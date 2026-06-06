import { pgTable, text, timestamp, uuid, integer, boolean, unique } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

/**
 * Savings Streaks — a derived, non-financial projection over real save events
 * (goal allocations and circle contributions). The double-entry ledger remains
 * the source of truth for money; nothing here moves or stores balances.
 *
 * One streak row per (user, commitment). A "save" anywhere inside a period keeps
 * the flame; amount is irrelevant. Periods are evaluated in the user's timezone.
 */
export const streaksTable = pgTable("streaks", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }),
  commitmentType: text("commitment_type").notNull(), // 'goal' | 'circle'
  commitmentId: uuid("commitment_id").notNull(),
  frequency: text("frequency").notNull(), // weekly | biweekly | monthly
  startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
  currentCount: integer("current_count").notNull().default(0),
  bestCount: integer("best_count").notNull().default(0),
  status: text("status").notNull().default("active"), // active | frozen | paused | broken
  currentPeriodStart: timestamp("current_period_start", { withTimezone: true }).notNull(),
  currentPeriodEnd: timestamp("current_period_end", { withTimezone: true }).notNull(),
  currentPeriodSatisfied: boolean("current_period_satisfied").notNull().default(false),
  lastSaveRef: text("last_save_ref"), // tx id (goal) or contribution id (circle)
  // Dedup marker so at most one reminder is enqueued per (streak, period).
  reminderSentPeriodStart: timestamp("reminder_sent_period_start", { withTimezone: true }),
  archivedAt: timestamp("archived_at", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => ({
  uniqStreak: unique().on(t.userId, t.commitmentType, t.commitmentId),
}));

/**
 * Append-only outcome log, one row per closed period. Idempotent via the
 * (streakId, periodStart) unique constraint so the daily job never double-counts
 * or double-breaks a period.
 */
export const streakPeriodsTable = pgTable("streak_periods", {
  id: uuid("id").primaryKey().defaultRandom(),
  streakId: uuid("streak_id").notNull().references(() => streaksTable.id, { onDelete: "cascade" }),
  periodStart: timestamp("period_start", { withTimezone: true }).notNull(),
  periodEnd: timestamp("period_end", { withTimezone: true }).notNull(),
  outcome: text("outcome").notNull(), // saved | frozen | paused | missed
  saveCount: integer("save_count").notNull().default(0),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => ({
  uniqPeriod: unique().on(t.streakId, t.periodStart),
}));

/**
 * Freeze allowance, one row per user. Accrual is calendar-based: grant 1 every
 * 3 months (cap 4/year); enforce "<= 1 used per rolling 3-month window" via
 * lastUsedAt. Never purchasable.
 */
export const streakFreezesTable = pgTable("streak_freezes", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
  balance: integer("balance").notNull().default(0),
  lastGrantedAt: timestamp("last_granted_at", { withTimezone: true }),
  lastUsedAt: timestamp("last_used_at", { withTimezone: true }),
  grantedTotal: integer("granted_total").notNull().default(0),
  usedTotal: integer("used_total").notNull().default(0),
  // Enforce the "max 4 freezes per calendar year" cap (user timezone).
  grantYear: integer("grant_year"),
  grantsThisYear: integer("grants_this_year").notNull().default(0),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

/**
 * Cosmetic, persistent badges. Earned by calendar duration of an unbroken
 * streak (3 months => 1 badge, 4/year). (year, quarterIndex) is the collectible
 * slot; badgeKey encodes the yearly-unique design. Earned badges persist forever.
 */
export const streakBadgesTable = pgTable("streak_badges", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }),
  badgeKey: text("badge_key").notNull(),
  year: integer("year").notNull(),
  quarterIndex: integer("quarter_index").notNull(), // 1..4
  earnedAt: timestamp("earned_at", { withTimezone: true }).notNull().defaultNow(),
  sourceCommitmentId: uuid("source_commitment_id"),
}, (t) => ({
  uniqBadge: unique().on(t.userId, t.year, t.quarterIndex),
}));

export const insertStreakSchema = createInsertSchema(streaksTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertStreakPeriodSchema = createInsertSchema(streakPeriodsTable).omit({ id: true, createdAt: true });
export const insertStreakFreezeSchema = createInsertSchema(streakFreezesTable).omit({ id: true, updatedAt: true });
export const insertStreakBadgeSchema = createInsertSchema(streakBadgesTable).omit({ id: true, earnedAt: true });

export type InsertStreak = z.infer<typeof insertStreakSchema>;
export type Streak = typeof streaksTable.$inferSelect;
export type StreakPeriod = typeof streakPeriodsTable.$inferSelect;
export type StreakFreeze = typeof streakFreezesTable.$inferSelect;
export type StreakBadge = typeof streakBadgesTable.$inferSelect;
