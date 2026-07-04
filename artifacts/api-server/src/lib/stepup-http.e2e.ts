/**
 * End-to-end test for `verifyStepUp` wired through real HTTP routes, proving
 * accounts with BOTH a password and TOTP 2FA require BOTH factors for
 * high-risk actions — not just the password.
 *
 * Regression coverage for: step-up used to short-circuit on `currentPassword`
 * alone and never reach the `twoFactorEnabled` branch, so a stolen session +
 * a phished/reused password was enough to deactivate/delete the account or
 * change auth settings even when 2FA was enabled. See stepUp.ts.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import so this
 * is deterministic and fully offline. APP_ENCRYPTION_KEY must remain set —
 * the TOTP secret is encrypted at rest.
 *
 * Run: pnpm --filter @workspace/api-server test:stepup-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, sessionsTable, inArray, eq } = await (async () => {
  const dbMod = await import("@workspace/db");
  const drizzle = await import("drizzle-orm");
  return { ...dbMod, inArray: drizzle.inArray, eq: drizzle.eq };
})();
const { createSession } = await import("./auth");
const { hashPassword } = await import("./password");
const { encryptSecret } = await import("./crypto");
const { authenticator } = await import("otplib");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const userIds: string[] = [];

const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

type ApiResult<T = unknown> = { status: number; body: T };

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
  return { status: res.status, body: body as T };
}

const PASSWORD = "correct horse battery staple 9!";

async function makeUserWithPasswordAnd2fa(label: string) {
  const email = `e2e+stepup+${label}+${runId}@moolahub.test`;
  const secret = authenticator.generateSecret();
  const [u] = await db
    .insert(usersTable)
    .values({
      name: `Step-up ${label} ${runId}`,
      email,
      passwordHash: await hashPassword(PASSWORD),
      twoFactorEnabled: true,
      twoFactorSecret: encryptSecret(secret),
      twoFactorBackupCodes: [],
    })
    .returning();
  userIds.push(u.id);
  const token = await createSession(u.id);
  return { id: u.id, email, token, secret };
}

async function run() {
  const user = await makeUserWithPasswordAnd2fa("deactivate");

  // 1) Password alone must NOT be sufficient once 2FA is enabled.
  const passwordOnly = await api("POST", "/api/account/deactivate", {
    token: user.token,
    body: { currentPassword: PASSWORD },
  });
  assert.equal(
    passwordOnly.status,
    401,
    `password alone must be rejected for a password+2FA account (got ${passwordOnly.status})`,
  );

  // 2) 2FA code alone (without the password) must also NOT be sufficient.
  const totpOnly = await api("POST", "/api/account/deactivate", {
    token: user.token,
    body: { twoFactorCode: authenticator.generate(user.secret) },
  });
  assert.equal(
    totpOnly.status,
    401,
    `2FA code alone must be rejected when a password is also configured (got ${totpOnly.status})`,
  );

  // 3) A wrong 2FA code alongside the correct password must still fail.
  const wrongTotp = await api("POST", "/api/account/deactivate", {
    token: user.token,
    body: { currentPassword: PASSWORD, twoFactorCode: "000000" },
  });
  assert.equal(wrongTotp.status, 401, `a wrong 2FA code must be rejected even with the correct password (got ${wrongTotp.status})`);

  // 4) Both factors together succeed.
  const both = await api("POST", "/api/account/deactivate", {
    token: user.token,
    body: { currentPassword: PASSWORD, twoFactorCode: authenticator.generate(user.secret) },
  });
  assert.equal(both.status, 200, `both factors together must succeed (got ${both.status})`);

  const me = await api("GET", "/api/auth/me", { token: user.token });
  assert.equal(me.status, 401, "the session is signed out after a successful deactivation");

  // -- /auth/password: this route used to manually verify only the current
  // password, bypassing verifyStepUp entirely for password-having accounts.
  const pwUser = await makeUserWithPasswordAnd2fa("password");
  const NEW_PASSWORD = "another correct horse battery 7!";

  const pwPasswordOnly = await api("POST", "/api/auth/password", {
    token: pwUser.token,
    body: { currentPassword: PASSWORD, newPassword: NEW_PASSWORD },
  });
  assert.equal(
    pwPasswordOnly.status,
    401,
    `password alone must be rejected for /auth/password on a password+2FA account (got ${pwPasswordOnly.status})`,
  );

  const pwBoth = await api("POST", "/api/auth/password", {
    token: pwUser.token,
    body: {
      currentPassword: PASSWORD,
      newPassword: NEW_PASSWORD,
      twoFactorCode: authenticator.generate(pwUser.secret),
    },
  });
  assert.equal(pwBoth.status, 200, `both factors together must succeed for /auth/password (got ${pwBoth.status})`);

  // Note: /auth/privy/link is NOT exercised here over HTTP — it calls out to
  // Privy's real network API to verify the token *before* reaching the
  // verifyStepUp gate, which this offline/deterministic suite cannot do.
  // Its step-up call already forwards the FULL proof object (currentPassword,
  // twoFactorCode, reauthCode) to the same `verifyStepUp` proven above and in
  // /auth/password, so it is covered by code inspection + shared-function
  // coverage rather than a route-level HTTP assertion. See auth.ts.

  console.log(`\u2713 Step-up password+2FA HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`\u2717 Step-up password+2FA HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  if (userIds.length) {
    await db.delete(sessionsTable).where(inArray(sessionsTable.userId, userIds));
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
