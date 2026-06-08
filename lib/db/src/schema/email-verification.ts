import { integer, pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

/**
 * Short-lived, single-use email verification codes. The 6-digit code is stored
 * only as a SHA-256 hash; the plaintext is emailed once. A user has at most one
 * live code at a time (issuing a new one deletes prior codes for that user).
 */
export const emailVerificationCodesTable = pgTable("email_verification_codes", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id")
    .notNull()
    .references(() => usersTable.id, { onDelete: "cascade" }),
  codeHash: text("code_hash").notNull(),
  attempts: integer("attempts").notNull().default(0),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const insertEmailVerificationCodeSchema = createInsertSchema(emailVerificationCodesTable).omit({
  id: true,
  createdAt: true,
});
export type InsertEmailVerificationCode = z.infer<typeof insertEmailVerificationCodeSchema>;
export type EmailVerificationCode = typeof emailVerificationCodesTable.$inferSelect;
