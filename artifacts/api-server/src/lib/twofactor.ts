import { authenticator } from "otplib";
import QRCode from "qrcode";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { eq, lt } from "drizzle-orm";
import { db, twoFactorChallengesTable } from "@workspace/db";
import { encryptSecret, decryptSecret } from "./crypto";

/**
 * Authenticator-app (TOTP) two-factor authentication.
 *
 * The TOTP secret is stored encrypted at rest (AES-256-GCM via crypto.ts). Backup
 * codes are stored only as SHA-256 hashes; the plaintext set is shown to the user
 * exactly once at generation time. A small time window tolerance covers clock drift.
 */

// Allow the previous/next 30s step so minor clock drift doesn't reject valid codes.
authenticator.options = { window: 1 };

const ISSUER = "MoolaHub";

export function generateTotpSecret(): string {
  return authenticator.generateSecret();
}

export function totpKeyUri(accountName: string, secret: string): string {
  return authenticator.keyuri(accountName, ISSUER, secret);
}

export async function totpQrDataUrl(keyUri: string): Promise<string> {
  return QRCode.toDataURL(keyUri, { margin: 1, width: 240 });
}

export function verifyTotp(token: string, secret: string): boolean {
  const cleaned = token.replace(/\s+/g, "");
  if (!/^\d{6}$/.test(cleaned)) return false;
  try {
    return authenticator.verify({ token: cleaned, secret });
  } catch {
    return false;
  }
}

export function encryptTotpSecret(secret: string): string {
  return encryptSecret(secret);
}

export function decryptTotpSecret(payload: string): string {
  return decryptSecret(payload);
}

// ----------------------------------------------------------------- backup codes

const BACKUP_CODE_COUNT = 10;

function formatCode(raw: string): string {
  // 8 lowercase hex chars shown as "xxxx-xxxx" for readability.
  return `${raw.slice(0, 4)}-${raw.slice(4, 8)}`;
}

function hashCode(code: string): string {
  return createHash("sha256").update(code.replace(/[\s-]/g, "").toLowerCase()).digest("hex");
}

/** Generate fresh plaintext backup codes plus their hashes (store the hashes). */
export function generateBackupCodes(): { codes: string[]; hashes: string[] } {
  const codes: string[] = [];
  for (let i = 0; i < BACKUP_CODE_COUNT; i++) {
    codes.push(formatCode(randomBytes(4).toString("hex")));
  }
  return { codes, hashes: codes.map(hashCode) };
}

/**
 * If `code` matches one of the stored hashes, return the remaining hashes (with
 * the used one removed). Returns null when there is no match. Constant-time per
 * candidate to avoid leaking which code matched via timing.
 */
export function consumeBackupCode(code: string, hashes: string[]): string[] | null {
  const candidate = hashCode(code);
  const candidateBuf = Buffer.from(candidate, "hex");
  let matchIndex = -1;
  for (let i = 0; i < hashes.length; i++) {
    const stored = Buffer.from(hashes[i], "hex");
    if (stored.length === candidateBuf.length && timingSafeEqual(stored, candidateBuf)) {
      matchIndex = i;
    }
  }
  if (matchIndex === -1) return null;
  return hashes.filter((_, i) => i !== matchIndex);
}

// ------------------------------------------------------------- login challenges

const CHALLENGE_TTL_MS = 5 * 60 * 1000;

/** Issue a short-lived, single-use challenge after primary auth when 2FA is on. */
export async function createTwoFactorChallenge(userId: string, rememberMe: boolean): Promise<string> {
  const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS);
  const [row] = await db
    .insert(twoFactorChallengesTable)
    .values({ userId, rememberMe, expiresAt })
    .returning();
  return row.id;
}

/** Look up a live challenge (without consuming it) so the code can be retried. */
export async function getTwoFactorChallenge(
  id: string,
): Promise<{ userId: string; rememberMe: boolean } | null> {
  await db.delete(twoFactorChallengesTable).where(lt(twoFactorChallengesTable.expiresAt, new Date()));
  const [row] = await db
    .select()
    .from(twoFactorChallengesTable)
    .where(eq(twoFactorChallengesTable.id, id));
  if (!row || row.expiresAt < new Date()) return null;
  return { userId: row.userId, rememberMe: row.rememberMe };
}

/** Consume the challenge once the second factor has been verified. */
export async function deleteTwoFactorChallenge(id: string): Promise<void> {
  await db.delete(twoFactorChallengesTable).where(eq(twoFactorChallengesTable.id, id));
}

/**
 * Verify a submitted code against a user's enabled 2FA: first the TOTP secret,
 * then backup codes. Returns whether it passed and, if a backup code was used,
 * the remaining backup-code hashes to persist.
 */
export function verifyTwoFactorCode(
  code: string,
  encryptedSecret: string | null,
  backupHashes: string[] | null,
): { ok: boolean; remainingBackupHashes?: string[] } {
  const cleaned = (code ?? "").trim();
  if (!cleaned) return { ok: false };
  if (encryptedSecret) {
    try {
      if (verifyTotp(cleaned, decryptTotpSecret(encryptedSecret))) return { ok: true };
    } catch {
      /* fall through to backup codes */
    }
  }
  if (backupHashes && backupHashes.length) {
    const remaining = consumeBackupCode(cleaned, backupHashes);
    if (remaining) return { ok: true, remainingBackupHashes: remaining };
  }
  return { ok: false };
}
