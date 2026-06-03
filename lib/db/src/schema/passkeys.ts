import { pgTable, text, timestamp, uuid, integer } from "drizzle-orm/pg-core";
import { createInsertSchema } from "drizzle-zod";
import { z } from "zod/v4";
import { usersTable } from "./users";

export const passkeysTable = pgTable("passkeys", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }),
  credentialId: text("credential_id").notNull().unique(),
  publicKey: text("public_key").notNull(),
  counter: integer("counter").notNull().default(0),
  transports: text("transports"),
  deviceName: text("device_name"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  lastUsedAt: timestamp("last_used_at", { withTimezone: true }),
});

export const insertPasskeySchema = createInsertSchema(passkeysTable).omit({ id: true, createdAt: true });
export type InsertPasskey = z.infer<typeof insertPasskeySchema>;
export type Passkey = typeof passkeysTable.$inferSelect;

// Short-lived WebAuthn challenges. For registration userId is set; for login it
// may be null (usernameless / discoverable credential flows). The random id is
// handed to the client as an opaque flow token and exchanged back on verify so
// the challenge itself never round-trips through the client.
export const webauthnChallengesTable = pgTable("webauthn_challenges", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").references(() => usersTable.id, { onDelete: "cascade" }),
  challenge: text("challenge").notNull(),
  type: text("type").notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const insertWebauthnChallengeSchema = createInsertSchema(webauthnChallengesTable).omit({ id: true, createdAt: true });
export type InsertWebauthnChallenge = z.infer<typeof insertWebauthnChallengeSchema>;
export type WebauthnChallenge = typeof webauthnChallengesTable.$inferSelect;
