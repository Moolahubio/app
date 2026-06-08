import { pgTable, text, timestamp, uuid, boolean, integer, jsonb, uniqueIndex } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";

export const usersTable = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  // Private legal name — only ever shown back to the account owner.
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  privyDid: text("privy_did").unique(),
  avatarUrl: text("avatar_url"),
  // Primary credential: argon2/scrypt-hashed password. Nullable so legacy
  // Privy-only accounts (created before email/password) can still exist and be
  // prompted to set one. Accounts WITH a passwordHash are NOT loginable via
  // Privy email-match — email compromise alone must never grant access.
  passwordHash: text("password_hash"),
  // Set once the user proves control of their email via a one-time code.
  emailVerifiedAt: timestamp("email_verified_at", { withTimezone: true }),
  // "How did you hear about MoolaHub?" — onboarding attribution.
  referralSource: text("referral_source"),
  // Public-facing handle, shown to other members instead of the legal name.
  // Uniqueness is enforced case-insensitively via a functional unique index
  // (see below), not a plain UNIQUE column, so "Alice" and "alice" can't coexist.
  username: text("username"),
  dateOfBirth: text("date_of_birth"),
  nationality: text("nationality"),
  // Notification preference tier + optional per-category custom map.
  notificationPreference: text("notification_preference").notNull().default("everything"),
  notificationPrefs: jsonb("notification_prefs").$type<Record<string, boolean>>(),
  // Account lifecycle: deactivation is reversible (cleared on next login); a set
  // deletedAt means the account was deleted (PII cleared, access revoked).
  deactivatedAt: timestamp("deactivated_at", { withTimezone: true }),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
  // Authenticator-app 2FA (TOTP). Secret is stored encrypted; backup codes hashed.
  twoFactorEnabled: boolean("two_factor_enabled").notNull().default(false),
  twoFactorSecret: text("two_factor_secret"),
  twoFactorBackupCodes: jsonb("two_factor_backup_codes").$type<string[]>(),
  // Streaks: evaluate periods/badges/freezes/vacation in the user's local tz.
  timezone: text("timezone").notNull().default("UTC"),
  streakReminderOptIn: boolean("streak_reminder_opt_in").notNull().default(false),
  // Single annual vacation that pauses streak evaluation (<=30 days, 1/year).
  vacationStart: timestamp("vacation_start", { withTimezone: true }),
  vacationEnd: timestamp("vacation_end", { withTimezone: true }),
  vacationYearUsed: integer("vacation_year_used"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => ({
  // Case-insensitive uniqueness guarantee for public handles. NULLs are allowed
  // (legacy accounts without a username yet) since NULLs don't collide.
  usernameLowerUniq: uniqueIndex("users_username_lower_unique").on(sql`lower(${t.username})`),
}));

export const insertUserSchema = createInsertSchema(usersTable).omit({ id: true, createdAt: true, updatedAt: true });
export type InsertUser = z.infer<typeof insertUserSchema>;
export type User = typeof usersTable.$inferSelect;
