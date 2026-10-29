/**
 * End-to-end test: `DELETE /account` refuses (money, groups, goals) BEFORE it
 * asks for step-up proof, through the real HTTP API (R1).
 *
 * Step-up can use up a one-time proof: a 2FA backup code, or the emailed code an
 * account with neither a password nor 2FA confirms with. A request that is going
 * to be refused anyway must not spend one, so the three 409 checks run first.
 * They run again after step-up, so money that lands meanwhile still blocks the
 * deletion. Their statuses, messages and order are unchanged, and a clean
 * account still needs every configured factor.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import, and the
 * test faucet funds wallets, so this is deterministic and fully offline.
 * APP_ENCRYPTION_KEY must be set: the TOTP secret is encrypted at rest.
 *
 * Run: pnpm --filter @workspace/api-server run test:account-delete-http
 */
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;
process.env.ENABLE_TEST_FAUCET = "true";
// Every connection this process opens carries this name (pg reads PGAPPNAME when
// it opens one), so lockWaiters counts only this test's own lock waiters, never
// another session's on the database.
const APP_NAME = `account-delete-e2e-${process.pid}`;
process.env.PGAPPNAME = APP_NAME;

const { db, pool, usersTable, sessionsTable, reauthCodesTable } = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { eq } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { createSession } = await import("./auth");
const { hashPassword } = await import("./password");
const { encryptSecret } = await import("./crypto");
const { generateBackupCodes } = await import("./twofactor");
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
const WRONG = "not the password 1!";
const FUNDS = "Withdraw your funds and release any goals before deleting your account.";
const GOALS = "Release your active goals before deleting your account.";

async function makeUser(label: string, values: Partial<typeof usersTable.$inferInsert> = {}) {
  const [u] = await db
    .insert(usersTable)
    .values({ name: `Delete ${label} ${runId}`, email: `e2e+delete+${label}+${runId}@moolahub.test`, ...values })
    .returning();
  userIds.push(u.id);
  await createWalletForUser(u.id);
  const token = await createSession(u.id);
  return { id: u.id, token };
}

async function fund(token: string): Promise<void> {
  const r = await api("POST", "/api/wallet/deposit", { token, body: { amountCents: 1000 } });
  assert.equal(r.status, 200, `faucet deposit should succeed (got ${r.status})`);
}

const deleteAccount = (token: string, proof: Record<string, string>) =>
  api<{ error?: string; ok?: boolean }>("DELETE", "/api/account", { token, body: { confirm: "DELETE", ...proof } });

const sha256 = (code: string) => createHash("sha256").update(code).digest("hex");

/** Wait until `n` of this test's connections are waiting for a lock. */
async function lockWaiters(n: number): Promise<void> {
  for (let i = 0; i < 250; i++) {
    const { rows } = await pool.query<{ n: number }>(
      "select count(*)::int as n from pg_stat_activity where datname = current_database() and application_name = $1 and wait_event_type = 'Lock'",
      [APP_NAME],
    );
    if (rows[0].n >= n) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${n} lock waiter(s)`);
}

async function run() {
  // 1. A refused request keeps the 2FA backup code it carried.
  const backup = generateBackupCodes();
  const a = await makeUser("a", {
    passwordHash: await hashPassword(PASSWORD),
    twoFactorEnabled: true,
    twoFactorSecret: encryptSecret(authenticator.generateSecret()),
    twoFactorBackupCodes: backup.hashes,
  });
  await fund(a.token);
  let r = await deleteAccount(a.token, { currentPassword: PASSWORD, twoFactorCode: backup.codes[0] });
  assert.equal(r.status, 409, `money blocks deletion (got ${r.status})`);
  assert.deepEqual(r.body, { error: FUNDS });
  const [rowA] = await db.select().from(usersTable).where(eq(usersTable.id, a.id));
  assert.deepEqual(rowA.twoFactorBackupCodes, backup.hashes, "every backup code is still there");

  // 2. With a wrong password the refusal still comes first.
  r = await deleteAccount(a.token, { currentPassword: WRONG, twoFactorCode: backup.codes[0] });
  assert.equal(r.status, 409, `refused before the password check (got ${r.status})`);
  assert.deepEqual(r.body, { error: FUNDS });

  // 3. A refused request keeps the emailed code of an account with no password and no 2FA.
  const b = await makeUser("b");
  await fund(b.token);
  await db.insert(reauthCodesTable).values({
    userId: b.id,
    codeHash: sha256("123456"),
    expiresAt: new Date(Date.now() + 10 * 60 * 1000),
  });
  r = await deleteAccount(b.token, { reauthCode: "123456" });
  assert.equal(r.status, 409, `money blocks deletion (got ${r.status})`);
  const codes = await db.select().from(reauthCodesTable).where(eq(reauthCodesTable.userId, b.id));
  assert.equal(codes.length, 1, "the emailed code still exists");
  assert.equal(codes[0].attempts, 0, "and no attempt was spent");

  // 4. The goals check also runs before the password check.
  const d = await makeUser("d", { passwordHash: await hashPassword(PASSWORD) });
  const goal = await api("POST", "/api/goals", {
    token: d.token,
    body: { name: "Laptop", targetCents: 100_000, deadline: "2027-06-30T00:00:00.000Z" },
  });
  assert.equal(goal.status, 201, `create goal should return 201 (got ${goal.status})`);
  r = await deleteAccount(d.token, { currentPassword: WRONG });
  assert.equal(r.status, 409, `a goal blocks deletion (got ${r.status})`);
  assert.deepEqual(r.body, { error: GOALS });

  // 5. A clean account still needs the right password.
  const c = await makeUser("c", { passwordHash: await hashPassword(PASSWORD) });
  r = await deleteAccount(c.token, { currentPassword: WRONG });
  assert.equal(r.status, 401, `a wrong password is refused (got ${r.status})`);
  assert.deepEqual(r.body, { error: "Your password is incorrect." });

  // 6. And with it, the account is deleted.
  r = await deleteAccount(c.token, { currentPassword: PASSWORD });
  assert.equal(r.status, 200, `deletion succeeds (got ${r.status})`);
  assert.deepEqual(r.body, { ok: true });
  const [rowC] = await db.select().from(usersTable).where(eq(usersTable.id, c.id));
  assert.ok(rowC.email.startsWith("deleted+"), "the email is anonymised");
  const sessions = await db.select().from(sessionsTable).where(eq(sessionsTable.userId, c.id));
  assert.equal(sessions.length, 0, "every session is ended");

  // 7. Money that lands while step-up runs still blocks the deletion. A raw
  // client holds the emailed code's row, so the request passes the first checks
  // and waits inside step-up while the deposit lands.
  const e = await makeUser("e");
  await db.insert(reauthCodesTable).values({
    userId: e.id,
    codeHash: sha256("654321"),
    expiresAt: new Date(Date.now() + 10 * 60 * 1000),
  });
  const holder = await pool.connect();
  let clean = false;
  try {
    await holder.query("begin");
    await holder.query("select id from reauth_codes where user_id = $1 for update", [e.id]);
    const pending = deleteAccount(e.token, { reauthCode: "654321" });
    pending.catch(() => {});
    await lockWaiters(1);
    await fund(e.token);
    await holder.query("commit");
    clean = true;
    r = await pending;
  } finally {
    holder.release(!clean);
  }
  assert.equal(r.status, 409, `money that landed during step-up blocks deletion (got ${r.status})`);
  assert.deepEqual(r.body, { error: FUNDS });
  const [rowE] = await db.select().from(usersTable).where(eq(usersTable.id, e.id));
  assert.equal(rowE.deletedAt, null, "the account is not deleted");
  assert.ok(!rowE.email.startsWith("deleted+"), "nor anonymised");
  const sessionsE = await db.select().from(sessionsTable).where(eq(sessionsTable.userId, e.id));
  assert.equal(sessionsE.length, 1, "the session is kept");
}

let failed = false;
try {
  await run();
  console.log(`\n✓ Account delete HTTP e2e passed (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Account delete HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  try {
    await purgeTestData({ userIds });
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
