import { eq } from "drizzle-orm";
import { db, usersTable, sessionsTable } from "@workspace/db";
import type { Request, Response, NextFunction } from "express";
import crypto from "crypto";
import bcrypt from "bcryptjs";

export async function getUserFromRequest(req: Request): Promise<typeof usersTable.$inferSelect | null> {
  const token = req.cookies?.["moolahub_session"] ?? req.headers["x-session-token"];
  if (!token) return null;

  const [session] = await db
    .select()
    .from(sessionsTable)
    .where(eq(sessionsTable.token, token as string));

  if (!session || session.expiresAt < new Date()) return null;

  const [user] = await db
    .select()
    .from(usersTable)
    .where(eq(usersTable.id, session.userId));

  return user ?? null;
}

export async function requireAuth(req: Request, res: Response, next: NextFunction): Promise<void> {
  const user = await getUserFromRequest(req);
  if (!user) {
    res.status(401).json({ error: "Unauthorized" });
    return;
  }
  (req as Request & { user: typeof usersTable.$inferSelect }).user = user;
  next();
}

export async function createSession(userId: string): Promise<string> {
  const token = crypto.randomBytes(32).toString("hex");
  const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
  await db.insert(sessionsTable).values({ userId, token, expiresAt });
  return token;
}

export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, 12);
}

export async function comparePassword(password: string, hash: string): Promise<boolean> {
  return bcrypt.compare(password, hash);
}

export type AuthRequest = Request & { user: typeof usersTable.$inferSelect };
