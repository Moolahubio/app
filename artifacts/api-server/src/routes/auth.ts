import { Router, type IRouter, type Request, type Response, type NextFunction } from "express";
import { and, eq, ne, sql } from "drizzle-orm";
import { db, usersTable, sessionsTable } from "@workspace/db";
import {
  PrivyAuthBody,
  PrivyAuthResponse,
  TwoFactorLoginBody,
  TwoFactorLoginResponse,
  LogoutResponse,
  GetMeResponse,
  RegisterBody,
  RegisterResponse,
  LoginBody,
  LoginResponse,
  VerifyEmailBody,
  VerifyEmailResponse,
  ResendVerificationCodeBody,
  ResendVerificationCodeResponse,
  UsernameAvailableResponse,
  LinkPrivyBody,
  LinkPrivyResponse,
  ChangePasswordBody,
  ChangePasswordResponse,
  ForgotPasswordBody,
  ForgotPasswordResponse,
  ResetPasswordBody,
  ResetPasswordResponse,
} from "@workspace/api-zod";
import {
  requireAuth,
  createSession,
  sessionTtlMs,
  type AuthRequest,
} from "../lib/auth";
import { createWalletForUser, getWalletForUser } from "../lib/wallet";
import { privyEnabled, verifyPrivyToken, getPrivyProfile } from "../lib/privy";
import { hashPassword, verifyPassword, DUMMY_PASSWORD_HASH } from "../lib/password";
import { issueVerificationCode, consumeVerificationCode } from "../lib/emailVerification";
import { issuePasswordResetCode, consumePasswordResetCode } from "../lib/passwordReset";
import { sendPasswordChangedEmail } from "../lib/email";
import { loginLockoutRemaining, recordFailedLogin, clearLoginAttempts } from "../lib/loginThrottle";
import { resetThrottleRemaining, recordResetRequest } from "../lib/resetThrottle";
import { isUniqueViolation } from "../lib/dbErrors";
import { isAllowedOrigin, isSameOrigin, requireAllowedOrigin } from "../lib/origins";
import { verifyStepUp } from "../lib/stepUp";
import { issueReauthCode } from "../lib/reauth";
import {
  createTwoFactorChallenge,
  getTwoFactorChallenge,
  deleteTwoFactorChallenge,
  consumeTwoFactorChallenge,
  verifyTwoFactorCode,
} from "../lib/twofactor";

const router: IRouter = Router();

/**
 * CSRF guard for session-establishing endpoints.
 *
 * Two complementary checks:
 *  1. Content-Type must be `application/json`.  HTML forms can only submit
 *     application/x-www-form-urlencoded, multipart/form-data, or text/plain —
 *     never JSON — so this alone blocks every cross-site form attack.
 *  2. If an `Origin` header is present (browsers always include it on POSTs,
 *     even same-origin ones) it must either match the host the request was
 *     served on (same-origin) or appear in the allowlist (ALLOWED_ORIGINS +
 *     REPLIT_DOMAINS). This closes the gap for any future path that could
 *     accept non-JSON bodies, without requiring manual origin configuration.
 */
function requireJsonAndAllowedOrigin(req: Request, res: Response, next: NextFunction): void {
  if (!req.is("application/json")) {
    res.status(415).json({ error: "Content-Type must be application/json" });
    return;
  }

  const origin = req.headers["origin"];
  if (origin && !isSameOrigin(req) && !isAllowedOrigin(origin)) {
    res.status(403).json({ error: "Forbidden" });
    return;
  }

  next();
}

const COOKIE = "moolahub_session";
// Base cookie attributes; `maxAge` is set per-login to match the session TTL
// (7 days by default, 30 with "keep me logged in").
const cookieOpts = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax" as const,
};

const USERNAME_RE = /^[a-zA-Z0-9_]{3,30}$/;
const MIN_PASSWORD = 8;
const REFERRAL_SOURCES = [
  "Twitter",
  "Telegram",
  "WhatsApp",
  "Discord",
  "LinkedIn",
  "Friends",
  "Others",
];

type UserRow = typeof usersTable.$inferSelect;

/** Public, session-bearing user shape returned after a successful login. */
function authUserFields(user: UserRow, walletAddress: string | null) {
  return {
    id: user.id,
    name: user.name,
    email: user.email,
    username: user.username ?? null,
    avatarUrl: user.avatarUrl ?? null,
    hasWallet: !!walletAddress,
    walletAddress: walletAddress ?? null,
    hasPassword: !!user.passwordHash,
    privyLinked: !!user.privyDid,
    emailVerified: !!user.emailVerifiedAt,
  };
}

/**
 * Complete a primary-auth login: clear any deactivation, mint a session +
 * cookie, and return the LoginResult payload. Callers must already have
 * verified credentials (and any 2FA second factor).
 *
 * No wallet is provisioned here. A wallet is created only when the user
 * explicitly opts in via the "Continue with Privy" flow (POST /auth/privy/link)
 * from the Wallet section, so accounts start without one.
 */
async function finishLogin(res: Response, user: UserRow, rememberMe: boolean) {
  if (user.deactivatedAt) {
    await db.update(usersTable).set({ deactivatedAt: null }).where(eq(usersTable.id, user.id));
  }
  const wallet = await getWalletForUser(user.id);
  const token = await createSession(user.id, rememberMe);
  res.cookie(COOKIE, token, { ...cookieOpts, maxAge: sessionTtlMs(rememberMe) });
  return { twoFactorRequired: false, ...authUserFields(user, wallet?.address ?? null) };
}

/** Case-insensitive username clash check, optionally excluding one user id. */
async function usernameTaken(username: string, excludeUserId?: string): Promise<boolean> {
  const [clash] = await db
    .select({ id: usersTable.id })
    .from(usersTable)
    .where(
      and(
        sql`lower(${usersTable.username}) = ${username}`,
        excludeUserId ? ne(usersTable.id, excludeUserId) : undefined,
      ),
    );
  return !!clash;
}

function isValidPastDate(dob: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dob)) return false;
  const d = new Date(`${dob}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return false;
  return d.getTime() < Date.now();
}

router.post("/auth/logout", requireAllowedOrigin, async (req, res): Promise<void> => {
  const token = req.cookies?.[COOKIE] ?? req.headers["x-session-token"];
  if (token) {
    await db.delete(sessionsTable).where(eq(sessionsTable.token, token as string));
  }
  res.clearCookie(COOKIE);
  res.json(LogoutResponse.parse({ ok: true }));
});

router.get("/auth/me", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await getWalletForUser(user.id);
  res.json(GetMeResponse.parse(authUserFields(user, wallet?.address ?? null)));
});

// --------------------------------------------------------- email + password

router.post("/auth/register", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = RegisterBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const name = parsed.data.name.trim();
  const email = parsed.data.email.trim().toLowerCase();
  const username = parsed.data.username.trim().toLowerCase();
  const { password, dateOfBirth } = parsed.data;
  const referralSource = parsed.data.referralSource ?? null;

  if (!name) {
    res.status(400).json({ error: "Please enter your legal name." });
    return;
  }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    res.status(400).json({ error: "Please enter a valid email address." });
    return;
  }
  if (!USERNAME_RE.test(username)) {
    res.status(400).json({ error: "Username must be 3–30 characters: letters, numbers, or underscores." });
    return;
  }
  if (password.length < MIN_PASSWORD) {
    res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD} characters.` });
    return;
  }
  if (!isValidPastDate(dateOfBirth)) {
    res.status(400).json({ error: "Please enter a valid date of birth." });
    return;
  }
  if (referralSource && !REFERRAL_SOURCES.includes(referralSource)) {
    res.status(400).json({ error: "Invalid referral source." });
    return;
  }

  const [existing] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  if (existing && existing.emailVerifiedAt) {
    res.status(409).json({ error: "An account with this email already exists. Please sign in." });
    return;
  }
  if (await usernameTaken(username, existing?.id)) {
    res.status(409).json({ error: "That username is already taken." });
    return;
  }

  const passwordHash = await hashPassword(password);

  let user: UserRow;
  try {
    if (existing) {
      // Re-registering an account that never finished email verification: refresh
      // its details and issue a new code.
      [user] = await db
        .update(usersTable)
        .set({ name, username, passwordHash, dateOfBirth, referralSource })
        .where(eq(usersTable.id, existing.id))
        .returning();
    } else {
      [user] = await db
        .insert(usersTable)
        .values({ name, email, username, passwordHash, dateOfBirth, referralSource })
        .returning();
    }
  } catch (err) {
    // The case-insensitive unique index is the source of truth — the pre-check
    // above is just UX. A concurrent registration that wins the race surfaces
    // here as a unique violation and must map to a clean 409, not a 500.
    if (isUniqueViolation(err)) {
      res.status(409).json({ error: "That username is already taken." });
      return;
    }
    throw err;
  }

  await issueVerificationCode(user.id, email, name);
  res.json(RegisterResponse.parse({ emailVerificationRequired: true, email }));
});

router.post("/auth/login", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = LoginBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const email = parsed.data.email.trim().toLowerCase();
  const rememberMe = parsed.data.rememberMe === true;
  const ip = req.ip || "unknown";

  const locked = loginLockoutRemaining(email, ip);
  if (locked !== null) {
    res.status(429).json({ error: "Too many failed attempts. Please try again later." });
    return;
  }

  const [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  // Verify against a decoy hash when there is no account/password, so scrypt runs
  // (and latency is constant) regardless of whether the email exists — the login
  // response must stay non-enumerating, matching forgot-password/resend-code.
  const ok = await verifyPassword(parsed.data.password, user?.passwordHash ?? DUMMY_PASSWORD_HASH);
  if (!user || user.deletedAt || !user.passwordHash || !ok) {
    recordFailedLogin(email, ip);
    res.status(401).json({ error: "Invalid email or password." });
    return;
  }

  clearLoginAttempts(email, ip);

  if (!user.emailVerifiedAt) {
    await issueVerificationCode(user.id, email, user.name);
    res.json(LoginResponse.parse({ twoFactorRequired: false, emailVerificationRequired: true, email }));
    return;
  }

  if (user.twoFactorEnabled) {
    const challengeId = await createTwoFactorChallenge(user.id, rememberMe);
    res.json(LoginResponse.parse({ twoFactorRequired: true, challengeId }));
    return;
  }

  res.json(LoginResponse.parse(await finishLogin(res, user, rememberMe)));
});

router.post("/auth/verify-email", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = VerifyEmailBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const email = parsed.data.email.trim().toLowerCase();
  const rememberMe = parsed.data.rememberMe === true;

  const [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  if (!user) {
    res.status(400).json({ error: "That code is invalid or has expired." });
    return;
  }
  if (user.emailVerifiedAt) {
    res.status(400).json({ error: "This email is already verified. Please sign in." });
    return;
  }

  const verified = await consumeVerificationCode(user.id, parsed.data.code);
  if (!verified) {
    res.status(400).json({ error: "That code is invalid or has expired." });
    return;
  }

  const [updated] = await db
    .update(usersTable)
    .set({ emailVerifiedAt: new Date() })
    .where(eq(usersTable.id, user.id))
    .returning();

  if (updated.twoFactorEnabled) {
    const challengeId = await createTwoFactorChallenge(updated.id, rememberMe);
    res.json(VerifyEmailResponse.parse({ twoFactorRequired: true, challengeId }));
    return;
  }

  res.json(VerifyEmailResponse.parse(await finishLogin(res, updated, rememberMe)));
});

router.post("/auth/resend-code", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = ResendVerificationCodeBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const email = parsed.data.email.trim().toLowerCase();
  const [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  // Never reveal whether an account exists / is already verified.
  if (user && !user.emailVerifiedAt) {
    await issueVerificationCode(user.id, email, user.name);
  }
  res.json(ResendVerificationCodeResponse.parse({ ok: true }));
});

// --------------------------------------------------------- forgot password

router.post("/auth/forgot-password", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = ForgotPasswordBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const email = parsed.data.email.trim().toLowerCase();
  const ip = req.ip || "unknown";

  // Throttle per IP + per email to stop email-bombing (flooding reset emails by
  // rotating addresses), on top of the per-user resend cooldown. The 429 is
  // generic and identical for any email, so it never reveals account existence.
  const locked = resetThrottleRemaining("forgot", ip, email);
  if (locked !== null) {
    res.status(429).json({ error: "Too many requests. Please try again later." });
    return;
  }
  recordResetRequest("forgot", ip, email);

  const [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));

  // Product decision: tell the user plainly when no account matches that email,
  // instead of the silent always-{ok:true}. Email harvesting is mitigated by the
  // per-IP/per-email throttle above (a generic 429), so this cannot be abused to
  // enumerate accounts at scale.
  if (!user || user.deletedAt) {
    res.status(404).json({ error: "We couldn't find an account with that email address." });
    return;
  }

  // A passwordless (legacy Privy / social) account is still never issued a reset
  // code: email control alone must not mint a password login, or an email
  // compromise would bypass the social provider. Point them to their existing
  // sign-in method; they can add a password afterwards from account settings.
  if (!user.passwordHash) {
    res.status(409).json({
      error:
        "This account doesn't use a password yet. Sign in the way you joined, then add a password from your account settings.",
    });
    return;
  }

  await issuePasswordResetCode(user.id, email, user.name);
  res.json(ForgotPasswordResponse.parse({ ok: true }));
});

router.post("/auth/reset-password", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = ResetPasswordBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (parsed.data.newPassword.length < MIN_PASSWORD) {
    res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD} characters.` });
    return;
  }

  const email = parsed.data.email.trim().toLowerCase();
  const ip = req.ip || "unknown";

  // Per-IP throttle to slow probing of this endpoint (code brute-forcing itself
  // is already capped by the per-code attempt burn). Generic 429, no enumeration.
  const locked = resetThrottleRemaining("reset", ip, email);
  if (locked !== null) {
    res.status(429).json({ error: "Too many requests. Please try again later." });
    return;
  }
  recordResetRequest("reset", ip, email);

  const [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));
  // A reset code is only ever issued by forgot-password to a non-deleted account
  // that already has a password. Reject anything else with the same generic
  // message to avoid enumeration.
  if (!user || user.deletedAt) {
    res.status(400).json({ error: "That code is invalid or has expired." });
    return;
  }

  const ok = await consumePasswordResetCode(user.id, parsed.data.code);
  if (!ok) {
    res.status(400).json({ error: "That code is invalid or has expired." });
    return;
  }

  const passwordHash = await hashPassword(parsed.data.newPassword);
  // Proving control of the email is enough to confirm it; a reset also verifies
  // the email so the account is immediately usable.
  await db
    .update(usersTable)
    .set({ passwordHash, emailVerifiedAt: user.emailVerifiedAt ?? new Date() })
    .where(eq(usersTable.id, user.id));
  // Invalidate every existing session: a forgotten password implies the account
  // may be compromised, so force a fresh sign-in everywhere.
  await db.delete(sessionsTable).where(eq(sessionsTable.userId, user.id));

  // Security heads-up. Best-effort: never block or fail the reset on a send error.
  void sendPasswordChangedEmail(user.email, user.name).catch((e) =>
    console.error("[auth] password-changed email failed:", e),
  );

  res.json(ResetPasswordResponse.parse({ ok: true }));
});

// Issue an emailed step-up confirmation code for accounts that have neither a
// password nor TOTP 2FA enabled (the only accounts that need this fallback —
// everyone else proves possession with their existing password/2FA code
// directly on the enrollment request). Requires an authenticated session so it
// can't be used to spam arbitrary inboxes.
router.post(
  "/auth/stepup/request-code",
  requireAllowedOrigin,
  requireAuth,
  async (req, res): Promise<void> => {
    const user = (req as AuthRequest).user;
    if (user.passwordHash || user.twoFactorEnabled) {
      res.status(400).json({
        error: "Use your password or two-factor code instead of requesting an email code.",
      });
      return;
    }
    await issueReauthCode(user.id, user.email, user.name);
    // Always ok:true regardless of the cooldown, matching resend-code's shape —
    // there is nothing to enumerate here since the caller is already authenticated.
    res.json({ ok: true });
  },
);

router.get("/auth/username-available", async (req, res): Promise<void> => {
  const raw = typeof req.query.username === "string" ? req.query.username.trim().toLowerCase() : "";
  if (!USERNAME_RE.test(raw)) {
    res.json(
      UsernameAvailableResponse.parse({
        available: false,
        reason: "Username must be 3–30 characters: letters, numbers, or underscores.",
      }),
    );
    return;
  }
  const taken = await usernameTaken(raw);
  res.json(
    UsernameAvailableResponse.parse({
      available: !taken,
      reason: taken ? "That username is already taken." : null,
    }),
  );
});

// ---------------------------------------------------- change / set password

router.post("/auth/password", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = ChangePasswordBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (parsed.data.newPassword.length < MIN_PASSWORD) {
    res.status(400).json({ error: `Password must be at least ${MIN_PASSWORD} characters.` });
    return;
  }

  // A passwordless (legacy Privy) account sets its FIRST password here, from an
  // authenticated session. There is no current password to verify, so this is
  // exactly the "durable factor enrollment" case that must be step-up gated:
  // possession of the session cookie alone must not be enough to mint a
  // password login an attacker controls. verifyStepUp falls back to the
  // account's 2FA code, and then to an emailed reauth code, for accounts with
  // neither a password nor 2FA. Completing the password also stamps
  // emailVerifiedAt, finishing the account. Every other session is revoked
  // below, limiting the blast radius of a stolen session.
  if (user.passwordHash) {
    const ok = await verifyPassword(parsed.data.currentPassword ?? "", user.passwordHash);
    if (!ok) {
      res.status(401).json({ error: "Your current password is incorrect." });
      return;
    }
  } else {
    const stepUp = await verifyStepUp(user, {
      twoFactorCode: parsed.data.currentPassword,
      reauthCode: parsed.data.currentPassword,
    });
    if (!stepUp.ok) {
      res.status(stepUp.status).json({ error: stepUp.error });
      return;
    }
  }

  const passwordHash = await hashPassword(parsed.data.newPassword);
  await db
    .update(usersTable)
    .set({ passwordHash, emailVerifiedAt: user.emailVerifiedAt ?? new Date() })
    .where(eq(usersTable.id, user.id));

  // Invalidate every OTHER session so concurrent stolen sessions can't stay
  // active after a credential rotation, while keeping the current session so
  // the user stays logged in.
  const currentToken = req.cookies?.[COOKIE] ?? req.headers["x-session-token"];
  if (currentToken) {
    await db
      .delete(sessionsTable)
      .where(and(eq(sessionsTable.userId, user.id), ne(sessionsTable.token, currentToken as string)));
  } else {
    await db.delete(sessionsTable).where(eq(sessionsTable.userId, user.id));
  }

  // Security heads-up. Best-effort: never block or fail the change on a send error.
  void sendPasswordChangedEmail(user.email, user.name).catch((e) =>
    console.error("[auth] password-changed email failed:", e),
  );

  res.json(ChangePasswordResponse.parse({ ok: true }));
});

// --------------------------------------------------------------- Privy auth

router.post("/auth/privy", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = PrivyAuthBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  if (!privyEnabled()) {
    res.status(400).json({ error: "Privy sign-in is not configured." });
    return;
  }

  let did: string;
  try {
    did = await verifyPrivyToken(parsed.data.token);
  } catch {
    res.status(401).json({ error: "Invalid Privy token" });
    return;
  }

  // Identity is derived strictly from the verified Privy token (the DID) and the
  // profile fetched server-side from Privy. Client-supplied email/name are NOT
  // trusted for account linking.
  const profile = await getPrivyProfile(did).catch(() => ({}) as { email?: string; name?: string });
  const verifiedEmail = profile.email ? profile.email.toLowerCase() : null;
  const name = profile.name ?? parsed.data.name ?? "MoolaHub Member";

  let [user] = await db.select().from(usersTable).where(eq(usersTable.privyDid, did));

  // Privy is NOT a login method for password accounts — email compromise alone
  // must never grant access. A password account that has linked Privy still
  // signs in with its email + password only.
  if (user && user.passwordHash) {
    res.status(403).json({ error: "Please sign in with your email and password." });
    return;
  }

  if (!user && verifiedEmail) {
    const [byEmail] = await db.select().from(usersTable).where(eq(usersTable.email, verifiedEmail));
    if (byEmail) {
      if (byEmail.passwordHash) {
        // Don't link or log in via a Privy email-match to a password account.
        res.status(403).json({
          error:
            "An account with this email uses a password. Sign in with your email and password, then link Privy from your account settings.",
        });
        return;
      }
      // Legacy passwordless account — safe to link this DID.
      [user] = await db
        .update(usersTable)
        .set({ privyDid: did })
        .where(eq(usersTable.id, byEmail.id))
        .returning();
    }
  }

  if (!user) {
    const email = verifiedEmail ?? `${did.replace(/[^a-zA-Z0-9]/g, "")}@privy.moolahub`;
    // Privy-verified email counts as verified; synthetic placeholders do not.
    const emailVerifiedAt = verifiedEmail ? new Date() : null;
    [user] = await db.insert(usersTable).values({ name, email, privyDid: did, emailVerifiedAt }).returning();
  }

  const rememberMe = (req.body as { rememberMe?: unknown })?.rememberMe === true;

  if (user.twoFactorEnabled) {
    const challengeId = await createTwoFactorChallenge(user.id, rememberMe);
    res.json(PrivyAuthResponse.parse({ twoFactorRequired: true, challengeId }));
    return;
  }

  res.json(PrivyAuthResponse.parse(await finishLogin(res, user, rememberMe)));
});

// Link a Privy identity to the *currently signed-in* account (optional wallet
// linkage). This is the only Privy path available to password accounts.
router.post("/auth/privy/link", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = LinkPrivyBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (!privyEnabled()) {
    res.status(400).json({ error: "Privy is not configured." });
    return;
  }

  let did: string;
  try {
    did = await verifyPrivyToken(parsed.data.token);
  } catch {
    res.status(400).json({ error: "Invalid Privy token" });
    return;
  }

  // Linking (or re-linking) Privy overwrites `users.privyDid`, which is itself a
  // durable login method — a stolen session must not be able to silently swap
  // in an attacker-controlled Privy identity. Require step-up proof of an
  // existing factor first (password, 2FA code, or emailed reauth code).
  const stepUp = await verifyStepUp(user, {
    currentPassword: parsed.data.currentPassword,
    twoFactorCode: parsed.data.twoFactorCode,
    reauthCode: parsed.data.reauthCode,
  });
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
    return;
  }

  const [other] = await db.select().from(usersTable).where(eq(usersTable.privyDid, did));
  if (other && other.id !== user.id) {
    res.status(409).json({ error: "This Privy identity is already linked to another account." });
    return;
  }

  const [updated] = await db
    .update(usersTable)
    .set({ privyDid: did })
    .where(eq(usersTable.id, user.id))
    .returning();
  const wallet = await createWalletForUser(user.id);

  res.json(LinkPrivyResponse.parse(authUserFields(updated, wallet.address)));
});

// Second step of a 2FA-gated login: verify the authenticator/backup code against
// the pending challenge, then establish the session.
router.post("/auth/2fa/login", requireJsonAndAllowedOrigin, async (req, res): Promise<void> => {
  const parsed = TwoFactorLoginBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  const challenge = await getTwoFactorChallenge(parsed.data.challengeId);
  if (!challenge) {
    res.status(400).json({ error: "Your verification session expired. Please sign in again." });
    return;
  }

  const [user] = await db.select().from(usersTable).where(eq(usersTable.id, challenge.userId));
  if (!user || !user.twoFactorEnabled) {
    await deleteTwoFactorChallenge(parsed.data.challengeId);
    res.status(400).json({ error: "Two-factor authentication is not active for this account." });
    return;
  }

  const result = verifyTwoFactorCode(parsed.data.code, user.twoFactorSecret, user.twoFactorBackupCodes ?? null);
  if (!result.ok) {
    res.status(401).json({ error: "That code didn't match. Try a current code or a backup code." });
    return;
  }

  // Success — atomically consume the challenge so it can be used exactly once.
  const consumed = await consumeTwoFactorChallenge(parsed.data.challengeId);
  if (!consumed) {
    res.status(400).json({ error: "Your verification session expired. Please sign in again." });
    return;
  }

  if (result.remainingBackupHashes) {
    await db
      .update(usersTable)
      .set({ twoFactorBackupCodes: result.remainingBackupHashes })
      .where(eq(usersTable.id, user.id));
  }

  res.json(TwoFactorLoginResponse.parse(await finishLogin(res, user, consumed.rememberMe)));
});

export default router;
