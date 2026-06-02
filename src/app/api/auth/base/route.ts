import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { randomBytes } from "node:crypto";
import { createPublicClient, http, getAddress, type Hex } from "viem";
import { base, baseSepolia } from "viem/chains";
import { db } from "@/lib/db";
import { createSession } from "@/lib/server/auth";
import { encryptSecret } from "@/lib/server/crypto";

export const dynamic = "force-dynamic";

const CHAIN = process.env.NEXT_PUBLIC_BASE_CHAIN === "base" ? base : baseSepolia;
const NONCE_COOKIE = "base_nonce";

/** Issue a sign-in nonce (also stored in an httpOnly cookie for verification). */
export async function GET() {
  const nonce = randomBytes(16).toString("hex");
  const jar = await cookies();
  jar.set(NONCE_COOKIE, nonce, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 600,
  });
  return NextResponse.json({ nonce });
}

/**
 * Verify a Base Account signature (ERC-1271/6492 for smart wallets) over the
 * nonce challenge, then find-or-create the MoolaHub user + session. Base Account
 * is the canonical wallet for these users; the custodial key is unused (the
 * smart wallet self-signs), so we store a placeholder.
 */
export async function POST(req: Request) {
  let body: { address?: string; message?: string; signature?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid request" }, { status: 400 });
  }
  const { address, message, signature } = body;
  if (!address || !message || !signature) {
    return NextResponse.json({ error: "Missing fields" }, { status: 400 });
  }

  const jar = await cookies();
  const nonce = jar.get(NONCE_COOKIE)?.value;
  if (!nonce || !message.includes(nonce)) {
    return NextResponse.json({ error: "Stale or missing nonce — try again." }, { status: 400 });
  }

  // Verify against the chain (ERC-6492 supports not-yet-deployed smart accounts).
  try {
    const client = createPublicClient({
      chain: CHAIN,
      transport: http(process.env.BASE_RPC_URL || undefined),
    });
    const valid = await client.verifyMessage({
      address: getAddress(address),
      message,
      signature: signature as Hex,
    });
    if (!valid) return NextResponse.json({ error: "Invalid signature" }, { status: 401 });
  } catch {
    return NextResponse.json(
      { error: "Couldn't verify the signature (Base RPC unavailable)." },
      { status: 502 },
    );
  }

  const addr = getAddress(address);
  const externalId = `base:${addr.toLowerCase()}`;
  let user = await db.user.findFirst({ where: { privyId: externalId } });
  if (!user) {
    user = await db.user.create({
      data: {
        name: `${addr.slice(0, 6)}…${addr.slice(-4)}`,
        email: `${addr.toLowerCase()}@base.moolahub`,
        privyId: externalId,
        kycStatus: "unstarted",
        wallet: { create: { address: addr, privateKeyEnc: encryptSecret("") } },
      },
    });
  }
  jar.delete(NONCE_COOKIE);
  await createSession(user.id);
  return NextResponse.json({ ok: true });
}
