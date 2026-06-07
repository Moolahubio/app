import { pgTable, timestamp, uuid, boolean } from "drizzle-orm/pg-core";

/**
 * Short-lived, single-use challenge issued after primary auth (Privy/passkey)
 * when the account has 2FA enabled. The client exchanges the challenge id plus a
 * TOTP/backup code for a real session. Rows are consumed on use and expire fast.
 */
export const twoFactorChallengesTable = pgTable("two_factor_challenges", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull(),
  rememberMe: boolean("remember_me").notNull().default(false),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export type TwoFactorChallenge = typeof twoFactorChallengesTable.$inferSelect;
