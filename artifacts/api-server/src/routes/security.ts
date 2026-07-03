import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, usersTable } from "@workspace/db";
import {
  GetTwoFactorStatusResponse,
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
