import "server-only";
import { db } from "@/lib/db";
import { acct, transfer } from "./ledger";
import {
  onchainEnabled,
  sendUsdc,
  getIncomingUsdc,
  isValidAddress,
  type OnchainResult,
} from "./chain";
import { notify } from "./notifications";
import { formatMoney, truncateAddress } from "@/lib/utils";

/**
 * Crypto rail (USDC on Base). Deposits arrive on-chain to the user's wallet;
 * withdrawals send USDC to any Base address. No KYC gate on the crypto rail.
 * (Local-currency on/off-ramp via a fiat partner is planned for later.)
 */

async function availableCents(userId: string) {
  const r = await db.posting.aggregate({
    _sum: { amountCents: true },
    where: { account: { key: acct.wallet(userId) } },
  });
  return r._sum.amountCents ?? 0;
}

/**
 * Testnet faucet: the platform distributor sends test USDC to the user's
 * wallet so flows can be exercised before real funds exist. Credits the ledger.
 */
export async function faucetDeposit(userId: string, amountCents: number) {
  const user = await db.user.findUnique({ where: { id: userId }, include: { wallet: true } });
  if (!user?.wallet) throw new Error("Wallet not provisioned");
  if (amountCents <= 0 || amountCents > 1_000_00) {
    throw new Error("Enter an amount up to 1,000 test USDC.");
  }

  let onchain: OnchainResult = { status: "skipped", reason: "onchain disabled" };
  if (onchainEnabled()) {
    onchain = await sendUsdc({
      fromPrivateKey: process.env.PLATFORM_PRIVATE_KEY!,
      to: user.wallet.address,
      amountCents,
      memo: "faucet",
    });
  }

  const txn = await transfer({
    type: "deposit",
    description: "Test USDC received (faucet)",
    userId,
    fromKey: acct.external,
    toKey: acct.wallet(userId),
    amountCents,
    onchain: toMeta(onchain),
  });
  await notify(userId, {
    type: "deposit",
    title: "USDC received",
    body: `${formatMoney(amountCents)} is now in your wallet.`,
    link: "/activity",
  });
  return txn;
}

/**
 * Detect real incoming USDC payments to the user's wallet and credit any that
 * aren't already recorded. Returns the number of new deposits credited.
 */
export async function syncDeposits(userId: string): Promise<{ credited: number; totalCents: number }> {
  const user = await db.user.findUnique({ where: { id: userId }, include: { wallet: true } });
  if (!user?.wallet) return { credited: 0, totalCents: 0 };

  const payments = await getIncomingUsdc(user.wallet.address);
  let credited = 0;
  let totalCents = 0;
  for (const p of payments) {
    // Dedupe on the on-chain reference (we store the op id as txHash for deposits).
    const seen = await db.transaction.findFirst({ where: { type: "deposit", txHash: p.opId } });
    if (seen) continue;
    await transfer({
      type: "deposit",
      description: `USDC deposit from ${truncateAddress(p.from, 4, 4)}`,
      userId,
      fromKey: acct.external,
      toKey: acct.wallet(userId),
      amountCents: p.amountCents,
      onchain: { txHash: p.opId, onchainStatus: "confirmed" },
    });
    await notify(userId, {
      type: "deposit",
      title: "USDC received",
      body: `${formatMoney(p.amountCents)} arrived in your wallet.`,
      link: "/activity",
    });
    credited += 1;
    totalCents += p.amountCents;
  }
  return { credited, totalCents };
}

/** Withdraw USDC on-chain to an external Base address. */
export async function withdrawToAddress(userId: string, amountCents: number, destination: string) {
  if (!isValidAddress(destination)) {
    throw new Error("Enter a valid Base address (starts with 0x).");
  }
  if (amountCents <= 0) throw new Error("Enter a valid amount.");
  if ((await availableCents(userId)) < amountCents) {
    throw new Error("Insufficient available balance.");
  }
  const wallet = await db.wallet.findUnique({ where: { userId } });
  if (!wallet) throw new Error("Wallet not provisioned");

  let onchain: OnchainResult = { status: "skipped", reason: "onchain disabled" };
  if (onchainEnabled()) {
    const { decryptSecret } = await import("./crypto");
    onchain = await sendUsdc({
      fromPrivateKey: decryptSecret(wallet.privateKeyEnc),
      to: destination,
      amountCents,
      memo: "withdrawal",
    });
  }

  const txn = await transfer({
    type: "withdrawal",
    description: `USDC withdrawal to ${truncateAddress(destination, 4, 4)}`,
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.external,
    amountCents,
    onchain: toMeta(onchain),
  });
  await notify(userId, {
    type: "withdrawal",
    title: "Withdrawal sent",
    body: `${formatMoney(amountCents)} sent to ${truncateAddress(destination, 4, 4)}.`,
    link: "/activity",
  }, { email: true });
  return txn;
}

/**
 * Record a withdrawal that the user already broadcast from their Base Account
 * (a sponsored, gasless UserOp signed client-side). The chain move happened in
 * the browser; here we validate and debit the ledger with the real tx hash.
 */
export async function recordWithdrawal(
  userId: string,
  amountCents: number,
  destination: string,
  txHash: string,
) {
  if (!isValidAddress(destination)) throw new Error("Invalid destination address.");
  if (amountCents <= 0) throw new Error("Invalid amount.");
  if ((await availableCents(userId)) < amountCents) {
    throw new Error("Insufficient available balance.");
  }
  const txn = await transfer({
    type: "withdrawal",
    description: `USDC withdrawal to ${truncateAddress(destination, 4, 4)}`,
    userId,
    fromKey: acct.wallet(userId),
    toKey: acct.external,
    amountCents,
    onchain: { txHash, onchainStatus: "confirmed" },
  });
  await notify(
    userId,
    {
      type: "withdrawal",
      title: "Withdrawal sent",
      body: `${formatMoney(amountCents)} sent to ${truncateAddress(destination, 4, 4)}.`,
      link: "/activity",
    },
    { email: true },
  );
  return txn;
}

export function toMeta(r: OnchainResult) {
  if (r.status === "confirmed") return { txHash: r.hash, onchainStatus: "confirmed" };
  if (r.status === "queued")
    return { txHash: r.hash, onchainStatus: "queued", onchainXdr: r.xdr };
  return { onchainStatus: "none" as const };
}
