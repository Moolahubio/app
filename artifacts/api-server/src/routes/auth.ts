import { Router, type IRouter } from "express";
import { eq } from "drizzle-orm";
import { db, usersTable, sessionsTable, walletsTable } from "@workspace/db";
import {
  LoginBody,
  RegisterBody,
  PrivyAuthBody,
  LoginResponse,
  LogoutResponse,
  GetMeResponse,
} from "@workspace/api-zod";
import {
  requireAuth,
  createSession,
  hashPassword,
  comparePassword,
  getUserFromRequest,
  getOrCreateWallet,
  type AuthRequest,
} from "../lib/auth";

const router: IRouter = Router();

router.post("/auth/login", async (req, res): Promise<void> => {
  const parsed = LoginBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const [user] = await db
    .select()
    .from(usersTable)
    .where(eq(usersTable.email, parsed.data.email.toLowerCase()));

  if (!user || !user.passwordHash) {
    res.status(400).json({ error: "Invalid email or password" });
    return;
  }

  const valid = await comparePassword(parsed.data.password, user.passwordHash);
  if (!valid) {
    res.status(400).json({ error: "Invalid email or password" });
    return;
  }

  const token = await createSession(user.id);
  const wallet = await getOrCreateWallet(user.id);

  res.cookie("moolahub_session", token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: 30 * 24 * 60 * 60 * 1000,
  });

  res.json(
    LoginResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      kycStatus: user.kycStatus,
      hasWallet: true,
      walletAddress: wallet.address,
    })
  );
});

router.post("/auth/register", async (req, res): Promise<void> => {
  const parsed = RegisterBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const [existing] = await db
    .select()
    .from(usersTable)
    .where(eq(usersTable.email, parsed.data.email.toLowerCase()));

  if (existing) {
    res.status(400).json({ error: "Email already registered" });
    return;
  }

  const passwordHash = await hashPassword(parsed.data.password);
  const [user] = await db
    .insert(usersTable)
    .values({
      name: parsed.data.name,
      email: parsed.data.email.toLowerCase(),
      passwordHash,
    })
    .returning();

  const token = await createSession(user.id);
  const wallet = await getOrCreateWallet(user.id);

  res.cookie("moolahub_session", token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: 30 * 24 * 60 * 60 * 1000,
  });

  res.status(201).json(
    LoginResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      kycStatus: user.kycStatus,
      hasWallet: true,
      walletAddress: wallet.address,
    })
  );
});

router.post("/auth/logout", async (req, res): Promise<void> => {
  const token = req.cookies?.["moolahub_session"] ?? req.headers["x-session-token"];
  if (token) {
    await db.delete(sessionsTable).where(eq(sessionsTable.token, token as string));
  }
  res.clearCookie("moolahub_session");
  res.json(LogoutResponse.parse({ ok: true }));
});

router.get("/auth/me", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const wallet = await getOrCreateWallet(user.id);
  res.json(
    GetMeResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      kycStatus: user.kycStatus,
      hasWallet: true,
      walletAddress: wallet.address,
    })
  );
});

router.post("/auth/privy", async (req, res): Promise<void> => {
  const parsed = PrivyAuthBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const email = parsed.data.email?.toLowerCase() ?? `privy_${Date.now()}@moolahub.io`;
  const name = parsed.data.name ?? "MoolaHub User";

  let [user] = await db.select().from(usersTable).where(eq(usersTable.email, email));

  if (!user) {
    [user] = await db
      .insert(usersTable)
      .values({ name, email, privyDid: parsed.data.token })
      .returning();
  }

  const token = await createSession(user.id);
  const wallet = await getOrCreateWallet(user.id);

  res.cookie("moolahub_session", token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: 30 * 24 * 60 * 60 * 1000,
  });

  res.json(
    LoginResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      kycStatus: user.kycStatus,
      hasWallet: true,
      walletAddress: wallet.address,
    })
  );
});

export default router;
