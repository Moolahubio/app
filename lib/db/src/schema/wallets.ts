import { pgTable, text, timestamp, uuid, integer, boolean } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

export const walletsTable = pgTable("wallets", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
  address: text("address").notNull().unique(),
  cdpWalletId: text("cdp_wallet_id"),
  network: text("network").notNull().default("base-sepolia"),
  availableCents: integer("available_cents").notNull().default(0),
  goalAllocatedCents: integer("goal_allocated_cents").notNull().default(0),
  onrampEnabled: boolean("onramp_enabled").notNull().default(true),
  onchainEnabled: boolean("onchain_enabled").notNull().default(false),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const insertWalletSchema = createInsertSchema(walletsTable).omit({ id: true, createdAt: true, updatedAt: true });
export type InsertWallet = z.infer<typeof insertWalletSchema>;
export type Wallet = typeof walletsTable.$inferSelect;
