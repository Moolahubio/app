import { eq } from "drizzle-orm";
import { db, usersTable, sessionsTable } from "@workspace/db";
import type { Request, Response, NextFunction } from "express";
import crypto from "crypto";

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

/**
 * Gate operator-only, read-only endpoints behind a shared operator token. The
 * caller must send `x-operator-token` matching the `OPERATOR_TOKEN` secret. When
 * the secret is unset the route is treated as not configured (503) rather than
 * open, so operational data is never exposed by default.
 */
export function requireOperator(req: Request, res: Response, next: NextFunction): void {
  const expected = process.env.OPERATOR_TOKEN;
  if (!expected) {
    res.status(503).json({ error: "Operator console not configured (OPERATOR_TOKEN unset)" });
    return;
  }
  const header = req.headers["x-operator-token"];
  const provided = Array.isArray(header) ? header[0] : header;
  if (!provided || !timingSafeEqualStr(provided, expected)) {
    res.status(401).json({ error: "Unauthorized" });
    return;
  }
  next();
}

function timingSafeEqualStr(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

export async function createSession(userId: string): Promise<string> {
  const token = crypto.randomBytes(32).toString("hex");
  const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
  await db.insert(sessionsTable).values({ userId, token, expiresAt });
  return token;
}

export type AuthRequest = Request & { user: typeof usersTable.$inferSelect };
