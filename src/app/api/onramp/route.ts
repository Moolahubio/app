import { NextResponse } from "next/server";
import { z } from "zod";
import { getCurrentUser } from "@/lib/server/auth";
import { onrampEnabled, createOnrampSessionToken, buildOnrampUrl } from "@/lib/server/onramp";

export const dynamic = "force-dynamic";

const bodySchema = z.object({
  presetFiatAmount: z.number().int().positive().max(10_000).optional(),
});

// Simple in-memory per-user rate limit (10/min).
const hits = new Map<string, { count: number; reset: number }>();
function rateLimited(key: string, limit = 10, windowMs = 60_000): boolean {
  const now = Date.now();
  const e = hits.get(key);
  if (!e || now > e.reset) {
    hits.set(key, { count: 1, reset: now + windowMs });
    return false;
  }
  e.count += 1;
  return e.count > limit;
}

function clientIp(req: Request): string {
  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ||
    req.headers.get("x-real-ip") ||
    "";
  // CDP rejects private/loopback IPs — fall back to a documentation IP (RFC 5737).
  const isPrivate =
    !ip ||
    ip === "::1" ||
    ip === "127.0.0.1" ||
    /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)/.test(ip);
  return isPrivate ? "192.0.2.1" : ip;
}

/**
 * Start a fiat → USDC purchase. Auth-gated; the destination is ALWAYS the
 * authenticated user's own wallet (server-set), never client input.
 */
export async function POST(req: Request) {
  if (!onrampEnabled()) {
    return NextResponse.json({ error: "Onramp is not configured" }, { status: 503 });
  }
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  if (!user.wallet?.address) {
    return NextResponse.json({ error: "No wallet provisioned" }, { status: 400 });
  }
  if (rateLimited(user.id)) {
    return NextResponse.json({ error: "Too many requests. Try again shortly." }, { status: 429 });
  }

  let raw: unknown = {};
  try {
    raw = await req.json();
  } catch {
    /* empty body is fine */
  }
  const parsed = bodySchema.safeParse(raw);
  if (!parsed.success) {
    return NextResponse.json({ error: "Invalid request" }, { status: 400 });
  }

  try {
    const token = await createOnrampSessionToken(user.wallet.address, clientIp(req));
    const url = buildOnrampUrl(token, { presetFiatAmount: parsed.data.presetFiatAmount });
    return NextResponse.json({ url });
  } catch (e) {
    console.error("[onramp] token error:", e);
    return NextResponse.json({ error: "Couldn't start checkout. Try again." }, { status: 502 });
  }
}
