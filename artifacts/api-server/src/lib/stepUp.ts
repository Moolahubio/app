import { db, usersTable } from "@workspace/db";
import { eq } from "drizzle-orm";
import { verifyPassword } from "./password";
import { verifyTwoFactorCode } from "./twofactor";
import { consumeReauthCode } from "./reauth";

/**
 * Step-up reauthentication for enrolling/replacing durable login factors.
 *
 * A stolen `moolahub_session` cookie alone must never be enough to bind a new
 * long-lived login method (passkey, Privy link, first password) to an account
 * — that would let a transient session compromise turn into permanent account
 * takeover. Every enrollment route must call `verifyStepUp` with fresh proof
 * of an *existing* factor before making the change:
 *
 *  - Account has a password           -> current password must be supplied.
 *  - Else account has TOTP 2FA        -> a live TOTP/backup code must be supplied.
 *  - Else (no password, no 2FA — e.g. a Privy-only account) -> a short-lived
 *    email confirmation code must be supplied (requested via
 *    POST /auth/stepup/request-code).
 *
 * This mirrors how /auth/password already re-verifies the current password
 * before a rotation; this helper generalizes that check to every route that
 * can add a new way to log in, and covers the passwordless/2FA-less case that
 * previously had no check at all.
 */

export type StepUpProof = {
  currentPassword?: string | null;
  twoFactorCode?: string | null;
  reauthCode?: string | null;
};

export type StepUpResult =
  | { ok: true }
  | { ok: false; status: number; error: string };

type UserRow = typeof usersTable.$inferSelect;

export async function verifyStepUp(user: UserRow, proof: StepUpProof): Promise<StepUpResult> {
  if (user.passwordHash) {
    const supplied = proof.currentPassword ?? "";
    if (!supplied) {
      return { ok: false, status: 401, error: "Please confirm your password to continue." };
    }
    const ok = await verifyPassword(supplied, user.passwordHash);
    if (!ok) return { ok: false, status: 401, error: "Your password is incorrect." };
    return { ok: true };
  }

  if (user.twoFactorEnabled) {
    const supplied = proof.twoFactorCode ?? "";
    if (!supplied) {
      return { ok: false, status: 401, error: "Please enter your two-factor code to continue." };
    }
    const result = verifyTwoFactorCode(supplied, user.twoFactorSecret, user.twoFactorBackupCodes ?? null);
    if (!result.ok) {
      return { ok: false, status: 401, error: "That two-factor code didn't match." };
    }
    if (result.remainingBackupHashes) {
      await db
        .update(usersTable)
        .set({ twoFactorBackupCodes: result.remainingBackupHashes })
        .where(eq(usersTable.id, user.id));
    }
    return { ok: true };
  }

  const supplied = proof.reauthCode ?? "";
  if (!supplied) {
    return {
      ok: false,
      status: 401,
      error: "Please confirm the code we emailed you to continue. Request one from POST /auth/stepup/request-code.",
    };
  }
  const ok = await consumeReauthCode(user.id, supplied);
  if (!ok) return { ok: false, status: 401, error: "That code is invalid or has expired." };
  return { ok: true };
}
