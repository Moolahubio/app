import { pgTable, text, timestamp, uuid, integer, boolean, unique } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

export const circlesTable = pgTable("circles", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull(),
  createdById: uuid("created_by_id").notNull().references(() => usersTable.id),
  imageUrl: text("image_url"),
  status: text("status").notNull().default("forming"),
  frequency: text("frequency").notNull().default("monthly"),
  type: text("type").notNull().default("rotation"),
  contributionCents: integer("contribution_cents").notNull(),
  payoutCents: integer("payout_cents"),
  currentRound: integer("current_round").notNull().default(0),
  totalRounds: integer("total_rounds").notNull().default(0),
  startDate: timestamp("start_date", { withTimezone: true }),
  contractAddress: text("contract_address"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const circleMembersTable = pgTable("circle_members", {
  id: uuid("id").primaryKey().defaultRandom(),
  circleId: uuid("circle_id").notNull().references(() => circlesTable.id, { onDelete: "cascade" }),
  userId: uuid("user_id").notNull().references(() => usersTable.id),
  position: integer("position").notNull().default(0),
  payoutRound: integer("payout_round").notNull().default(0),
  paidOut: boolean("paid_out").notNull().default(false),
  remindedRound: integer("reminded_round").notNull().default(0),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => ({
  uniqMember: unique().on(t.circleId, t.userId),
  uniqPosition: unique("circle_members_circle_id_position_unique").on(t.circleId, t.position),
  uniqPayoutRound: unique("circle_members_circle_id_payout_round_unique").on(t.circleId, t.payoutRound),
}));

export const circleInvitesTable = pgTable("circle_invites", {
  id: uuid("id").primaryKey().defaultRandom(),
  circleId: uuid("circle_id").notNull().references(() => circlesTable.id, { onDelete: "cascade" }),
  invitedById: uuid("invited_by_id").notNull().references(() => usersTable.id),
  email: text("email").notNull(),
  status: text("status").notNull().default("pending"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
}, (t) => ({
  uniqInvite: unique().on(t.circleId, t.email),
}));

export const contributionsTable = pgTable("contributions", {
  id: uuid("id").primaryKey().defaultRandom(),
  circleId: uuid("circle_id").notNull().references(() => circlesTable.id, { onDelete: "cascade" }),
  userId: uuid("user_id").notNull().references(() => usersTable.id),
  round: integer("round").notNull(),
  amountCents: integer("amount_cents").notNull(),
  txHash: text("tx_hash"),
  status: text("status").notNull().default("confirmed"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
}, (t) => ({
  uniqContribution: unique().on(t.circleId, t.userId, t.round),
}));

export const insertCircleSchema = createInsertSchema(circlesTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertCircleMemberSchema = createInsertSchema(circleMembersTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertCircleInviteSchema = createInsertSchema(circleInvitesTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertContributionSchema = createInsertSchema(contributionsTable).omit({ id: true, createdAt: true });

export type InsertCircle = z.infer<typeof insertCircleSchema>;
export type Circle = typeof circlesTable.$inferSelect;
export type CircleMember = typeof circleMembersTable.$inferSelect;
export type CircleInvite = typeof circleInvitesTable.$inferSelect;
export type Contribution = typeof contributionsTable.$inferSelect;
