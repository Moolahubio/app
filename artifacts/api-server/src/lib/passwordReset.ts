import { createHash, randomInt, timingSafeEqual } from "node:crypto";
import { and, eq, lt, sql } from "drizzle-orm";
import { db, passwordResetCodesTable } from "@workspace/db";
import { sendEmail, brandedEmail } from "./email";

/**
 * One-time, 6-digit password reset codes. Mirrors the email verification code
 * design: the plaintext is emailed once; only its SHA-256 hash is persisted. A
 * user holds at most one live reset code (a new code deletes prior ones). Codes
 * expire after 15 minutes; a 30s per-user cooldown throttles resend abuse, and a
 * code is burned after a fixed number of failed attempts.
 */
const CODE_TTL_MS = 15 * 60 * 1000;
const RESEND_COOLDOWN_MS = 30 * 1000;
// A code is invalidated after this many failed attempts, forcing the user to
// request a fresh one. This caps online guessing well below the 1e6 code space.
const MAX_ATTEMPTS = 5;

function hashCode(code: string): string {
  return createHash("sha256").update(code.trim()).digest("hex");
}

function generateCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}

/**
 * Issue a fresh reset code for a user and email it. Returns false (without
 * sending) when a code was issued within the cooldown window, so callers can
 * throttle without leaking timing to anonymous callers.
 */
export async function issuePasswordResetCode(
  userId: string,
  email: string,
  name: string,
): Promise<boolean> {
  const [recent] = await db
    .select()
    .from(passwordResetCodesTable)
    .where(eq(passwordResetCodesTable.userId, userId));
  if (recent && Date.now() - recent.createdAt.getTime() < RESEND_COOLDOWN_MS) {
    return false;
  }

  const code = generateCode();
  await db.delete(passwordResetCodesTable).where(eq(passwordResetCodesTable.userId, userId));
  await db.insert(passwordResetCodesTable).values({
    userId,
    codeHash: hashCode(code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
  });

  await sendEmail({
    to: email,
    subject: "Reset your MoolaHub password",
    html: brandedEmail({
      heading: "Reset your password",
      body: `Hi ${name}, your MoolaHub password reset code is ${code}. It expires in 15 minutes. If you didn't request this, you can safely ignore this email — your password won't change.`,
    }),
    text: `Your MoolaHub password reset code is ${code}. It expires in 15 minutes.`,
  });
  return true;
}

/**
 * Verify and consume a reset code for a user. Returns true only if a live,
 * matching code existed; the code is deleted on success. Constant-time
 * comparison, with the same brute-force burn as email verification.
 */
export async function consumePasswordResetCode(userId: string, code: string): Promise<boolean> {
  await db
    .delete(passwordResetCodesTable)
    .where(lt(passwordResetCodesTable.expiresAt, new Date()));

  return db.transaction(async (tx) => {
    // Row-level lock serializes concurrent consume attempts for this user so
    // the check-then-delete/increment sequence below is effectively atomic.
    const [row] = await tx
      .select()
      .from(passwordResetCodesTable)
      .where(eq(passwordResetCodesTable.userId, userId))
      .for("update");
    if (!row || row.expiresAt < new Date()) return false;

    // Already exhausted: invalidate and force a fresh code.
    if (row.attempts >= MAX_ATTEMPTS) {
      await tx.delete(passwordResetCodesTable).where(eq(passwordResetCodesTable.id, row.id));
      return false;
    }

    const candidate = Buffer.from(hashCode(code), "hex");
    const stored = Buffer.from(row.codeHash, "hex");
    const ok = candidate.length === stored.length && timingSafeEqual(candidate, stored);
    if (!ok) {
      const [updated] = await tx
        .update(passwordResetCodesTable)
        .set({ attempts: sql`${passwordResetCodesTable.attempts} + 1` })
        .where(eq(passwordResetCodesTable.id, row.id))
        .returning({ attempts: passwordResetCodesTable.attempts });
      // Burn the code once the attempt budget is spent.
      if (updated && updated.attempts >= MAX_ATTEMPTS) {
        await tx.delete(passwordResetCodesTable).where(eq(passwordResetCodesTable.id, row.id));
      }
      return false;
    }

    await tx
      .delete(passwordResetCodesTable)
      .where(and(eq(passwordResetCodesTable.id, row.id)));
    return true;
  });
}
