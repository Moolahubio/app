import { createHash, randomInt, timingSafeEqual } from "node:crypto";
import { and, eq, lt, sql } from "drizzle-orm";
import { db, reauthCodesTable } from "@workspace/db";
import { sendEmail, brandedEmail } from "./email";

/**
 * One-time, 6-digit "step-up" reauthentication codes. These prove a signed-in
 * session still belongs to the legitimate account holder when the account has
 * no password and no TOTP 2FA to check instead (see stepUp.ts). Mirrors the
 * email-verification / password-reset code design: the plaintext is emailed
 * once, only its SHA-256 hash is persisted, a user holds at most one live code,
 * codes expire after 15 minutes, and a code is burned after too many attempts.
 */
const CODE_TTL_MS = 15 * 60 * 1000;
const RESEND_COOLDOWN_MS = 30 * 1000;
const MAX_ATTEMPTS = 5;

function hashCode(code: string): string {
  return createHash("sha256").update(code.trim()).digest("hex");
}

function generateCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, "0");
}

/**
 * Issue a fresh step-up code for a user and email it. Returns false (without
 * sending) when a code was issued within the cooldown window.
 */
export async function issueReauthCode(userId: string, email: string, name: string): Promise<boolean> {
  const [recent] = await db.select().from(reauthCodesTable).where(eq(reauthCodesTable.userId, userId));
  if (recent && Date.now() - recent.createdAt.getTime() < RESEND_COOLDOWN_MS) {
    return false;
  }

  const code = generateCode();
  await db.delete(reauthCodesTable).where(eq(reauthCodesTable.userId, userId));
  await db.insert(reauthCodesTable).values({
    userId,
    codeHash: hashCode(code),
    expiresAt: new Date(Date.now() + CODE_TTL_MS),
  });

  await sendEmail({
    to: email,
    subject: "Confirm it's you — MoolaHub security code",
    html: brandedEmail({
      heading: "Confirm it's you",
      body: `Hi ${name}, someone is trying to add a new sign-in method to your MoolaHub account. Your confirmation code is ${code}. It expires in 15 minutes. If this wasn't you, do not share this code, and consider signing out of any devices you don't recognize.`,
    }),
    text: `Your MoolaHub confirmation code is ${code}. It expires in 15 minutes. If this wasn't you, do not share this code.`,
  });
  return true;
}

/**
 * Verify and consume a step-up code for a user. Returns true only if a live,
 * matching code existed; the code is deleted on success either way.
 */
export async function consumeReauthCode(userId: string, code: string): Promise<boolean> {
  await db.delete(reauthCodesTable).where(lt(reauthCodesTable.expiresAt, new Date()));

  const [row] = await db.select().from(reauthCodesTable).where(eq(reauthCodesTable.userId, userId));
  if (!row || row.expiresAt < new Date()) return false;

  if (row.attempts >= MAX_ATTEMPTS) {
    await db.delete(reauthCodesTable).where(eq(reauthCodesTable.id, row.id));
    return false;
  }

  const candidate = Buffer.from(hashCode(code), "hex");
  const stored = Buffer.from(row.codeHash, "hex");
  const ok = candidate.length === stored.length && timingSafeEqual(candidate, stored);
  if (!ok) {
    const [updated] = await db
      .update(reauthCodesTable)
      .set({ attempts: sql`${reauthCodesTable.attempts} + 1` })
      .where(eq(reauthCodesTable.id, row.id))
      .returning({ attempts: reauthCodesTable.attempts });
    if (updated && updated.attempts >= MAX_ATTEMPTS) {
      await db.delete(reauthCodesTable).where(eq(reauthCodesTable.id, row.id));
    }
    return false;
  }

  await db.delete(reauthCodesTable).where(and(eq(reauthCodesTable.id, row.id)));
  return true;
}
