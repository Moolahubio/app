import { eq, and, inArray } from "drizzle-orm";
import { AppError } from "./errors";
import { db, transactionsTable } from "@workspace/db";
import { acct, transfer, accountBalance } from "./ledger";
import {
  onchainEnabled,
  getIncomingUsdc,
  isValidAddress,
  platformAddress,
  goalVaultContract,
  factoryContract,
} from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { getWalletForUser } from "./wallet";
import { notify } from "./notifications";
import { formatMoney, truncateAddress } from "./money";

/**
 * Crypto rail (USDC on Monad). Deposits arrive on-chain to the user's wallet;
 * withdrawals send USDC to any Monad address.
 *
 * Money moves through the double-entry ledger synchronously (source of truth);
 * the matching USDC transfer is enqueued and settled out of band by the
 * reconciler (`lib/settlement.ts`), so an unfunded wallet or unreachable RPC
 * leaves the transfer "pending" rather than silently ledger-only.
 */

/** Postgres unique-violation SQLSTATE, used to detect a lost dedupe race. */
function isUniqueViolation(e: unknown): boolean {
  return (
    typeof e === "object" &&
    e !== null &&
    "code" in e &&
    (e as { code?: unknown }).code === "23505"
  );
}

/** Initial on-chain meta for a movement: pending when settlement is configured. */
function initialOnchainMeta() {
  return onchainEnabled()
    ? { onchainStatus: "pending" as const }
    : { onchainStatus: "none" as const };
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
    body: `${formatMoney(amountCents)} was added to your wallet.`,
    link: "/activity",
  });
  return txn;
}

/**
 * Detect real incoming USDC payments to the user's wallet and credit any not
 * already recorded. Returns the number of new deposits credited.
 *
 * Only transfers from addresses that are NOT internal platform contracts are
 * eligible. Transfers from the platform distributor, goal vault, or circle
 * factory are already booked under other transaction types (payout, goal_release,
 * etc.) and must never be re-imported as fresh deposits.
 */
export async function syncDeposits(
  userId: string,
): Promise<{ credited: number; totalCents: number }> {
  const wallet = await getWalletForUser(userId);
  if (!wallet) return { credited: 0, totalCents: 0 };

  // Collect all known internal sender addresses (lower-cased for comparison).
  // These are platform-controlled contracts whose outgoing USDC transfers to
  // user wallets represent already-booked ledger entries (payouts, goal
  // withdrawals, etc.) and must never be imported as external deposits.
  const internalAddresses = new Set<string>(
    [platformAddress(), goalVaultContract(), factoryContract()]
      .filter((a): a is string => Boolean(a))
      .map((a) => a.toLowerCase()),
  );

  const payments = await getIncomingUsdc(wallet.address);
  let credited = 0;
  let totalCents = 0;
  for (const p of payments) {
    // Reject transfers originating from internal platform addresses. These are
    // app-generated outflows (payouts, goal withdrawals, faucet sends) that
    // already have a ledger entry under another transaction type. Importing them
    // again would create duplicate balance.
    if (internalAddresses.has(p.from.toLowerCase())) continue;

    // The bare on-chain tx hash is the canonical dedupe key shared by every
    // transaction type. We check across all types (not just 'deposit') so that
    // a hash already recorded as goal_withdraw, payout, faucet, etc. is not
    // re-imported as a new deposit. We also match the legacy `hash:logIndex`
    // form for any rows written before this canonicalization.
    const [seen] = await db
      .select({ id: transactionsTable.id })
      .from(transactionsTable)
      .where(inArray(transactionsTable.txHash, [p.hash, p.opId]));
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
      // Authoritative dedupe guard: the unique index on transactions(tx_hash)
      // WHERE tx_hash IS NOT NULL rejects any second insert for the same hash,
      // regardless of transaction type. The pre-check above is only a fast
      // path; two concurrent /wallet/sync calls can both pass it, so the index
      // is what actually prevents double-crediting. Treat the rejection as
      // "already credited" and skip.
      if (isUniqueViolation(e)) continue;
      throw e;
    }
    await notify(userId, {
      type: "deposit",
      title: "USDC received",
      body: `${formatMoney(p.amountCents)} was added to your wallet.`,
      link: "/activity",
    });
    credited += 1;
    totalCents += p.amountCents;
  }
  return { credited, totalCents };
}

/** Withdraw USDC on-chain to an external Monad address. */
export async function withdrawToAddress(userId: string, amountCents: number, destination: string) {
  if (!isValidAddress(destination)) {
    throw new AppError("Enter a valid Monad address (starts with 0x).");
  }
  if (amountCents <= 0) throw new AppError("Enter a valid amount.");
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new AppError("Set up your wallet first to withdraw.");
  if ((await accountBalance(acct.wallet(userId))) < amountCents) {
    throw new AppError("Insufficient available balance.");
  }

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
