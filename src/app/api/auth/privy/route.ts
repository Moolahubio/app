import { NextResponse } from "next/server";
import { db } from "@/lib/db";
import { createSession } from "@/lib/server/auth";
import { createWalletForUser } from "@/lib/server/wallet";
import { privyEnabled, verifyPrivyToken, getPrivyProfile } from "@/lib/server/privy";

/**
 * Bridge: client posts its Privy access token; we verify it, find-or-create the
 * matching MoolaHub user (+ wallet), and issue our own session cookie.
 */
export async function POST(req: Request) {
  if (!privyEnabled()) {
    return NextResponse.json({ error: "Privy is not configured" }, { status: 400 });
  }

  let token: string | undefined;
  try {
    ({ token } = await req.json());
  } catch {
    return NextResponse.json({ error: "Invalid request body" }, { status: 400 });
  }
  if (!token) return NextResponse.json({ error: "Missing token" }, { status: 400 });

  let did: string;
  try {
    did = await verifyPrivyToken(token);
  } catch {
    return NextResponse.json({ error: "Invalid Privy token" }, { status: 401 });
  }

  let user = await db.user.findUnique({ where: { privyId: did } });
  if (!user) {
    const profile = await getPrivyProfile(did);
    const email =
      profile.email?.toLowerCase() ?? `${did.replace(/[^a-z0-9]/gi, "").slice(-12)}@privy.moolahub`;
    const name = profile.name ?? profile.email?.split("@")[0] ?? "MoolaHub Saver";

    // Link to an existing email account if present, else create a new one.
    const existing = await db.user.findUnique({ where: { email } });
    user = existing
      ? await db.user.update({ where: { id: existing.id }, data: { privyId: did } })
      : await db.user.create({ data: { email, name, privyId: did, kycStatus: "unstarted" } });

    await createWalletForUser(user.id);
  }

  await createSession(user.id);
  return NextResponse.json({ ok: true });
}
