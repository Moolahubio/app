import { pgTable, text, timestamp, uuid, integer, boolean } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

export const circlesTable = pgTable("circles", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull(),
  creatorId: uuid("creator_id").notNull().references(() => usersTable.id),
  status: text("status").notNull().default("pending"),
  frequency: text("frequency").notNull().default("monthly"),
  contributionCents: integer("contribution_cents").notNull(),
  potCents: integer("pot_cents").notNull().default(0),
  currentRound: integer("current_round").notNull().default(0),
  totalRounds: integer("total_rounds").notNull().default(0),
  startDate: timestamp("start_date", { withTimezone: true }),
  nextPayoutDate: timestamp("next_payout_date", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const circleMembersTable = pgTable("circle_members", {
  id: uuid("id").primaryKey().defaultRandom(),
  circleId: uuid("circle_id").notNull().references(() => circlesTable.id, { onDelete: "cascade" }),
  userId: uuid("user_id").notNull().references(() => usersTable.id),
  payoutRound: integer("payout_round").notNull().default(0),
  state: text("state").notNull().default("invited"),
  paidOut: boolean("paid_out").notNull().default(false),
  contributedThisRound: boolean("contributed_this_round").notNull().default(false),
  inviteEmail: text("invite_email"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const circleInvitesTable = pgTable("circle_invites", {
  id: uuid("id").primaryKey().defaultRandom(),
  circleId: uuid("circle_id").notNull().references(() => circlesTable.id, { onDelete: "cascade" }),
  inviterId: uuid("inviter_id").notNull().references(() => usersTable.id),
  inviteeEmail: text("invitee_email").notNull(),
  inviteeId: uuid("invitee_id").references(() => usersTable.id),
  status: text("status").notNull().default("pending"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const insertCircleSchema = createInsertSchema(circlesTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertCircleMemberSchema = createInsertSchema(circleMembersTable).omit({ id: true, createdAt: true, updatedAt: true });
export const insertCircleInviteSchema = createInsertSchema(circleInvitesTable).omit({ id: true, createdAt: true, updatedAt: true });

export type InsertCircle = z.infer<typeof insertCircleSchema>;
export type Circle = typeof circlesTable.$inferSelect;
export type CircleMember = typeof circleMembersTable.$inferSelect;
export type CircleInvite = typeof circleInvitesTable.$inferSelect;
