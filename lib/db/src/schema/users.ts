import { pgTable, text, timestamp, uuid, boolean, integer } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";

export const usersTable = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  privyDid: text("privy_did").unique(),
  avatarUrl: text("avatar_url"),
  // Streaks: evaluate periods/badges/freezes/vacation in the user's local tz.
  timezone: text("timezone").notNull().default("UTC"),
  streakReminderOptIn: boolean("streak_reminder_opt_in").notNull().default(false),
  // Single annual vacation that pauses streak evaluation (<=30 days, 1/year).
  vacationStart: timestamp("vacation_start", { withTimezone: true }),
  vacationEnd: timestamp("vacation_end", { withTimezone: true }),
  vacationYearUsed: integer("vacation_year_used"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});

export const insertUserSchema = createInsertSchema(usersTable).omit({ id: true, createdAt: true, updatedAt: true });
export type InsertUser = z.infer<typeof insertUserSchema>;
export type User = typeof usersTable.$inferSelect;
