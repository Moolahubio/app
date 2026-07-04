import { pgTable, text, timestamp, uuid, integer, uniqueIndex } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";
import { goalsTable } from "./goals";
import { circlesTable } from "./circles";

/**
 * Double-entry ledger. Every money movement is a transaction with postings
 * that sum to zero. Balances are always derived from postings, never stored.
 *
 * Account keys:
 *   wallet:<userId>  available, unallocated balance in the user's wallet
 *   goal:<goalId>    allocated to a goal (still in the wallet, earmarked)
 *   pool:<circleId>  a Susu circle's escrowed pot
 *   external         the outside world: on-chain USDC in/out
 *   yield            yield source
 *   fees             platform fees
 */
export const ledgerAccountsTable = pgTable("ledger_accounts", {
  id: uuid("id").primaryKey().defaultRandom(),
  key: text("key").notNull().unique(),
  kind: text("kind").notNull(),
  label: text("label").notNull(),
  userId: uuid("user_id").references(() => usersTable.id, { onDelete: "cascade" }),
  goalId: uuid("goal_id").references(() => goalsTable.id, { onDelete: "cascade" }),
  circleId: uuid("circle_id").references(() => circlesTable.id, { onDelete: "cascade" }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const transactionsTable = pgTable("transactions", {
  id: uuid("id").primaryKey().defaultRandom(),
  type: text("type").notNull(),
  description: text("description").notNull(),
  userId: uuid("user_id").references(() => usersTable.id, { onDelete: "set null" }),
  // Circle + round context, set on circle contributions/payouts/fees so the
  // reconciler can confirm a rotation payout against the on-chain RoundSettled
  // event (which settles atomically with the final contribution) by circle+round.
  circleId: uuid("circle_id").references(() => circlesTable.id, { onDelete: "set null" }),
  round: integer("round"),
  txHash: text("tx_hash"),
  onchainStatus: text("onchain_status").notNull().default("none"),
  onchainXdr: text("onchain_xdr"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  // A given on-chain deposit (tx hash) can only ever be credited once. This is
  // the authoritative guard against concurrent /wallet/sync calls double-
  // crediting the same incoming USDC payment: the second insert fails on this
  // unique index and is skipped. Partial so it ignores faucet/other rows whose
  // tx_hash is null and only applies to deposit credits.
  //
  // NOTE: other transaction types (goal_withdraw net+fee, circle payout+fee)
  // intentionally share the same hash across multiple rows (one on-chain event
  // produces several ledger postings). The index must stay deposit-scoped so it
  // does not block those legitimate multi-row settlements. The application-level
  // cross-type hash check in syncDeposits() is what prevents an already-
  // recorded hash from being re-imported as a new deposit.
  uniqueIndex("transactions_deposit_tx_hash_uniq")
    .on(t.txHash)
    .where(sql`${t.type} = 'deposit' and ${t.txHash} is not null`),
  // A client-signed non-custodial withdrawal (wallets.custody = 'privy') is
  // recorded by POST /wallet/withdraw/submitted after verifying the on-chain
  // receipt. Like the deposit guard above, this partial unique index is the
  // authoritative defense against a replayed/duplicate tx hash being booked
  // twice (two concurrent submits can both pass the app-level pre-check). It is
  // withdrawal-scoped and deliberately separate from the deposit index so an
  // in-app-to-in-app transfer can still record the SAME hash once as the
  // sender's withdrawal and once as the recipient's deposit.
  uniqueIndex("transactions_withdrawal_tx_hash_uniq")
    .on(t.txHash)
    .where(sql`${t.type} = 'withdrawal' and ${t.txHash} is not null`),
]);

export const postingsTable = pgTable("postings", {
  id: uuid("id").primaryKey().defaultRandom(),
  transactionId: uuid("transaction_id").notNull().references(() => transactionsTable.id, { onDelete: "cascade" }),
  accountId: uuid("account_id").notNull().references(() => ledgerAccountsTable.id, { onDelete: "cascade" }),
  amountCents: integer("amount_cents").notNull(),
});

export const insertTransactionSchema = createInsertSchema(transactionsTable).omit({ id: true, createdAt: true });
export type InsertTransaction = z.infer<typeof insertTransactionSchema>;
export type Transaction = typeof transactionsTable.$inferSelect;
export type LedgerAccount = typeof ledgerAccountsTable.$inferSelect;
export type Posting = typeof postingsTable.$inferSelect;
