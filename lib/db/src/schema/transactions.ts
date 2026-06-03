import { pgTable, text, timestamp, uuid, integer } from "drizzle-orm/pg-core";
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
  txHash: text("tx_hash"),
  onchainStatus: text("onchain_status").notNull().default("none"),
  onchainXdr: text("onchain_xdr"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

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
