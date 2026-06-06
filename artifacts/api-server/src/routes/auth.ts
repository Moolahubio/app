import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, usersTable, sessionsTable } from "@workspace/db";
import {
  PrivyAuthBody,
  PrivyAuthResponse,
  LogoutResponse,
  GetMeResponse,
} from "@workspace/api-zod";
import {
  requireAuth,
  createSession,
  sessionTtlMs,
  type AuthRequest,
} from "../lib/auth";
import { createWalletForUser, getWalletForUser } from "../lib/wallet";
import { privyEnabled, verifyPrivyToken, getPrivyProfile } from "../lib/privy";

const router: IRouter = Router();

const COOKIE = "moolahub_session";
// Base cookie attributes; `maxAge` is set per-login to match the session TTL
// (7 days by default, 30 with "keep me logged in").
const cookieOpts = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax" as const,
};

router.post("/auth/logout", async (req, res): Promise<void> => {
  const token = req.cookies?.[COOKIE] ?? req.headers["x-session-token"];
  if (token) {
    await db.delete(sessionsTable).where(eq(sessionsTable.token, token as string));
  }
  res.clearCookie(COOKIE);
  res.json(LogoutResponse.parse({ ok: true }));
});

router.get("/auth/me", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await getWalletForUser(user.id);
  res.json(
    GetMeResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      avatarUrl: user.avatarUrl ?? null,
      hasWallet: !!wallet,
      walletAddress: wallet?.address ?? null,
    }),
  );
});

router.post("/auth/privy", async (req, res): Promise<void> => {
  const parsed = PrivyAuthBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: "Invalid request" });
    return;
  }

  if (!privyEnabled()) {
    res.status(400).json({ error: "Privy sign-in is not configured." });
    return;
  }

  let did: string;
  try {
    did = await verifyPrivyToken(parsed.data.token);
  } catch {
    res.status(401).json({ error: "Invalid Privy token" });
    return;
  }

  // Identity is derived strictly from the verified Privy token (the DID) and the
  // profile fetched server-side from Privy. Client-supplied email/name are NOT
  // trusted for account linking — otherwise a valid Privy token holder could
  // bind their DID to someone else's account by submitting that email.
  const profile = await getPrivyProfile(did).catch(() => ({}) as { email?: string; name?: string });
  const verifiedEmail = profile.email ? profile.email.toLowerCase() : null;
  const name = profile.name ?? parsed.data.name ?? "MoolaHub Member";

  let [user] = await db.select().from(usersTable).where(eq(usersTable.privyDid, did));
  if (!user && verifiedEmail) {
    // Only link to an existing account when the email is verified by Privy.
    [user] = await db.select().from(usersTable).where(eq(usersTable.email, verifiedEmail));
    if (user) {
      await db.update(usersTable).set({ privyDid: did }).where(eq(usersTable.id, user.id));
    }
  }
  if (!user) {
    const email = verifiedEmail ?? `${did.replace(/[^a-zA-Z0-9]/g, "")}@privy.moolahub`;
    [user] = await db.insert(usersTable).values({ name, email, privyDid: did }).returning();
  }

  // "Keep me logged in" — read defensively from the raw body so it works whether
  // or not the generated client/schema includes it yet. Defaults to false (7d).
  const rememberMe = (req.body as { rememberMe?: unknown })?.rememberMe === true;

  const wallet = await createWalletForUser(user.id);
  const token = await createSession(user.id, rememberMe);
  res.cookie(COOKIE, token, { ...cookieOpts, maxAge: sessionTtlMs(rememberMe) });

  res.json(
    PrivyAuthResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      avatarUrl: user.avatarUrl ?? null,
      hasWallet: true,
      walletAddress: wallet.address,
    }),
  );
});

export default router;
