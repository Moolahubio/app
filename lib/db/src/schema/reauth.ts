import { integer, pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

/**
 * Short-lived, single-use "step-up" reauthentication codes.
 *
 * Used as the fallback proof-of-possession factor when a signed-in account has
 * neither a password nor TOTP 2FA enabled (e.g. a Privy-only account) and needs
 * to prove it is still the legitimate holder of the account before enrolling a
 * new durable login method (passkey, Privy link, first password). Mirrors
 * password_reset_codes: the 6-digit code is stored only as a SHA-256 hash, the
 * plaintext is emailed once, and a user has at most one live code at a time.
 * Kept separate from email_verification_codes / password_reset_codes so an
 * in-flight step-up never collides with those unrelated flows.
 */
export const reauthCodesTable = pgTable("reauth_codes", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id")
    .notNull()
    .references(() => usersTable.id, { onDelete: "cascade" }),
  codeHash: text("code_hash").notNull(),
  attempts: integer("attempts").notNull().default(0),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const insertReauthCodeSchema = createInsertSchema(reauthCodesTable).omit({
  id: true,
  createdAt: true,
});
export type InsertReauthCode = z.infer<typeof insertReauthCodeSchema>;
export type ReauthCode = typeof reauthCodesTable.$inferSelect;
