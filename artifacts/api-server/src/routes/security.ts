import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, usersTable } from "@workspace/db";
import {
  GetTwoFactorStatusResponse,
  SetupTwoFactorBody,
  SetupTwoFactorResponse,
  EnableTwoFactorBody,
  EnableTwoFactorResponse,
  DisableTwoFactorBody,
  DisableTwoFactorResponse,
  RegenerateBackupCodesBody,
  RegenerateBackupCodesResponse,
} from "@workspace/api-zod";
import { requireAuth, type AuthRequest } from "../lib/auth";
import { requireAllowedOrigin, requireJsonAndAllowedOrigin } from "../lib/origins";
import { verifyStepUp } from "../lib/stepUp";
import {
  generateTotpSecret,
  totpKeyUri,
  totpQrDataUrl,
  verifyTotp,
  encryptTotpSecret,
  decryptTotpSecret,
  generateBackupCodes,
  verifyTwoFactorCode,
} from "../lib/twofactor";

const router: IRouter = Router();

router.get("/security/2fa", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  res.json(
    GetTwoFactorStatusResponse.parse({
      enabled: user.twoFactorEnabled,
      backupCodesRemaining: user.twoFactorEnabled ? (user.twoFactorBackupCodes?.length ?? 0) : 0,
    }),
  );
});

// Begin setup: generate (or re-use a not-yet-confirmed) secret and return a QR.
// The secret is stored encrypted but 2FA stays disabled until /enable confirms a code.
router.post("/security/2fa/setup", requireAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  if (user.twoFactorEnabled) {
    res.status(400).json({ error: "Two-factor authentication is already enabled." });
    return;
  }

  // Enrolling 2FA is minting a new durable login factor — possession of the
  // session cookie alone must not be enough (a stolen session on a passwordless
  // account could otherwise enroll attacker-controlled TOTP and use it to take
  // over the account, see /auth/password's step-up fallback). Require proof of
  // an existing factor (password, or emailed reauth code) up front, before even
  // generating the secret.
  const parsed = SetupTwoFactorBody.safeParse(req.body ?? {});
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
    return;
  }

  const secret = generateTotpSecret();
  await db
    .update(usersTable)
    .set({ twoFactorSecret: encryptTotpSecret(secret) })
    .where(eq(usersTable.id, user.id));

  const accountLabel = user.email && !user.email.endsWith("@privy.moolahub") ? user.email : user.name;
  const otpauthUrl = totpKeyUri(accountLabel, secret);
  const qrDataUrl = await totpQrDataUrl(otpauthUrl);

  res.json(SetupTwoFactorResponse.parse({ secret, otpauthUrl, qrDataUrl }));
});

// Confirm the pending secret with a live code, enable 2FA, and return backup codes once.
router.post("/security/2fa/enable", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = EnableTwoFactorBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (user.twoFactorEnabled) {
    res.status(400).json({ error: "Two-factor authentication is already enabled." });
    return;
  }
  if (!user.twoFactorSecret) {
    res.status(400).json({ error: "Start setup first." });
    return;
  }

  // Same step-up requirement as /setup: confirming the TOTP code proves
  // possession of the authenticator, but not possession of an *existing*
  // login factor — a stolen session could otherwise complete enrollment on
  // its own. Require the same proof again here so a session that only made
  // it through /setup (e.g. via a still-valid but now-stale reauth code)
  // can't finish enrollment without it.
  const stepUp = await verifyStepUp(user, parsed.data);
  if (!stepUp.ok) {
    res.status(stepUp.status).json({ error: stepUp.error });
    return;
  }

  let secret: string;
  try {
    secret = decryptTotpSecret(user.twoFactorSecret);
  } catch {
    res.status(400).json({ error: "Setup expired. Please start again." });
    return;
  }

  if (!verifyTotp(parsed.data.code, secret)) {
    res.status(400).json({ error: "That code didn't match. Check your authenticator app and try again." });
    return;
  }

  const { codes, hashes } = generateBackupCodes();
  await db
    .update(usersTable)
    .set({ twoFactorEnabled: true, twoFactorBackupCodes: hashes })
    .where(eq(usersTable.id, user.id));

  res.json(EnableTwoFactorResponse.parse({ backupCodes: codes }));
});

router.post("/security/2fa/disable", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = DisableTwoFactorBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (!user.twoFactorEnabled) {
    res.status(400).json({ error: "Two-factor authentication is not enabled." });
    return;
  }

  const result = verifyTwoFactorCode(parsed.data.code, user.twoFactorSecret, user.twoFactorBackupCodes ?? null);
  if (!result.ok) {
    res.status(400).json({ error: "That code didn't match. Try a current code or a backup code." });
    return;
  }

  await db
    .update(usersTable)
    .set({ twoFactorEnabled: false, twoFactorSecret: null, twoFactorBackupCodes: null })
    .where(eq(usersTable.id, user.id));

  res.json(DisableTwoFactorResponse.parse({ ok: true }));
});

router.post("/security/2fa/backup-codes", requireJsonAndAllowedOrigin, requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = RegenerateBackupCodesBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }
  if (!user.twoFactorEnabled) {
    res.status(400).json({ error: "Two-factor authentication is not enabled." });
    return;
  }

  const result = verifyTwoFactorCode(parsed.data.code, user.twoFactorSecret, user.twoFactorBackupCodes ?? null);
  if (!result.ok) {
    res.status(400).json({ error: "That code didn't match. Try a current code or a backup code." });
    return;
  }

  const { codes, hashes } = generateBackupCodes();
  await db
    .update(usersTable)
    .set({ twoFactorBackupCodes: hashes })
    .where(eq(usersTable.id, user.id));

  res.json(RegenerateBackupCodesResponse.parse({ backupCodes: codes }));
});

export default router;
