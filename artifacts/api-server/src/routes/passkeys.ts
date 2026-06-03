import { Router, type IRouter, type Request } from "express";
import { and, eq, lt } from "drizzle-orm";
import {
  db,
  usersTable,
  walletsTable,
  passkeysTable,
  webauthnChallengesTable,
} from "@workspace/db";
import {
  RegisterPasskeyVerifyBody,
  LoginPasskeyVerifyBody,
  RegisterPasskeyOptionsResponse,
  LoginPasskeyOptionsResponse,
  RegisterPasskeyVerifyResponse,
  ListPasskeysResponse,
  LoginPasskeyVerifyResponse,
} from "@workspace/api-zod";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "@simplewebauthn/server";
import { isoBase64URL } from "@simplewebauthn/server/helpers";
import { requireAuth, createSession, type AuthRequest } from "../lib/auth";

const router: IRouter = Router();

const RP_NAME = "MoolaHub";
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const COOKIE = "moolahub_session";
const cookieOpts = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax" as const,
  maxAge: 30 * 24 * 60 * 60 * 1000,
};

// Derive the WebAuthn Relying Party ID + expected origin from the request so the
// same code works in the dev preview and in the published deployment without any
// hard-coded domain. The ceremony runs at the page origin, which the browser
// echoes back in the Origin header.
function rpFromRequest(req: Request): { rpID: string; origin: string } {
  const originHeader = (req.headers.origin as string | undefined) ?? "";
  let origin = originHeader;
  if (!origin) {
    const proto = (req.headers["x-forwarded-proto"] as string | undefined) ?? "https";
    const host = req.headers.host ?? "localhost";
    origin = `${proto}://${host}`;
  }
  const rpID = new URL(origin).hostname;
  return { rpID, origin };
}

function parseTransports(value: string | null): string[] | undefined {
  if (!value) return undefined;
  try {
    const arr = JSON.parse(value);
    return Array.isArray(arr) ? arr : undefined;
  } catch {
    return undefined;
  }
}

async function storeChallenge(userId: string | null, challenge: string, type: string): Promise<string> {
  const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS);
  const [row] = await db
    .insert(webauthnChallengesTable)
    .values({ userId, challenge, type, expiresAt })
    .returning();
  return row.id;
}

async function consumeChallenge(flowId: string, type: string): Promise<{ challenge: string; userId: string | null } | null> {
  // Best-effort cleanup of expired challenges.
  await db.delete(webauthnChallengesTable).where(lt(webauthnChallengesTable.expiresAt, new Date()));

  // Atomic single-use: delete-and-return in one statement so concurrent verify
  // requests cannot both claim the same challenge (prevents replay races).
  const [row] = await db
    .delete(webauthnChallengesTable)
    .where(and(eq(webauthnChallengesTable.id, flowId), eq(webauthnChallengesTable.type, type)))
    .returning();

  if (!row) return null;
  if (row.expiresAt < new Date()) return null;
  return { challenge: row.challenge, userId: row.userId };
}

router.get("/passkeys", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const rows = await db.select().from(passkeysTable).where(eq(passkeysTable.userId, user.id));
  res.json(
    ListPasskeysResponse.parse({
      passkeys: rows.map((p) => ({
        id: p.id,
        deviceName: p.deviceName,
        createdAt: p.createdAt.toISOString(),
        lastUsedAt: p.lastUsedAt ? p.lastUsedAt.toISOString() : null,
      })),
    }),
  );
});

router.delete("/passkeys/:id", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  await db
    .delete(passkeysTable)
    .where(and(eq(passkeysTable.id, String(req.params.id)), eq(passkeysTable.userId, user.id)));
  res.json({ ok: true });
});

router.post("/passkeys/register/options", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const { rpID } = rpFromRequest(req);

  const existing = await db.select().from(passkeysTable).where(eq(passkeysTable.userId, user.id));

  const options = await generateRegistrationOptions({
    rpName: RP_NAME,
    rpID,
    userID: new TextEncoder().encode(user.id),
    userName: user.email,
    userDisplayName: user.name,
    attestationType: "none",
    excludeCredentials: existing.map((p) => ({
      id: p.credentialId,
      transports: parseTransports(p.transports) as never,
    })),
    authenticatorSelection: {
      residentKey: "preferred",
      userVerification: "preferred",
    },
  });

  const flowId = await storeChallenge(user.id, options.challenge, "register");
  res.json(RegisterPasskeyOptionsResponse.parse({ flowId, options }));
});

router.post("/passkeys/register/verify", requireAuth, async (req, res): Promise<void> => {
  const user = (req as AuthRequest).user;
  const parsed = RegisterPasskeyVerifyBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const flow = await consumeChallenge(parsed.data.flowId, "register");
  if (!flow || flow.userId !== user.id) {
    res.status(400).json({ error: "Registration session expired. Please try again." });
    return;
  }

  const { rpID, origin } = rpFromRequest(req);
  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response: parsed.data.response as never,
      expectedChallenge: flow.challenge,
      expectedOrigin: origin,
      expectedRPID: rpID,
    });
  } catch {
    res.status(400).json({ error: "Could not verify passkey." });
    return;
  }

  if (!verification.verified || !verification.registrationInfo) {
    res.status(400).json({ error: "Passkey verification failed." });
    return;
  }

  const cred = verification.registrationInfo.credential;
  const deviceName = parsed.data.deviceName?.trim() || "Passkey";

  const [saved] = await db
    .insert(passkeysTable)
    .values({
      userId: user.id,
      credentialId: cred.id,
      publicKey: isoBase64URL.fromBuffer(cred.publicKey),
      counter: cred.counter,
      transports: cred.transports ? JSON.stringify(cred.transports) : null,
      deviceName,
    })
    .returning();

  res.json(
    RegisterPasskeyVerifyResponse.parse({
      id: saved.id,
      deviceName: saved.deviceName,
      createdAt: saved.createdAt.toISOString(),
      lastUsedAt: null,
    }),
  );
});

router.post("/passkeys/login/options", async (req, res): Promise<void> => {
  const { rpID } = rpFromRequest(req);
  const options = await generateAuthenticationOptions({
    rpID,
    userVerification: "preferred",
  });
  const flowId = await storeChallenge(null, options.challenge, "login");
  res.json(LoginPasskeyOptionsResponse.parse({ flowId, options }));
});

router.post("/passkeys/login/verify", async (req, res): Promise<void> => {
  const parsed = LoginPasskeyVerifyBody.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({ error: parsed.error.message });
    return;
  }

  const flow = await consumeChallenge(parsed.data.flowId, "login");
  if (!flow) {
    res.status(400).json({ error: "Login session expired. Please try again." });
    return;
  }

  const credentialId = (parsed.data.response as { id?: string }).id;
  if (!credentialId) {
    res.status(400).json({ error: "Malformed passkey response." });
    return;
  }

  const [passkey] = await db
    .select()
    .from(passkeysTable)
    .where(eq(passkeysTable.credentialId, credentialId));
  if (!passkey) {
    res.status(400).json({ error: "Unrecognized passkey." });
    return;
  }

  const { rpID, origin } = rpFromRequest(req);
  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response: parsed.data.response as never,
      expectedChallenge: flow.challenge,
      expectedOrigin: origin,
      expectedRPID: rpID,
      credential: {
        id: passkey.credentialId,
        publicKey: isoBase64URL.toBuffer(passkey.publicKey),
        counter: passkey.counter,
        transports: parseTransports(passkey.transports) as never,
      },
    });
  } catch {
    res.status(400).json({ error: "Could not verify passkey." });
    return;
  }

  if (!verification.verified) {
    res.status(400).json({ error: "Passkey verification failed." });
    return;
  }

  await db
    .update(passkeysTable)
    .set({ counter: verification.authenticationInfo.newCounter, lastUsedAt: new Date() })
    .where(eq(passkeysTable.id, passkey.id));

  const [user] = await db.select().from(usersTable).where(eq(usersTable.id, passkey.userId));
  if (!user) {
    res.status(400).json({ error: "Account not found." });
    return;
  }

  const [wallet] = await db.select().from(walletsTable).where(eq(walletsTable.userId, user.id));
  const token = await createSession(user.id);
  res.cookie(COOKIE, token, cookieOpts);

  res.json(
    LoginPasskeyVerifyResponse.parse({
      id: user.id,
      name: user.name,
      email: user.email,
      avatarUrl: user.avatarUrl ?? null,
      hasWallet: !!wallet,
      walletAddress: wallet?.address ?? null,
    }),
  );
});

export default router;
