import { eq, and, inArray } from "drizzle-orm";
import { db, walletsTable, transactionsTable } from "@workspace/db";
import { acct, transfer, accountBalance } from "./ledger";
import {
  onchainEnabled,
  sendUsdc,
  getIncomingUsdc,
  isValidAddress,
  type OnchainResult,
} from "./chain";
import { getWalletForUser } from "./wallet";
import { decryptSecret } from "./crypto";
import { notify } from "./notifications";
import { formatMoney, truncateAddress } from "./money";

/**
 * Crypto rail (USDC on Base). Deposits arrive on-chain to the user's wallet;
 * withdrawals send USDC to any Base address.
 */

export function toMeta(r: OnchainResult) {
  if (r.status === "confirmed") return { txHash: r.hash, onchainStatus: "confirmed" };
  if (r.status === "queued") return { txHash: r.hash, onchainStatus: "queued", onchainXdr: r.xdr };
  return { onchainStatus: "none" as const };
}

/**
 * Testnet faucet: the platform distributor sends test USDC to the user's
 * wallet. Credits the ledger; settles on-chain where the platform is funded.
 */
export async function faucetDeposit(userId: string, amountCents: number) {
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new Error("Wallet not provisioned");
  if (amountCents <= 0 || amountCents > 1_000_00) {
    throw new Error("Enter an amount up to 1,000 test USDC.");
  }

  let onchain: OnchainResult = { status: "skipped", reason: "onchain disabled" };
  if (onchainEnabled()) {
    onchain = await sendUsdc({
      fromPrivateKey: process.env.PLATFORM_PRIVATE_KEY!,
      to: wallet.address,
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
 * Detect real incoming USDC payments to the user's wallet and credit any not
 * already recorded. Returns the number of new deposits credited.
 */
export async function syncDeposits(
  userId: string,
): Promise<{ credited: number; totalCents: number }> {
  const wallet = await getWalletForUser(userId);
  if (!wallet) return { credited: 0, totalCents: 0 };

  const payments = await getIncomingUsdc(wallet.address);
  let credited = 0;
  let totalCents = 0;
  for (const p of payments) {
    // The bare on-chain tx hash is the canonical dedupe key shared by every
    // deposit source (faucet records `p.hash` too), so a faucet send can't be
    // re-imported by sync. We also match the legacy `hash:logIndex` form for
    // any rows written before this canonicalization.
    const [seen] = await db
      .select({ id: transactionsTable.id })
      .from(transactionsTable)
      .where(
        and(
          eq(transactionsTable.type, "deposit"),
          inArray(transactionsTable.txHash, [p.hash, p.opId]),
        ),
      );
    if (seen) continue;
    await transfer({
      type: "deposit",
      description: `USDC deposit from ${truncateAddress(p.from, 4, 4)}`,
      userId,
      fromKey: acct.external,
      toKey: acct.wallet(userId),
      amountCents: p.amountCents,
      onchain: { txHash: p.hash, onchainStatus: "confirmed" },
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
  if ((await accountBalance(acct.wallet(userId))) < amountCents) {
    throw new Error("Insufficient available balance.");
  }
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new Error("Wallet not provisioned");

  let onchain: OnchainResult = { status: "skipped", reason: "onchain disabled" };
  if (onchainEnabled()) {
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
    requireSufficientFrom: true,
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
