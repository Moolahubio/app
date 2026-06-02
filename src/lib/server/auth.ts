import "server-only";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { randomBytes } from "node:crypto";
import bcrypt from "bcryptjs";
import { db } from "@/lib/db";

/**
 * Session-based auth. Passwords are bcrypt-hashed; sessions are opaque tokens
 * persisted in the DB (revocable) and carried in an httpOnly cookie.
 *
 * This sits behind a thin seam: swapping in Privy later means replacing
 * `createSession`/`getCurrentUser` with Privy's verifier — the rest of the app
 * only depends on `getCurrentUser()` / `requireUser()`.
 */

const COOKIE = "mh_session";
const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 30; // 30 days

export function hashPassword(plain: string) {
  return bcrypt.hash(plain, 10);
}

export function verifyPassword(plain: string, hash: string) {
  return bcrypt.compare(plain, hash);
}

export async function createSession(userId: string) {
  const token = randomBytes(32).toString("hex");
  const expiresAt = new Date(Date.now() + SESSION_TTL_MS);
  await db.session.create({ data: { token, userId, expiresAt } });
  const jar = await cookies();
  jar.set(COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    expires: expiresAt,
  });
}

export async function destroySession() {
  const jar = await cookies();
  const token = jar.get(COOKIE)?.value;
  if (token) {
    await db.session.deleteMany({ where: { token } });
    jar.delete(COOKIE);
  }
}

export async function getCurrentUser() {
  const jar = await cookies();
  const token = jar.get(COOKIE)?.value;
  if (!token) return null;
  const session = await db.session.findUnique({
    where: { token },
    include: { user: { include: { wallet: true } } },
  });
  if (!session || session.expiresAt < new Date()) return null;
  return session.user;
}

export async function requireUser() {
  const user = await getCurrentUser();
  if (!user) redirect("/login");
  return user;
}

export type SessionUser = NonNullable<Awaited<ReturnType<typeof getCurrentUser>>>;
