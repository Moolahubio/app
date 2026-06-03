import { pgTable, text, timestamp, uuid, integer, index } from "drizzle-orm/pg-core";
import { usersTable } from "./users";
import { transactionsTable } from "./transactions";
import { contributionsTable } from "./circles";

/**
 * On-chain settlement queue. The double-entry ledger is the source of truth and
 * commits immediately; the actual USDC transfer on Base is settled
 * asynchronously by the reconciler (`lib/settlement.ts`). Each row is a transfer
 * the reconciler must (re)attempt until it confirms, so a temporarily unfunded
 * platform/user wallet or an unreachable RPC no longer silently degrades a money
 * movement to ledger-only — it stays "pending" and is retried.
 *
 * No secrets are stored here: the signing key is resolved at send time from
 * `sourceUserId` (null => the platform distributor key).
 *
 * status: pending (awaiting/awaiting-retry) | processing (claimed by a worker)
 *         | confirmed (settled on-chain) | failed (permanent, will not retry)
 */
export const onchainTransfersTable = pgTable(
  "onchain_transfers",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    transactionId: uuid("transaction_id")
      .notNull()
      .references(() => transactionsTable.id, { onDelete: "cascade" }),
    contributionId: uuid("contribution_id").references(() => contributionsTable.id, {
      onDelete: "set null",
    }),
    kind: text("kind").notNull(),
    // null => platform distributor wallet is the source.
    sourceUserId: uuid("source_user_id").references(() => usersTable.id, { onDelete: "set null" }),
    toAddress: text("to_address").notNull(),
    amountCents: integer("amount_cents").notNull(),
    memo: text("memo"),
    status: text("status").notNull().default("pending"),
    attempts: integer("attempts").notNull().default(0),
    lastError: text("last_error"),
    txHash: text("tx_hash"),
    lastAttemptAt: timestamp("last_attempt_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => ({
    statusIdx: index("onchain_transfers_status_idx").on(t.status),
  }),
);

export type OnchainTransfer = typeof onchainTransfersTable.$inferSelect;
