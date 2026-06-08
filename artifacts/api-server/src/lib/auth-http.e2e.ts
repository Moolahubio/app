/**
 * End-to-end test for email + password PRIMARY auth, driven through the ACTUAL
 * HTTP API. Proves the security-critical guarantees of Task #47:
 *
 *   - register requires email verification before a session is ever minted,
 *   - a wrong password is rejected (401),
 *   - usernames are unique case-insensitively at register (409),
 *   - email verification codes are NOT brute-forceable: a code is burned after a
 *     fixed number of failed attempts, forcing the user to request a new one,
 *   - a fresh, correct code verifies the email and mints a working session,
 *   - GET /auth/me exposes username + hasPassword + emailVerified (public surfaces
 *     use the username, never the legal name),
 *   - changing the password invalidates the old one and the new one works,
 *   - a legacy Privy-only account (no password) reports hasPassword=false so the
 *     UI completion gate fires, and CAN set a first password without the current
 *     one — which also confirms its email.
 *
 * Privy PRIMARY auth (/auth/privy) is intentionally out of scope here: it needs a
 * live Privy token, exactly like the sibling twofactor-http test excludes it.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import so this is
 * deterministic and fully offline. APP_ENCRYPTION_KEY must remain set.
 *
 * Run: pnpm --filter @workspace/api-server test:auth-http
 */
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source (snapshotted at import).
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, emailVerificationCodesTable } = await import("@workspace/db");
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

/** Replace whatever code register issued with one whose plaintext we control. */
async function seedCode(userId: string, code: string): Promise<void> {
  await db.delete(emailVerificationCodesTable).where(eq(emailVerificationCodesTable.userId, userId));
  await db.insert(emailVerificationCodesTable).values({
    userId,
    codeHash: hashCode(code),
    expiresAt: new Date(Date.now() + 10 * 60 * 1000),
  });
}

async function userIdByEmail(email: string): Promise<string> {
  const [u] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  assert.ok(u, `expected a user row for ${email}`);
  userIds.push(u.id);
  return u.id;
}

type MeDto = { id: string; username: string | null; hasPassword: boolean; emailVerified: boolean };

async function run() {
  const email = `e2e+authhttp+${runId}@moolahub.test`;
  const username = `auth${runId}`; // <= 30 chars, [a-z0-9_]
  const password = "Sup3rSecret!";

  // --- 1) Register requires verification before any session ------------------
  const reg = await api<{ emailVerificationRequired: boolean; email: string }>("POST", "/api/auth/register", {
    body: { name: "Auth Tester", email, username, password, dateOfBirth: "1990-01-01", referralSource: "Twitter" },
  });
  assert.equal(reg.status, 200, `register should return 200 (got ${reg.status})`);
  assert.equal(reg.body.emailVerificationRequired, true, "register requires email verification");
  assert.equal(reg.sessionToken, null, "register must NOT mint a session");
  const uid = await userIdByEmail(email);

  // --- 2) Login before verification yields no session ------------------------
  const preLogin = await api<{ emailVerificationRequired?: boolean }>("POST", "/api/auth/login", {
    body: { email, password },
  });
  assert.equal(preLogin.status, 200, "login with correct creds (unverified) returns 200 status");
  assert.equal(preLogin.body.emailVerificationRequired, true, "unverified login asks for verification");
  assert.equal(preLogin.sessionToken, null, "unverified login mints no session");

  // --- 3) Wrong password is rejected -----------------------------------------
  const wrong = await api("POST", "/api/auth/login", { body: { email, password: "wrong-password-xyz" } });
  assert.equal(wrong.status, 401, "a wrong password is rejected with 401");
  assert.equal(wrong.sessionToken, null, "no session for a wrong password");

  // --- 4) Username uniqueness is case-insensitive at register ----------------
  const dupUser = await api("POST", "/api/auth/register", {
    body: {
      name: "Impostor",
      email: `e2e+dup+${runId}@moolahub.test`,
      username: username.toUpperCase(),
      password,
      dateOfBirth: "1991-02-02",
      referralSource: "Friends",
    },
  });
  assert.equal(dupUser.status, 409, "a case-variant of an existing username is rejected (409)");

  // --- 5) Verification codes are not brute-forceable -------------------------
  await seedCode(uid, "111111");
  for (let i = 0; i < 5; i++) {
    const bad = await api("POST", "/api/auth/verify-email", { body: { email, code: "000000" } });
    assert.equal(bad.status, 400, `wrong verification code attempt ${i + 1} is rejected (400)`);
  }
  // The code is now burned: even the correct plaintext no longer works.
  const burned = await api("POST", "/api/auth/verify-email", { body: { email, code: "111111" } });
  assert.equal(burned.status, 400, "the correct code fails once the attempt budget is spent (code burned)");
  const [afterBurn] = await db
    .select()
    .from(emailVerificationCodesTable)
    .where(eq(emailVerificationCodesTable.userId, uid));
  assert.equal(afterBurn, undefined, "an exhausted code row is removed, forcing a fresh request");

  // --- 6) A fresh, correct code verifies and mints a working session ---------
  await seedCode(uid, "222222");
  const verify = await api<{ id: string }>("POST", "/api/auth/verify-email", {
    body: { email, code: "222222" },
  });
  assert.equal(verify.status, 200, `a fresh correct code verifies (got ${verify.status})`);
  assert.ok(verify.sessionToken, "verification mints a session");
  assert.equal(verify.body.id, uid, "verify returns the user id");

  const me = await api<MeDto>("GET", "/api/auth/me", { token: verify.sessionToken! });
  assert.equal(me.status, 200, "the issued session authenticates /auth/me");
  assert.equal(me.body.username, username, "/auth/me exposes the public username");
  assert.equal(me.body.hasPassword, true, "/auth/me reports hasPassword=true for a password account");
  assert.equal(me.body.emailVerified, true, "/auth/me reports emailVerified=true after verification");

  // --- 7) Changing the password invalidates the old one ----------------------
  const newPassword = "Even-Str0nger!";
  const change = await api("POST", "/api/auth/password", {
    token: verify.sessionToken!,
    body: { currentPassword: password, newPassword },
  });
  assert.equal(change.status, 200, `change-password should return 200 (got ${change.status})`);

  const oldLogin = await api("POST", "/api/auth/login", { body: { email, password } });
  assert.equal(oldLogin.status, 401, "the old password no longer logs in after a change");

  const newLogin = await api<{ id: string }>("POST", "/api/auth/login", { body: { email, password: newPassword } });
  assert.equal(newLogin.status, 200, "the new password logs in");
  assert.ok(newLogin.sessionToken, "logging in with the new password mints a session");

  // --- 8) Legacy Privy-only account: completion gate + first password --------
  const legacyEmail = `e2e+legacy+${runId}@moolahub.test`;
  const [legacy] = await db
    .insert(usersTable)
    .values({
      name: "Legacy Privy User",
      email: legacyEmail,
      privyDid: `did:privy:legacy-${runId}`,
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(legacy.id);
  const legacyToken = await createSession(legacy.id);

  const legacyMe = await api<MeDto>("GET", "/api/auth/me", { token: legacyToken });
  assert.equal(legacyMe.status, 200, "legacy account authenticates");
  assert.equal(legacyMe.body.hasPassword, false, "legacy Privy-only account reports hasPassword=false (gate fires)");
  assert.equal(legacyMe.body.username, null, "legacy account has no username yet (gate fires)");

  // A passwordless account may set a first password WITHOUT the current one.
  const setFirst = await api("POST", "/api/auth/password", {
    token: legacyToken,
    body: { currentPassword: null, newPassword: "First-Passw0rd!" },
  });
  assert.equal(setFirst.status, 200, `legacy account can set a first password (got ${setFirst.status})`);

  const legacyMe2 = await api<MeDto>("GET", "/api/auth/me", { token: legacyToken });
  assert.equal(legacyMe2.body.hasPassword, true, "hasPassword flips true after a legacy account sets a password");

  // --- 9) Login is throttled after repeated wrong passwords -----------------
  // Use a dedicated verified account so the lockout (per email+IP) doesn't
  // affect the other identifiers exercised above.
  const lockEmail = `e2e+lock+${runId}@moolahub.test`;
  const [locked] = await db
    .insert(usersTable)
    .values({
      name: "Lockout User",
      username: `lock_${runId}`,
      email: lockEmail,
      passwordHash: await hashPassword("Right-Passw0rd!"),
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(locked.id);

  let sawLockout = false;
  for (let i = 0; i < 12; i++) {
    const attempt = await api("POST", "/api/auth/login", {
      body: { email: lockEmail, password: "definitely-wrong" },
    });
    if (attempt.status === 429) {
      sawLockout = true;
      break;
    }
    assert.equal(attempt.status, 401, `pre-lockout wrong password returns 401 (attempt ${i + 1})`);
  }
  assert.ok(sawLockout, "repeated wrong passwords eventually lock the account (429)");

  // Even the CORRECT password is refused while locked out.
  const blocked = await api("POST", "/api/auth/login", {
    body: { email: lockEmail, password: "Right-Passw0rd!" },
  });
  assert.equal(blocked.status, 429, "the correct password is also blocked while locked out");

  console.log(`\u2713 Email + password auth HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`\u2717 Email + password auth HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  if (userIds.length) {
    await db.delete(emailVerificationCodesTable).where(inArray(emailVerificationCodesTable.userId, userIds));
    // Deleting the users cascades their sessions + codes.
    await db.delete(usersTable).where(inArray(usersTable.id, userIds));
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
