import "server-only";
import { db } from "@/lib/db";
import { acct, transfer } from "./ledger";
import { onchainEnabled, sendPayment, type OnchainResult } from "./stellar";

/**
 * Fiat on-ramp (Yellowcard, in production). KYC is required for local-currency
 * deposits — enforced here. On testnet the platform distributor sends real USDC
 * to the user's wallet; the ledger records external → wallet.
 */
export async function deposit(userId: string, amountCents: number) {
  const user = await db.user.findUnique({ where: { id: userId }, include: { wallet: true } });
  if (!user) throw new Error("User not found");
  if (user.kycStatus !== "verified") {
    throw new Error("KYC verification is required before depositing local currency.");
  }
  if (!user.wallet) throw new Error("Wallet not provisioned");

  let onchain: OnchainResult = { status: "skipped", reason: "onchain disabled" };
  if (onchainEnabled()) {
    onchain = await sendPayment({
      fromSecret: process.env.STELLAR_DISTRIBUTOR_SECRET!,
      toPublicKey: user.wallet.stellarPublicKey,
      amountCents,
      memo: "deposit",
    });
  }

  return transfer({
    type: "deposit",
    description: "Deposit via Yellowcard",
    userId,
    fromKey: acct.external,
    toKey: acct.wallet(userId),
    amountCents,
    onchain: toMeta(onchain),
  });
}

export async function withdraw(userId: string, amountCents: number) {
  const available = await db.posting.aggregate({
    _sum: { amountCents: true },
    where: { account: { key: acct.wallet(userId) } },
  });
  if ((available._sum.amountCents ?? 0) < amountCents) {
    throw new Error("Insufficient available balance");
  }
  return transfer({
    type: "withdrawal",
    description: "Withdrawal to local currency",
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.external,
    amountCents,
  });
}

export function toMeta(r: OnchainResult) {
  if (r.status === "confirmed") return { txHash: r.hash, onchainStatus: "confirmed" };
  if (r.status === "queued")
    return { txHash: r.hash, onchainStatus: "queued", onchainXdr: r.xdr };
  return { onchainStatus: "none" as const };
}
