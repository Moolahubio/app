import { eq, and, inArray } from "drizzle-orm";
import { AppError } from "./errors";
import { db, transactionsTable } from "@workspace/db";
import { acct, transfer, accountBalance } from "./ledger";
import { onchainEnabled, getIncomingUsdc, isValidAddress } from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { getWalletForUser } from "./wallet";
import { notify } from "./notifications";
import { formatMoney, truncateAddress } from "./money";

/**
 * Crypto rail (USDC on Base). Deposits arrive on-chain to the user's wallet;
 * withdrawals send USDC to any Base address.
 *
 * Money moves through the double-entry ledger synchronously (source of truth);
 * the matching USDC transfer is enqueued and settled out of band by the
 * reconciler (`lib/settlement.ts`), so an unfunded wallet or unreachable RPC
 * leaves the transfer "pending" rather than silently ledger-only.
 */

/** Initial on-chain meta for a movement: pending when settlement is configured. */
function initialOnchainMeta() {
  return onchainEnabled()
    ? { onchainStatus: "pending" as const }
    : { onchainStatus: "none" as const };
}

/** Postgres unique-violation (SQLSTATE 23505), surfaced by node-postgres. */
function isUniqueViolation(e: unknown): boolean {
  return (
    typeof e === "object" &&
    e !== null &&
    (e as { code?: string }).code === "23505"
  );
}

/**
 * Testnet faucet: the platform distributor sends test USDC to the user's
 * wallet. Credits the ledger; settles on-chain where the platform is funded.
 */
export async function faucetDeposit(userId: string, amountCents: number) {
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new AppError("Wallet not provisioned");
  if (amountCents <= 0 || amountCents > 1_000_00) {
    throw new AppError("Enter an amount up to 1,000 test USDC.");
  }

  const enabled = onchainEnabled();
  const txn = await db.transaction(async (tx) => {
    const t = await transfer({
      type: "deposit",
      description: "Test USDC received (faucet)",
      userId,
      fromKey: acct.external,
      toKey: acct.wallet(userId),
      amountCents,
      onchain: initialOnchainMeta(),
      tx,
    });
    if (enabled) {
      await enqueueOnchainTransfer(
        {
          transactionId: t.id,
          kind: "faucet",
          sourceUserId: null,
          toAddress: wallet.address,
          amountCents,
          memo: "faucet",
        },
        tx,
      );
    }
    return t;
  });
  if (enabled) kickReconciler();
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
    try {
      await transfer({
        type: "deposit",
        description: `USDC deposit from ${truncateAddress(p.from, 4, 4)}`,
        userId,
        fromKey: acct.external,
        toKey: acct.wallet(userId),
        amountCents: p.amountCents,
        onchain: { txHash: p.hash, onchainStatus: "confirmed" },
      });
    } catch (e) {
      // A concurrent /wallet/sync already credited this exact tx hash: the
      // partial unique index on (tx_hash) WHERE type='deposit' rejected the
      // duplicate insert. Skip without re-crediting — this is the race-safe
      // guard against double-crediting the same on-chain deposit.
      if (isUniqueViolation(e)) continue;
      throw e;
    }
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
    throw new AppError("Enter a valid Base address (starts with 0x).");
  }
  if (amountCents <= 0) throw new AppError("Enter a valid amount.");
  if ((await accountBalance(acct.wallet(userId))) < amountCents) {
    throw new AppError("Insufficient available balance.");
  }
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new AppError("Wallet not provisioned");

  const enabled = onchainEnabled();
  const txn = await db.transaction(async (tx) => {
    const t = await transfer({
      type: "withdrawal",
      description: `USDC withdrawal to ${truncateAddress(destination, 4, 4)}`,
      userId,
      fromKey: acct.wallet(userId),
      toKey: acct.external,
      amountCents,
      onchain: initialOnchainMeta(),
      requireSufficientFrom: true,
      tx,
    });
    if (enabled) {
      await enqueueOnchainTransfer(
        {
          transactionId: t.id,
          kind: "withdrawal",
          sourceUserId: userId,
          toAddress: destination,
          amountCents,
          memo: "withdrawal",
        },
        tx,
      );
    }
    return t;
  });
  if (enabled) kickReconciler();
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
