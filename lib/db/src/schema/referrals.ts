import { pgTable, text, timestamp, uuid, integer, unique, index } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";
import { transactionsTable } from "./transactions";

/**
 * Refer & Earn — referral program tables.
 *
 * The double-entry ledger remains the source of truth for money: earnings are
 * held in a `referral:<userId>` ledger account and every credit/withdrawal is a
 * ledger transaction. These tables carry the program-specific relationships and
 * an idempotent accrual log; they never store balances directly.
 */

/** One immutable code per user (generated on first visit to Refer & Earn). */
export const referralCodesTable = pgTable("referral_codes", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
  code: text("code").notNull().unique(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * One attributed sign-up. `refereeId` is unique — a person has exactly one
 * referrer, locked in at sign-up and never reassigned. Self-referral is rejected
 * before insert.
 */
export const referralsTable = pgTable("referrals", {
  id: uuid("id").primaryKey().defaultRandom(),
  referrerId: uuid("referrer_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }),
  refereeId: uuid("referee_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => ({
  byReferrer: index("referrals_referrer_idx").on(t.referrerId),
}));

/**
 * Accrual log — one row per PROCESSED confirmed fee transaction, keyed uniquely
 * on `sourceTransactionId` so the idempotent sweep can never double-credit and
 * never re-scans a fee it already handled.
 *
 * status:
 *  - 'earned'  a referrer received commission (referrerId/refereeId set,
 *              commissionCents booked to the ledger).
 *  - 'skipped' the fee had no attributable referrer; recorded only so the sweep
 *              doesn't reconsider it (referrerId/refereeId may be null).
 *
 * `rateBps` is the commission rate LOCKED at accrual time (from the referrer's
 * active-saver tier then), so earnings are deterministic and auditable.
 */
export const referralEarningsTable = pgTable("referral_earnings", {
  id: uuid("id").primaryKey().defaultRandom(),
  sourceTransactionId: uuid("source_transaction_id")
    .notNull()
    .references(() => transactionsTable.id, { onDelete: "cascade" })
    .unique(),
  referrerId: uuid("referrer_id").references(() => usersTable.id, { onDelete: "cascade" }),
  refereeId: uuid("referee_id").references(() => usersTable.id, { onDelete: "set null" }),
  feeCents: integer("fee_cents").notNull().default(0),
  rateBps: integer("rate_bps").notNull().default(0),
  commissionCents: integer("commission_cents").notNull().default(0),
  status: text("status").notNull(), // 'earned' | 'skipped'
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => ({
  byReferrer: index("referral_earnings_referrer_idx").on(t.referrerId),
}));

/**
 * One row per referral withdrawal. `period` is the `YYYY-MM` (UTC) calendar
 * month, used to enforce the $1,000 monthly cap. Backed by a ledger transfer out
 * of the user's `referral:<userId>` account (and, when on-chain is enabled, an
 * on-chain payout to their wallet).
 */
export const referralWithdrawalsTable = pgTable("referral_withdrawals", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }),
  transactionId: uuid("transaction_id").references(() => transactionsTable.id, { onDelete: "set null" }),
  amountCents: integer("amount_cents").notNull(),
  period: text("period").notNull(), // 'YYYY-MM' (UTC)
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => ({
  byUserPeriod: index("referral_withdrawals_user_period_idx").on(t.userId, t.period),
}));

export const insertReferralCodeSchema = createInsertSchema(referralCodesTable).omit({ id: true, createdAt: true });
export const insertReferralSchema = createInsertSchema(referralsTable).omit({ id: true, createdAt: true });
export const insertReferralEarningSchema = createInsertSchema(referralEarningsTable).omit({ id: true, createdAt: true });
export const insertReferralWithdrawalSchema = createInsertSchema(referralWithdrawalsTable).omit({ id: true, createdAt: true });

export type ReferralCode = typeof referralCodesTable.$inferSelect;
export type Referral = typeof referralsTable.$inferSelect;
export type ReferralEarning = typeof referralEarningsTable.$inferSelect;
export type ReferralWithdrawal = typeof referralWithdrawalsTable.$inferSelect;

export type InsertReferralCode = z.infer<typeof insertReferralCodeSchema>;
export type InsertReferral = z.infer<typeof insertReferralSchema>;
export type InsertReferralEarning = z.infer<typeof insertReferralEarningSchema>;
export type InsertReferralWithdrawal = z.infer<typeof insertReferralWithdrawalSchema>;
