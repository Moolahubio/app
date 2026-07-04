import { pgTable, text, timestamp, uuid, check } from "drizzle-orm/pg-core";
import { sql } from "drizzle-orm";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

/**
 * A user's on-chain wallet.
 *
 * custody:
 *   'server' — legacy custodial wallet. The platform holds the encrypted private
 *              key (`private_key_enc`) and signs on the user's behalf via the
 *              reconciler, which can move funds to ANY destination — so a
 *              DB/env/admin compromise is a drain path.
 *   'privy'  — non-custodial. The fund-holding key is a Privy embedded EOA the
 *              user controls; NO server key exists (`private_key_enc IS NULL`).
 *              Withdrawals are client-signed by the user and only CONFIRMED
 *              (never signed) server-side.
 *
 * The CHECK constraint enforces that a signable key exists iff custody is
 * 'server', so a 'privy' row can never carry a key the platform could abuse.
 */
export const walletsTable = pgTable(
  "wallets",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
    address: text("address").notNull().unique(),
    privateKeyEnc: text("private_key_enc"),
    custody: text("custody").notNull().default("server"),
    network: text("network").notNull().default("monad-testnet"),
    fundedAt: timestamp("funded_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
  },
  (t) => [
    check(
      "wallets_custody_key_consistency",
      sql`(${t.custody} = 'server' AND ${t.privateKeyEnc} IS NOT NULL) OR (${t.custody} = 'privy' AND ${t.privateKeyEnc} IS NULL)`,
    ),
  ],
);

export const insertWalletSchema = createInsertSchema(walletsTable).omit({ id: true, createdAt: true, updatedAt: true });
export type InsertWallet = z.infer<typeof insertWalletSchema>;
export type Wallet = typeof walletsTable.$inferSelect;
