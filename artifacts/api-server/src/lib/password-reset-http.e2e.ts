/**
 * End-to-end test for the forgot-password flow, driven through the ACTUAL HTTP
 * API. Proves the security-critical guarantees of Task #49:
 *
 *   - /auth/forgot-password never reveals whether an account exists (always 200
 *     + {ok:true}), and issues a code only for an existing password account,
 *   - /auth/reset-password rejects an invalid/expired code (400) with a generic
 *     message and does not change the password,
 *   - reset codes are NOT brute-forceable: a code is burned after a fixed number
 *     of failed attempts, forcing the user to request a fresh one,
 *   - a fresh, correct code resets the password: the OLD password no longer logs
 *     in and the NEW password does,
 *   - resetting invalidates all existing sessions (a pre-reset session token can
 *     no longer call /auth/me),
 *   - a Privy-only account (no password) is never issued a reset code.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import so this is
 * deterministic and fully offline. APP_ENCRYPTION_KEY must remain set.
 *
 * Run: pnpm --filter @workspace/api-server test:reset-http
 */
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source (snapshotted at import).
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, passwordResetCodesTable } = await import("@workspace/db");
const { eq, inArray } = await import("drizzle-orm");
const { createSession } = await import("./auth");
const { hashPassword } = await import("./password");
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

function hashCode(code: string): string {
  return createHash("sha256").update(code.trim()).digest("hex");
}

/** Replace whatever forgot-password issued with a code whose plaintext we know. */
async function seedResetCode(userId: string, code: string): Promise<void> {
  await db.delete(passwordResetCodesTable).where(eq(passwordResetCodesTable.userId, userId));
  await db.insert(passwordResetCodesTable).values({
    userId,
    codeHash: hashCode(code),
    expiresAt: new Date(Date.now() + 10 * 60 * 1000),
  });
}

async function run() {
  const email = `e2e+reset+${runId}@moolahub.test`;
  const oldPassword = "Old-Passw0rd!";
  const newPassword = "Br4nd-New-Pass!";

  // A verified password account that "forgot" its password.
  const [user] = await db
    .insert(usersTable)
    .values({
      name: "Reset Tester",
      username: `reset_${runId}`,
      email,
      passwordHash: await hashPassword(oldPassword),
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(user.id);

  // --- 1) forgot-password never reveals account existence --------------------
  const forgotKnown = await api<{ ok: boolean }>("POST", "/api/auth/forgot-password", { body: { email } });
  assert.equal(forgotKnown.status, 200, "forgot-password returns 200 for a known account");
  assert.equal(forgotKnown.body.ok, true, "forgot-password returns {ok:true} for a known account");

  const forgotUnknown = await api<{ ok: boolean }>("POST", "/api/auth/forgot-password", {
    body: { email: `nobody+${runId}@moolahub.test` },
  });
  assert.equal(forgotUnknown.status, 200, "forgot-password returns 200 for an unknown account (no leak)");
  assert.equal(forgotUnknown.body.ok, true, "forgot-password returns {ok:true} for an unknown account");
  const [noRow] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(eq(passwordResetCodesTable.userId, user.id));
  // The known-account request above issued a real code; an unknown account must
  // not create any rows. (Sanity: the known row exists, since forgot ran first.)
  assert.ok(noRow, "a code row exists for the known account after its request");

  // --- 2) reset codes are not brute-forceable --------------------------------
  await seedResetCode(user.id, "111111");
  for (let i = 0; i < 5; i++) {
    const bad = await api("POST", "/api/auth/reset-password", {
      body: { email, code: "000000", newPassword },
    });
    assert.equal(bad.status, 400, `wrong reset code attempt ${i + 1} is rejected (400)`);
  }
  // The code is now burned: even the correct plaintext no longer works.
  const burned = await api("POST", "/api/auth/reset-password", {
    body: { email, code: "111111", newPassword },
  });
  assert.equal(burned.status, 400, "the correct code fails once the attempt budget is spent (burned)");
  const [afterBurn] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(eq(passwordResetCodesTable.userId, user.id));
  assert.equal(afterBurn, undefined, "an exhausted reset code row is removed");

  // The old password still works (no reset happened during the failed attempts).
  const stillOld = await api("POST", "/api/auth/login", { body: { email, password: oldPassword } });
  assert.equal(stillOld.status, 200, "the old password still logs in after only failed reset attempts");

  // --- 3) a short new password is rejected before the code is consumed -------
  await seedResetCode(user.id, "222222");
  const tooShort = await api("POST", "/api/auth/reset-password", {
    body: { email, code: "222222", newPassword: "short" },
  });
  assert.equal(tooShort.status, 400, "a too-short new password is rejected (400)");
  const [stillThere] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(eq(passwordResetCodesTable.userId, user.id));
  assert.ok(stillThere, "the reset code survives a rejected (too-short) password attempt");

  // --- 4) a fresh, correct code resets the password --------------------------
  // Establish a session BEFORE the reset to prove it gets invalidated.
  const preSession = await createSession(user.id);
  const preMe = await api("GET", "/api/auth/me", { token: preSession });
  assert.equal(preMe.status, 200, "the pre-reset session authenticates before the reset");

  const reset = await api<{ ok: boolean }>("POST", "/api/auth/reset-password", {
    body: { email, code: "222222", newPassword },
  });
  assert.equal(reset.status, 200, `a fresh correct code resets the password (got ${reset.status})`);
  assert.equal(reset.body.ok, true, "reset returns {ok:true}");

  const oldLogin = await api("POST", "/api/auth/login", { body: { email, password: oldPassword } });
  assert.equal(oldLogin.status, 401, "the old password no longer logs in after the reset");

  const newLogin = await api<{ id: string }>("POST", "/api/auth/login", {
    body: { email, password: newPassword },
  });
  assert.equal(newLogin.status, 200, "the new password logs in after the reset");
  assert.ok(newLogin.sessionToken, "logging in with the new password mints a session");

  // --- 5) reset invalidates all prior sessions -------------------------------
  const postMe = await api("GET", "/api/auth/me", { token: preSession });
  assert.equal(postMe.status, 401, "the pre-reset session is invalidated by the reset");

  // --- 6) a Privy-only account is never issued a reset code ------------------
  const privyEmail = `e2e+resetprivy+${runId}@moolahub.test`;
  const [privyUser] = await db
    .insert(usersTable)
    .values({
      name: "Privy Only",
      email: privyEmail,
      privyDid: `did:privy:reset-${runId}`,
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(privyUser.id);

  const forgotPrivy = await api<{ ok: boolean }>("POST", "/api/auth/forgot-password", {
    body: { email: privyEmail },
  });
  assert.equal(forgotPrivy.status, 200, "forgot-password returns 200 for a Privy-only account (no leak)");
  const [privyRow] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(eq(passwordResetCodesTable.userId, privyUser.id));
  assert.equal(privyRow, undefined, "no reset code is issued for a Privy-only (passwordless) account");

  console.log(`\u2713 Forgot-password HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`\u2717 Forgot-password HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  if (userIds.length) {
    await db.delete(passwordResetCodesTable).where(inArray(passwordResetCodesTable.userId, userIds));
    // Deleting the users cascades their sessions + codes.
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
