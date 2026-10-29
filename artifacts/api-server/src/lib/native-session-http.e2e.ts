/**
 * End-to-end test for the native (iOS) client contract, driven through the
 * ACTUAL HTTP API with real requests the way the app sends them: JSON bodies, no
 * Origin header, `X-Client: ios`, the session token in `x-session-token`.
 *
 * Proves:
 *   - no `sessionToken` in any login body without the header, and the browser
 *     JSON is exactly the native JSON minus that one field (web unchanged);
 *   - `sessionToken` IS returned with the header (value case-insensitive) on
 *     login, email verification and 2FA login, and only once a session exists;
 *   - that token authenticates GET /auth/me via `x-session-token` alone;
 *   - logout with only the header kills the session (row gone, /auth/me 401);
 *   - native requests (no Origin, JSON) pass the CSRF/origin guards while a
 *     cross-site Origin is still refused;
 *   - dev email-code logging: the verification / password-reset / step-up codes
 *     are logged (masked address) when DEV_LOG_EMAIL_CODES=true outside
 *     production, are NOT logged in production (with a warning), and are not
 *     logged when the flag is off;
 *   - a freshly verified user can use the ledger-only test faucet offline (a dev
 *     wallet is provisioned on first deposit), and production never does that.
 *
 * Scope: on-chain settlement and email are disabled BEFORE any import, so this is
 * deterministic and fully offline. APP_ENCRYPTION_KEY must be set (the dev
 * wallet key and the TOTP secret are encrypted at rest).
 *
 * Run: pnpm --filter @workspace/api-server test:native-session-http
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";

// Disable on-chain settlement and email at the source (snapshotted at import).
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;
delete process.env.ENABLE_PRIVY_CUSTODY;
// This suite makes more /api/auth calls than the 20-per-15-minutes production
// budget; the dev-only override is honoured because NODE_ENV isn't production.
process.env.DEV_AUTH_RATE_LIMIT_MAX = "1000";
process.env.ENABLE_TEST_FAUCET = "true";
const ORIGINAL_NODE_ENV = process.env.NODE_ENV;
if (ORIGINAL_NODE_ENV === "production") {
  throw new Error("native-session-http e2e must not run with NODE_ENV=production");
}

const { db, pool, usersTable, sessionsTable, walletsTable } = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { GetMeResponse } = await import("@workspace/api-zod");
const { eq } = await import("drizzle-orm");
const { createSession } = await import("./auth");
const { hashPassword } = await import("./password");
const { generateTotpSecret, encryptTotpSecret } = await import("./twofactor");
const { authenticator } = await import("otplib");
const { logger } = await import("./logger");
const appModule = await import("../app");
const app = appModule.default;

const runId = randomUUID().slice(0, 8);
const userIds: string[] = [];
const PASSWORD = "Native-Sess10n!";

// --- Log capture ---------------------------------------------------------------
// The dev code lines and the production warning go through logger.warn.
const warnLines: string[] = [];
const originalWarn = logger.warn;
logger.warn = ((...args: unknown[]) => {
  warnLines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
  return (originalWarn as (...a: unknown[]) => void).apply(logger, args);
}) as typeof logger.warn;

function devCodeLines(): string[] {
  return warnLines.filter((l) => l.includes("[DEV ONLY]") && / code for /.test(l));
}

/** The 6-digit code from the newest dev line of `kind`, asserting it exists. */
function lastLoggedCode(kind: string, sinceIndex: number): { code: string; line: string } {
  const lines = warnLines.slice(sinceIndex).filter((l) => l.startsWith(`[DEV ONLY] ${kind} code for `));
  assert.ok(lines.length > 0, `expected a "[DEV ONLY] ${kind} code" log line`);
  const line = lines[lines.length - 1]!;
  const m = / code for (\S+): (\d{6}) /.exec(line);
  assert.ok(m, `dev line has a masked address and a 6-digit code: ${line}`);
  return { code: m[2]!, line };
}

function withNodeEnv<T>(value: string | undefined, fn: () => Promise<T>): Promise<T> {
  if (value === undefined) delete process.env.NODE_ENV;
  else process.env.NODE_ENV = value;
  return fn().finally(() => {
    if (ORIGINAL_NODE_ENV === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = ORIGINAL_NODE_ENV;
  });
}

// --- In-process HTTP harness -------------------------------------------------
const server = app.listen(0);
await new Promise<void>((resolve) => server.once("listening", () => resolve()));
const baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

type ApiResult<T = Record<string, unknown>> = {
  status: number;
  body: T;
  text: string;
  cookieToken: string | null;
};

function extractCookieSession(res: Response): string | null {
  for (const c of res.headers.getSetCookie()) {
    const m = /(?:^|;\s*)moolahub_session=([^;]+)/.exec(c);
    if (m?.[1]) return decodeURIComponent(m[1]);
  }
  return null;
}

/**
 * One request. `client: "ios"` sends exactly what the native app sends; the
 * default is a browser-like call (no X-Client). Neither sends an Origin unless
 * `origin` is given. `xClient` overrides the header value verbatim.
 */
async function api<T = Record<string, unknown>>(
  method: string,
  path: string,
  opts: { client?: "ios"; xClient?: string; token?: string; body?: unknown; origin?: string } = {},
): Promise<ApiResult<T>> {
  const headers: Record<string, string> = {};
  const xClient = opts.xClient ?? (opts.client === "ios" ? "ios" : undefined);
  if (xClient !== undefined) headers["x-client"] = xClient;
  if (opts.token) headers["x-session-token"] = opts.token;
  if (opts.origin) headers["origin"] = opts.origin;
  if (opts.body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  let body: unknown = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }
  return { status: res.status, body: body as T, text, cookieToken: extractCookieSession(res) };
}

function omitToken(body: Record<string, unknown>): Record<string, unknown> {
  const { sessionToken: _omit, ...rest } = body;
  return rest;
}

async function userIdByEmail(email: string): Promise<string> {
  const [u] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  assert.ok(u, `expected a user row for ${email}`);
  if (!userIds.includes(u.id)) userIds.push(u.id);
  return u.id;
}

async function insertVerifiedUser(tag: string): Promise<{ id: string; email: string }> {
  const email = `e2e+native+${tag}+${runId}@moolahub.test`;
  const [u] = await db
    .insert(usersTable)
    .values({
      name: `Native ${tag}`,
      username: `nat_${tag}_${runId}`,
      email,
      passwordHash: await hashPassword(PASSWORD),
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(u.id);
  return { id: u.id, email };
}

async function register(tag: string, client?: "ios") {
  const email = `e2e+native+${tag}+${runId}@moolahub.test`;
  const res = await api("POST", "/api/auth/register", {
    client,
    body: {
      name: `Native ${tag}`,
      email,
      username: `nat_${tag}_${runId}`,
      password: PASSWORD,
      dateOfBirth: "1992-05-17",
    },
  });
  assert.equal(res.status, 200, `register ${tag} returns 200 (got ${res.status}: ${res.text})`);
  await userIdByEmail(email);
  return { email, res };
}

async function run() {
  // --- 1) Sign-up with a dev-logged verification code (dev flag on) ------------
  process.env.DEV_LOG_EMAIL_CODES = "true";
  let mark = warnLines.length;
  const web = await register("web");
  assert.equal("sessionToken" in web.res.body, false, "register never returns a session token");
  const webCode = lastLoggedCode("verification", mark);
  assert.ok(!webCode.line.includes(web.email), "the dev line never contains the full email address");
  assert.ok(webCode.line.includes("e***@m***.test"), `the dev line carries the masked address: ${webCode.line}`);

  // Browser verification: cookie, no token in the body.
  const webVerify = await api("POST", "/api/auth/verify-email", { body: { email: web.email, code: webCode.code } });
  assert.equal(webVerify.status, 200, `web verify-email with the logged code succeeds (got ${webVerify.status})`);
  assert.ok(webVerify.cookieToken, "web verify-email still sets the session cookie");
  assert.equal("sessionToken" in webVerify.body, false, "web verify-email body has no sessionToken");

  // --- 2) Login: web body unchanged, native body = web body + sessionToken ------
  const webLogin = await api("POST", "/api/auth/login", { body: { email: web.email, password: PASSWORD } });
  assert.equal(webLogin.status, 200, "web login succeeds");
  assert.ok(webLogin.cookieToken, "web login sets the session cookie");
  assert.equal("sessionToken" in webLogin.body, false, "web login body has NO sessionToken");
  assert.equal(webLogin.text.includes(webLogin.cookieToken!), false, "the cookie token never appears in the web body");

  const nativeLogin = await api("POST", "/api/auth/login", {
    client: "ios",
    body: { email: web.email, password: PASSWORD },
  });
  assert.equal(nativeLogin.status, 200, `native login (no Origin, JSON) passes the CSRF guard (got ${nativeLogin.status})`);
  const nativeToken = nativeLogin.body.sessionToken;
  assert.equal(typeof nativeToken, "string", "native login returns sessionToken");
  assert.match(nativeToken as string, /^[0-9a-f]{64}$/, "sessionToken is the 32-byte hex session token");
  assert.equal(nativeToken, nativeLogin.cookieToken, "the body token is the same session the cookie carries");
  assert.equal(
    JSON.stringify(omitToken(nativeLogin.body)),
    webLogin.text,
    "web login JSON is byte-for-byte the native JSON without sessionToken",
  );

  for (const variant of ["iOS", "IOS", " ios "]) {
    const r = await api("POST", "/api/auth/login", { xClient: variant, body: { email: web.email, password: PASSWORD } });
    assert.equal(typeof r.body.sessionToken, "string", `X-Client value "${variant}" is matched case-insensitively`);
  }
  for (const other of ["android", "web", "ios-test", ""]) {
    const r = await api("POST", "/api/auth/login", { xClient: other, body: { email: web.email, password: PASSWORD } });
    assert.equal(r.status, 200);
    assert.equal("sessionToken" in r.body, false, `X-Client "${other}" gets no sessionToken`);
  }

  // Guards are not loosened: a cross-site browser Origin is still refused.
  const crossSite = await api("POST", "/api/auth/login", {
    client: "ios",
    origin: "https://evil.example",
    body: { email: web.email, password: PASSWORD },
  });
  assert.equal(crossSite.status, 403, "a cross-site Origin is still rejected, X-Client or not");
  const notJson = await fetch(`${baseUrl}/api/auth/login`, {
    method: "POST",
    headers: { "x-client": "ios", "content-type": "text/plain" },
    body: JSON.stringify({ email: web.email, password: PASSWORD }),
  });
  assert.equal(notJson.status, 415, "a non-JSON login is still rejected (CSRF guard intact)");

  // --- 3) The token authenticates /auth/me via x-session-token alone ----------
  const me = await api<{ id: string; email: string }>("GET", "/api/auth/me", { client: "ios", token: nativeToken as string });
  assert.equal(me.status, 200, "x-session-token authenticates /auth/me");
  assert.equal(me.body.email, web.email, "/auth/me returns the signed-in user");
  const noToken = await api("GET", "/api/auth/me", { client: "ios" });
  assert.equal(noToken.status, 401, "no token, no session");
  const badToken = await api("GET", "/api/auth/me", { client: "ios", token: "0".repeat(64) });
  assert.equal(badToken.status, 401, "an unknown token is rejected");

  // --- 4) Logout with only the header kills that session ----------------------
  const logout = await api("POST", "/api/auth/logout", { client: "ios", token: nativeToken as string });
  assert.equal(logout.status, 200, `native logout (no body, no Origin) passes the origin guard (got ${logout.status})`);
  const [gone] = await db.select().from(sessionsTable).where(eq(sessionsTable.token, nativeToken as string));
  assert.equal(gone, undefined, "logout deleted the session row");
  const meAfter = await api("GET", "/api/auth/me", { client: "ios", token: nativeToken as string });
  assert.equal(meAfter.status, 401, "the token no longer authenticates after logout");
  const webStillIn = await api("GET", "/api/auth/me", { token: webLogin.cookieToken! });
  assert.equal(webStillIn.status, 200, "logging out one native session leaves other sessions alone");

  // --- 5) Native sign-up: verify-email returns the token ----------------------
  mark = warnLines.length;
  const ios = await register("ios", "ios");
  assert.equal("sessionToken" in ios.res.body, false, "native register returns no token (no session yet)");
  const iosCode = lastLoggedCode("verification", mark);
  const unverifiedLogin = await api("POST", "/api/auth/login", { client: "ios", body: { email: ios.email, password: PASSWORD } });
  assert.equal(unverifiedLogin.body.emailVerificationRequired, true, "unverified login asks for verification");
  assert.equal("sessionToken" in unverifiedLogin.body, false, "no token while verification is pending");
  const iosVerify = await api("POST", "/api/auth/verify-email", {
    client: "ios",
    body: { email: ios.email, code: iosCode.code },
  });
  assert.equal(iosVerify.status, 200, `native verify-email succeeds (got ${iosVerify.status}: ${iosVerify.text})`);
  const iosToken = iosVerify.body.sessionToken as string;
  assert.match(iosToken, /^[0-9a-f]{64}$/, "native verify-email returns sessionToken");
  const iosMe = await api<{ email: string; emailVerified: boolean }>("GET", "/api/auth/me", { client: "ios", token: iosToken });
  assert.equal(iosMe.status, 200, "the verify-email token authenticates /auth/me");
  assert.equal(iosMe.body.emailVerified, true);

  // --- 6) Offline test faucet works for that freshly verified user -------------
  const walletBefore = await api<{ hasWallet: boolean }>("GET", "/api/wallet", { client: "ios", token: iosToken });
  assert.equal(walletBefore.body.hasWallet, false, "a new account starts without a wallet");
  const deposit = await api("POST", "/api/wallet/deposit", { client: "ios", token: iosToken, body: { amountCents: 2500 } });
  assert.equal(deposit.status, 200, `offline faucet deposit succeeds for a fresh user (got ${deposit.status}: ${deposit.text})`);
  const deposit2 = await api("POST", "/api/wallet/deposit", { client: "ios", token: iosToken, body: { amountCents: 1000 } });
  assert.equal(deposit2.status, 200, "a second deposit reuses the wallet");
  const walletAfter = await api<{ hasWallet: boolean; availableCents: number; custody: string | null; onchainEnabled: boolean }>(
    "GET",
    "/api/wallet",
    { client: "ios", token: iosToken },
  );
  assert.equal(walletAfter.body.availableCents, 3500, "the ledger balance shows both test deposits");
  assert.equal(walletAfter.body.hasWallet, true);
  assert.equal(walletAfter.body.onchainEnabled, false, "offline: nothing settles on-chain");
  const iosUserId = await userIdByEmail(ios.email);
  const iosWallets = await db.select().from(walletsTable).where(eq(walletsTable.userId, iosUserId));
  assert.equal(iosWallets.length, 1, "exactly one wallet row was provisioned");

  // Production never provisions one, faucet flag or not.
  const prodUser = await insertVerifiedUser("prod");
  const prodToken = await createSession(prodUser.id);
  const prodDeposit = await withNodeEnv("production", () =>
    api<{ error: string }>("POST", "/api/wallet/deposit", { client: "ios", token: prodToken, body: { amountCents: 2500 } }),
  );
  assert.equal(prodDeposit.status, 400, `production refuses a walletless faucet deposit (got ${prodDeposit.status})`);
  assert.equal(prodDeposit.body.error, "Your account isn't set up to add money yet.");
  const prodWallets = await db.select().from(walletsTable).where(eq(walletsTable.userId, prodUser.id));
  assert.equal(prodWallets.length, 0, "no wallet is provisioned in production");

  // --- 7) 2FA login: token only after the second factor, web unchanged -------
  const tfa = await insertVerifiedUser("tfa");
  const secret = generateTotpSecret();
  await db
    .update(usersTable)
    .set({ twoFactorEnabled: true, twoFactorSecret: encryptTotpSecret(secret) })
    .where(eq(usersTable.id, tfa.id));

  const nativeFirst = await api("POST", "/api/auth/login", { client: "ios", body: { email: tfa.email, password: PASSWORD } });
  assert.equal(nativeFirst.body.twoFactorRequired, true, "2FA account gets a challenge");
  assert.equal("sessionToken" in nativeFirst.body, false, "no token before the second factor");
  assert.equal(nativeFirst.cookieToken, null, "no session before the second factor");
  const native2fa = await api("POST", "/api/auth/2fa/login", {
    client: "ios",
    body: { challengeId: nativeFirst.body.challengeId, code: authenticator.generate(secret) },
  });
  assert.equal(native2fa.status, 200, `native 2FA login succeeds (got ${native2fa.status}: ${native2fa.text})`);
  const tfaToken = native2fa.body.sessionToken as string;
  assert.match(tfaToken, /^[0-9a-f]{64}$/, "native 2FA login returns sessionToken");
  const tfaMe = await api("GET", "/api/auth/me", { client: "ios", token: tfaToken });
  assert.equal(tfaMe.status, 200, "the 2FA token authenticates /auth/me");

  const webFirst = await api("POST", "/api/auth/login", { body: { email: tfa.email, password: PASSWORD } });
  const web2fa = await api("POST", "/api/auth/2fa/login", {
    body: { challengeId: webFirst.body.challengeId, code: authenticator.generate(secret) },
  });
  assert.equal(web2fa.status, 200, "web 2FA login succeeds");
  assert.ok(web2fa.cookieToken, "web 2FA login sets the cookie");
  assert.equal("sessionToken" in web2fa.body, false, "web 2FA body has no sessionToken");
  assert.equal(
    web2fa.text,
    JSON.stringify(GetMeResponse.parse(web2fa.body)),
    "web 2FA JSON is exactly the AuthUser shape it always was",
  );
  assert.equal(JSON.stringify(omitToken(native2fa.body)), web2fa.text, "native 2FA JSON = web JSON + sessionToken");

  // --- 8) Password-reset and step-up codes are dev-logged too ------------------
  mark = warnLines.length;
  const forgot = await api("POST", "/api/auth/forgot-password", { client: "ios", body: { email: web.email } });
  assert.equal(forgot.status, 200, "forgot-password succeeds");
  const resetCode = lastLoggedCode("password reset", mark);
  const reset = await api("POST", "/api/auth/reset-password", {
    client: "ios",
    body: { email: web.email, code: resetCode.code, newPassword: `${PASSWORD}2` },
  });
  assert.equal(reset.status, 200, "the logged reset code resets the password");

  const [legacy] = await db
    .insert(usersTable)
    .values({
      name: "Native legacy",
      email: `e2e+native+legacy+${runId}@moolahub.test`,
      privyDid: `did:privy:native-${runId}`,
      emailVerifiedAt: new Date(),
    })
    .returning();
  userIds.push(legacy.id);
  mark = warnLines.length;
  const stepUp = await api("POST", "/api/auth/stepup/request-code", { client: "ios", token: await createSession(legacy.id) });
  assert.equal(stepUp.status, 200, `native step-up code request (no body) succeeds (got ${stepUp.status})`);
  lastLoggedCode("confirmation", mark);

  // --- 9) Dev code logging is off in production and when the flag is off ------
  mark = warnLines.length;
  const prodReg = await withNodeEnv("production", () => register("prodreg"));
  assert.equal(prodReg.res.status, 200);
  const prodForgot = await withNodeEnv("production", () =>
    api("POST", "/api/auth/forgot-password", { body: { email: tfa.email } }),
  );
  assert.equal(prodForgot.status, 200);
  const afterProd = warnLines.slice(mark);
  assert.equal(
    afterProd.filter((l) => l.includes("[DEV ONLY]") || /\b\d{6}\b/.test(l)).length,
    0,
    `no code is logged in production (got: ${JSON.stringify(afterProd)})`,
  );
  assert.ok(
    warnLines.some((l) => l.includes("DEV_LOG_EMAIL_CODES is ignored in production")),
    "production warns that DEV_LOG_EMAIL_CODES is ignored",
  );

  delete process.env.DEV_LOG_EMAIL_CODES;
  const before = devCodeLines().length;
  await register("noflag");
  assert.equal(devCodeLines().length, before, "no code is logged when DEV_LOG_EMAIL_CODES is unset");

  console.log(`✓ Native session + dev codes + offline faucet HTTP e2e passed (runId=${runId})`);
}

let failed = false;
try {
  await run();
} catch (e) {
  failed = true;
  console.error(`✗ Native session HTTP e2e FAILED (runId=${runId})\n`, e);
} finally {
  logger.warn = originalWarn;
  try {
    // Faucet deposits wrote ledger postings (append-only), so tear down with the
    // owner-only purge that removes them together with the users.
    await purgeTestData({ userIds });
  } catch (e) {
    failed = true;
    console.error("cleanup failed", e);
  }
  await new Promise<void>((resolve) => server.close(() => resolve()));
  await pool.end();
}

process.exit(failed ? 1 : 0);
