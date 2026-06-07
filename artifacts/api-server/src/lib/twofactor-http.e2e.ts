/**
 * End-to-end test for 2FA-gated login completion, driven through the ACTUAL HTTP
 * API: the security setup/enable routes and POST /api/auth/2fa/login.
 *
 * The sibling `twofactor.e2e.ts` covers the lib helpers in isolation (challenge
 * single-use, expiry, backup-code single-use). This test proves the wiring real
 * users hit end to end:
 *   - enabling 2FA over HTTP (setup -> enable with a live TOTP) returns backup codes,
 *   - GET /security/2fa reports enabled + the remaining backup-code count,
 *   - POST /auth/2fa/login accepts a current TOTP code and mints a WORKING session
 *     (verified by calling GET /auth/me with the issued session cookie),
 *   - a wrong code is rejected (401) WITHOUT consuming the challenge (retryable),
 *   - a backup code completes login once, decrements the count, and can't be reused,
 *   - a consumed / unknown challenge is rejected,
 *   - once 2FA is disabled, an outstanding challenge no longer logs anyone in.
 *
 * Privy / passkey PRIMARY auth is intentionally out of scope (it needs external
 * services). The short-lived challenge those flows issue is simulated here with
 * `createTwoFactorChallenge`, which is exactly what `/auth/privy` and
 * `/passkeys/login/verify` call when an account has 2FA enabled.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import (same as the
 * circles HTTP test) so this is deterministic and fully offline. APP_ENCRYPTION_KEY
 * must remain set — the TOTP secret is encrypted at rest.
 *
 * Run: pnpm --filter @workspace/api-server test:twofactor-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source (snapshotted at import).
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, twoFactorChallengesTable } = await import("@workspace/db");
const { eq, inArray } = await import("drizzle-orm");
const { createSession } = await import("./auth");
const { createTwoFactorChallenge } = await import("./twofactor");
const { authenticator } = await import("otplib");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const userIds: string[] = [];

// --- In-process HTTP harness -------------------------------------------------
const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

type ApiResult<T = unknown> = { status: number; body: T; sessionToken: string | null };

function extractSession(res: Response): string | null {
  const cookies =
    typeof res.headers.getSetCookie === "function"
      ? res.headers.getSetCookie()
      : res.headers.get("set-cookie")
        ? [res.headers.get("set-cookie") as string]
        : [];
  for (const c of cookies) {
    const m = /(?:^|;\s*)moolahub_session=([^;]+)/.exec(c);
    if (m?.[1]) return decodeURIComponent(m[1]);
  }
  return null;
}

async function api<T = unknown>(
  method: string,
  path: string,
  opts: { token?: string; body?: unknown } = {},
): Promise<ApiResult<T>> {
  const headers: Record<string, string> = {};
  if (opts.token) headers["x-session-token"] = opts.token;
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  let body: unknown = null;
  const text = await res.text();
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return { status: res.status, body: body as T, sessionToken: extractSession(res) };
}

async function makeAuthedUser(label: string): Promise<{ id: string; email: string; token: string }> {
  const email = `e2e+2fahttp+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `2FA HTTP ${label} ${runId}`, email }).returning();
  userIds.push(u.id);
  const token = await createSession(u.id);
  return { id: u.id, email, token };
}

/** Turn on 2FA the way the UI does: setup (get secret) then enable with a live code. */
async function enable2fa(token: string): Promise<{ secret: string; backupCodes: string[] }> {
  const setup = await api<{ secret: string }>("POST", "/api/security/2fa/setup", { token });
  assert.equal(setup.status, 200, `2fa setup should return 200 (got ${setup.status})`);
  assert.ok(setup.body.secret, "setup returns the TOTP secret to the client");

  const enable = await api<{ backupCodes: string[] }>("POST", "/api/security/2fa/enable", {
    token,
    body: { code: authenticator.generate(setup.body.secret) },
  });
  assert.equal(enable.status, 200, `2fa enable should return 200 (got ${enable.status})`);
  assert.ok(Array.isArray(enable.body.backupCodes), "enable returns backup codes");
  assert.equal(enable.body.backupCodes.length, 10, "enable returns 10 backup codes");
  return { secret: setup.body.secret, backupCodes: enable.body.backupCodes };
}

async function statusFor(token: string) {
  const r = await api<{ enabled: boolean; backupCodesRemaining: number }>("GET", "/api/security/2fa", { token });
  assert.equal(r.status, 200, `GET /security/2fa should return 200 (got ${r.status})`);
  return r.body;
}

async function run() {
  const user = await makeAuthedUser("user");
  const { secret, backupCodes } = await enable2fa(user.token);

  const enabledStatus = await statusFor(user.token);
  assert.equal(enabledStatus.enabled, true, "2FA reports enabled after setup+enable");
  assert.equal(enabledStatus.backupCodesRemaining, 10, "10 backup codes remain right after enable");

  // 1) A wrong code is rejected and must NOT consume the challenge.
  const challenge1 = await createTwoFactorChallenge(user.id, false);
  const bad = await api("POST", "/api/auth/2fa/login", { body: { challengeId: challenge1, code: "000000" } });
  assert.equal(bad.status, 401, "a wrong TOTP code is rejected with 401");
  assert.equal(bad.sessionToken, null, "no session is issued for a wrong code");

  // 2) The correct TOTP on the SAME challenge then succeeds (proves the wrong
  //    attempt above did not consume the challenge) and mints a working session.
  const good = await api<{ id: string }>("POST", "/api/auth/2fa/login", {
    body: { challengeId: challenge1, code: authenticator.generate(secret) },
  });
  assert.equal(good.status, 200, `a valid TOTP completes login (got ${good.status})`);
  assert.equal(good.body.id, user.id, "2fa login returns the user id through the response schema");
  assert.ok(good.sessionToken, "a valid TOTP mints a session cookie");

  const me = await api<{ id: string }>("GET", "/api/auth/me", { token: good.sessionToken! });
  assert.equal(me.status, 200, "the issued session authenticates /auth/me");
  assert.equal(me.body.id, user.id, "/auth/me returns the same user");

  // 3) The challenge is single-use: reusing it after success fails.
  const reuse = await api("POST", "/api/auth/2fa/login", {
    body: { challengeId: challenge1, code: authenticator.generate(secret) },
  });
  assert.equal(reuse.status, 400, "a consumed challenge cannot be reused");

  // 4) Backup codes complete login once, decrement the count, and can't be reused.
  const challenge2 = await createTwoFactorChallenge(user.id, false);
  const viaBackup = await api<{ id: string }>("POST", "/api/auth/2fa/login", {
    body: { challengeId: challenge2, code: backupCodes[0] },
  });
  assert.equal(viaBackup.status, 200, "a backup code completes login");
  assert.ok(viaBackup.sessionToken, "a backup-code login mints a session");

  const afterBackup = await statusFor(user.token);
  assert.equal(afterBackup.backupCodesRemaining, 9, "a used backup code decrements the remaining count");

  const challenge3 = await createTwoFactorChallenge(user.id, false);
  const backupReuse = await api("POST", "/api/auth/2fa/login", {
    body: { challengeId: challenge3, code: backupCodes[0] },
  });
  assert.equal(backupReuse.status, 401, "a used backup code cannot be used again");

  // 5) An unknown / expired challenge is rejected.
  const unknown = await api("POST", "/api/auth/2fa/login", {
    body: { challengeId: randomUUID(), code: authenticator.generate(secret) },
  });
  assert.equal(unknown.status, 400, "an unknown challenge is rejected");

  // 6) Disabling 2FA invalidates any outstanding challenge.
  const challenge4 = await createTwoFactorChallenge(user.id, false);
  await db
    .update(usersTable)
    .set({ twoFactorEnabled: false, twoFactorSecret: null, twoFactorBackupCodes: null })
    .where(eq(usersTable.id, user.id));
  const afterDisable = await api("POST", "/api/auth/2fa/login", {
    body: { challengeId: challenge4, code: backupCodes[1] },
  });
  assert.equal(afterDisable.status, 400, "once 2FA is disabled, an outstanding challenge no longer logs in");

  console.log(`\u2713 2FA login HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`\u2717 2FA login HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  if (userIds.length) {
    await db.delete(twoFactorChallengesTable).where(inArray(twoFactorChallengesTable.userId, userIds));
    // Deleting the users cascades their sessions.
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
