import { createHash, randomInt, timingSafeEqual } from "node:crypto";
import { and, eq, lt, sql } from "drizzle-orm";
import { db, emailVerificationCodesTable } from "@workspace/db";
import { sendEmail, brandedEmail } from "./email";

/**
 * One-time, 6-digit email verification codes. The plaintext is emailed once;
 * only its SHA-256 hash is persisted. A user holds at most one live code (a new
 * code deletes prior ones). Codes expire after 15 minutes; a 30s per-user
 * cooldown throttles resend abuse.
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
 * Issue a fresh code for a user and email it. Returns false (without sending)
 * when a code was issued within the cooldown window, so callers can surface a
 * "please wait" message without leaking timing to anonymous callers.
 */
export async function issueVerificationCode(
  userId: string,
  email: string,
  name: string,
): Promise<boolean> {
  const [recent] = await db
    .select()
    .from(emailVerificationCodesTable)
    .where(eq(emailVerificationCodesTable.userId, userId));
  if (recent && Date.now() - recent.createdAt.getTime() < RESEND_COOLDOWN_MS) {
    return false;
  }

  const code = generateCode();
  await db.delete(emailVerificationCodesTable).where(eq(emailVerificationCodesTable.userId, userId));
  await db.insert(emailVerificationCodesTable).values({
    userId,
    codeHash: hashCode(code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
  });

  await sendEmail({
    to: email,
    subject: "Your MoolaHub verification code",
    html: brandedEmail({
      heading: "Verify your email",
      body: `Hi ${name}, your MoolaHub verification code is ${code}. It expires in 15 minutes. If you didn't request this, you can ignore this email.`,
    }),
    text: `Your MoolaHub verification code is ${code}. It expires in 15 minutes.`,
  });
  return true;
}

/**
 * Verify and consume a code for a user. Returns true only if a live, matching
 * code existed; the code is deleted on success. Constant-time comparison.
 */
export async function consumeVerificationCode(userId: string, code: string): Promise<boolean> {
  await db
    .delete(emailVerificationCodesTable)
    .where(lt(emailVerificationCodesTable.expiresAt, new Date()));

  return db.transaction(async (tx) => {
    // Row-level lock serializes concurrent consume attempts for this user so
    // the check-then-delete/increment sequence below is effectively atomic.
    const [row] = await tx
      .select()
      .from(emailVerificationCodesTable)
      .where(eq(emailVerificationCodesTable.userId, userId))
      .for("update");
    if (!row || row.expiresAt < new Date()) return false;

    // Already exhausted: invalidate and force a fresh code.
    if (row.attempts >= MAX_ATTEMPTS) {
      await tx.delete(emailVerificationCodesTable).where(eq(emailVerificationCodesTable.id, row.id));
      return false;
    }

    const candidate = Buffer.from(hashCode(code), "hex");
    const stored = Buffer.from(row.codeHash, "hex");
    const ok = candidate.length === stored.length && timingSafeEqual(candidate, stored);
    if (!ok) {
      const [updated] = await tx
        .update(emailVerificationCodesTable)
        .set({ attempts: sql`${emailVerificationCodesTable.attempts} + 1` })
        .where(eq(emailVerificationCodesTable.id, row.id))
        .returning({ attempts: emailVerificationCodesTable.attempts });
      // Burn the code once the attempt budget is spent.
      if (updated && updated.attempts >= MAX_ATTEMPTS) {
        await tx.delete(emailVerificationCodesTable).where(eq(emailVerificationCodesTable.id, row.id));
      }
      return false;
    }

    await tx
      .delete(emailVerificationCodesTable)
      .where(and(eq(emailVerificationCodesTable.id, row.id)));
    return true;
  });
}
