export * from "./users";
export * from "./sessions";
export * from "./email-verification";
export * from "./password-reset";
export * from "./passkeys";
export * from "./twofactor";
export * from "./wallets";
export * from "./goals";
export * from "./circles";
export * from "./transactions";
export * from "./notifications";
export * from "./lessons";
export * from "./onchain";
export * from "./streaks";

import { usersTable } from "./users";
import { walletsTable } from "./wallets";
import { goalsTable } from "./goals";
import { circlesTable, circleMembersTable, circleInvitesTable, contributionsTable } from "./circles";
import { ledgerAccountsTable, transactionsTable, postingsTable } from "./transactions";
import { onchainTransfersTable } from "./onchain";
import { notificationsTable } from "./notifications";
import { streaksTable, streakPeriodsTable, streakFreezesTable, streakBadgesTable } from "./streaks";
import { relations } from "drizzle-orm";

export const usersRelations = relations(usersTable, ({ one, many }) => ({
  wallet: one(walletsTable, { fields: [usersTable.id], references: [walletsTable.userId] }),
  goals: many(goalsTable),
  circleMemberships: many(circleMembersTable),
  notifications: many(notificationsTable),
  streaks: many(streaksTable),
  streakBadges: many(streakBadgesTable),
  streakFreeze: one(streakFreezesTable, { fields: [usersTable.id], references: [streakFreezesTable.userId] }),
}));

export const streaksRelations = relations(streaksTable, ({ one, many }) => ({
  user: one(usersTable, { fields: [streaksTable.userId], references: [usersTable.id] }),
  periods: many(streakPeriodsTable),
}));

export const streakPeriodsRelations = relations(streakPeriodsTable, ({ one }) => ({
  streak: one(streaksTable, { fields: [streakPeriodsTable.streakId], references: [streaksTable.id] }),
}));

export const streakFreezesRelations = relations(streakFreezesTable, ({ one }) => ({
  user: one(usersTable, { fields: [streakFreezesTable.userId], references: [usersTable.id] }),
}));

export const streakBadgesRelations = relations(streakBadgesTable, ({ one }) => ({
  user: one(usersTable, { fields: [streakBadgesTable.userId], references: [usersTable.id] }),
}));

export const walletsRelations = relations(walletsTable, ({ one }) => ({
  user: one(usersTable, { fields: [walletsTable.userId], references: [usersTable.id] }),
}));

export const goalsRelations = relations(goalsTable, ({ one }) => ({
  user: one(usersTable, { fields: [goalsTable.userId], references: [usersTable.id] }),
}));

export const notificationsRelations = relations(notificationsTable, ({ one }) => ({
  user: one(usersTable, { fields: [notificationsTable.userId], references: [usersTable.id] }),
}));

export const transactionsRelations = relations(transactionsTable, ({ many, one }) => ({
  postings: many(postingsTable),
  user: one(usersTable, { fields: [transactionsTable.userId], references: [usersTable.id] }),
  onchainTransfers: many(onchainTransfersTable),
}));

export const onchainTransfersRelations = relations(onchainTransfersTable, ({ one }) => ({
  transaction: one(transactionsTable, {
    fields: [onchainTransfersTable.transactionId],
    references: [transactionsTable.id],
  }),
  sourceUser: one(usersTable, {
    fields: [onchainTransfersTable.sourceUserId],
    references: [usersTable.id],
  }),
}));

export const postingsRelations = relations(postingsTable, ({ one }) => ({
  transaction: one(transactionsTable, { fields: [postingsTable.transactionId], references: [transactionsTable.id] }),
  account: one(ledgerAccountsTable, { fields: [postingsTable.accountId], references: [ledgerAccountsTable.id] }),
}));

export const ledgerAccountsRelations = relations(ledgerAccountsTable, ({ many }) => ({
  postings: many(postingsTable),
}));

export const circlesRelations = relations(circlesTable, ({ many, one }) => ({
  members: many(circleMembersTable),
  invites: many(circleInvitesTable),
  contributions: many(contributionsTable),
  createdBy: one(usersTable, { fields: [circlesTable.createdById], references: [usersTable.id] }),
}));

export const circleMembersRelations = relations(circleMembersTable, ({ one }) => ({
  circle: one(circlesTable, { fields: [circleMembersTable.circleId], references: [circlesTable.id] }),
  user: one(usersTable, { fields: [circleMembersTable.userId], references: [usersTable.id] }),
}));

export const circleInvitesRelations = relations(circleInvitesTable, ({ one }) => ({
  circle: one(circlesTable, { fields: [circleInvitesTable.circleId], references: [circlesTable.id] }),
  invitedBy: one(usersTable, { fields: [circleInvitesTable.invitedById], references: [usersTable.id] }),
}));

export const contributionsRelations = relations(contributionsTable, ({ one }) => ({
  circle: one(circlesTable, { fields: [contributionsTable.circleId], references: [circlesTable.id] }),
  user: one(usersTable, { fields: [contributionsTable.userId], references: [usersTable.id] }),
}));
