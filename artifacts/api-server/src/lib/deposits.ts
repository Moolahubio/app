import { eq, and, inArray } from "drizzle-orm";
import { AppError } from "./errors";
import { db, transactionsTable } from "@workspace/db";
import { acct, transfer } from "./ledger";
import {
  onchainEnabled,
  getIncomingUsdc,
  isValidAddress,
  platformAddress,
  goalVaultContract,
  factoryContract,
  verifyUsdcTransferReceipt,
} from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { getWalletForUser, requireWalletForUser, requireServerCustody } from "./wallet";
import { getUserCircleEscrowAddresses } from "./circles";
import { walletSpendableCents } from "./onchainBalances";
import { notify } from "./notifications";
import { formatMoney, truncateAddress } from "./money";
import { logger } from "./logger";

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

/**
 * Testnet faucet: the platform distributor mints test USDC to the user's wallet
 * on-chain. When on-chain settlement is configured the ledger credit is booked
 * 'pending' and only stamped confirmed once the mint settles — a faucet credit
 * that never reaches the chain would be phantom balance the user can't actually
 * spend (on-chain is the source of truth). Offline (no chain configured) the
 * faucet is a pure ledger convenience and books the credit directly.
 */
export async function faucetDeposit(userId: string, amountCents: number) {
  const wallet = await getWalletForUser(userId);
  if (!wallet) throw new AppError("Wallet not provisioned");
  if (amountCents <= 0 || amountCents > 1_000_00) {
    throw new AppError("Enter an amount up to 1,000 test USDC.");
  }
  // When on-chain settlement is configured, the mint must actually land before
  // the credit is spendable, so we book the ledger 'pending' and settle via the
  // reconciler. Offline (no chain), money moves ledger-only (onchainStatus
  // 'none') — the testnet-convenience faucet with no real funding source.
  const settle = onchainEnabled();

  const txn = await db.transaction(async (tx) => {
    const t = await transfer({
      type: "deposit",
      description: "Test USDC received (faucet)",
      userId,
      fromKey: acct.external,
      toKey: acct.wallet(userId),
      amountCents,
      onchain: { onchainStatus: settle ? "pending" : "none" },
      tx,
    });
    if (settle) {
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
  if (settle) kickReconciler();
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
  //
  // Circle escrow clones are per-circle contracts (not the shared factory
  // address), so they must be resolved per-user from this user's circle
  // memberships rather than read from a fixed env-configured address. A
  // rotation-circle payout or accumulation-circle completion pays the member
  // straight from that escrow on-chain, and it is already booked as a
  // `payout`/fee ledger entry by the circle-settlement code path — importing
  // it again here as a fresh deposit would double-credit the same transfer.
  const escrowAddresses = await getUserCircleEscrowAddresses(userId);
  const internalAddresses = new Set<string>(
    [platformAddress(), goalVaultContract(), factoryContract(), ...escrowAddresses]
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
  // Server-signed withdrawal path (custodial wallets only). A non-custodial
  // (Privy) wallet has no server key, so this path would debit the ledger and
  // then fail forever in the reconciler, stranding the debit. Refuse up front,
  // before any booking; those wallets withdraw via the client-signed confirm
  // path (POST /wallet/withdraw/submitted) instead.
  const wallet = await requireServerCustody(
    userId,
    "This wallet is non-custodial — withdrawals are signed on your device.",
  );
  // Gate on the spendable balance: on-chain (confirmed minus in-flight outflows)
  // when configured, else the ledger balance offline. On-chain USDC is the source
  // of truth for what can be spent whenever a chain is available.
  if ((await walletSpendableCents(userId, wallet.address)) < amountCents) {
    throw new AppError("Insufficient available balance.");
  }
  const settle = onchainEnabled();

  const txn = await db.transaction(async (tx) => {
    const t = await transfer({
      type: "withdrawal",
      description: `USDC withdrawal to ${truncateAddress(destination, 4, 4)}`,
      userId,
      fromKey: acct.wallet(userId),
      toKey: acct.external,
      amountCents,
      onchain: { onchainStatus: settle ? "pending" : "none" },
      requireSufficientFrom: true,
      tx,
    });
    if (settle) {
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
  if (settle) kickReconciler();
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

/**
 * Confirm a client-signed (non-custodial) withdrawal. The user's Privy embedded
 * EOA already signed and broadcast the USDC transfer; the server holds no key
 * and NEVER signs. We independently verify the on-chain receipt, then record the
 * withdrawal in the ledger for history/display.
 *
 * Because the transfer is already irreversibly on-chain, we book it WITHOUT
 * requireSufficientFrom — a ledger shortfall can't unsend it, and integrity here
 * is simply that the postings net to zero (the transient negative wallet:<uid>
 * balance is fine; spendable balance is read on-chain). The partial unique index
 * over (tx_hash) WHERE type='withdrawal' is the authoritative guard against
 * booking the same broadcast twice (double-submit / retry).
 */
export async function confirmClientWithdrawal(
  userId: string,
  txHash: string,
  amountCents: number,
  destination: string,
): Promise<{ alreadyRecorded: boolean }> {
  if (amountCents <= 0) throw new AppError("Enter a valid amount.");
  if (!isValidAddress(destination)) {
    throw new AppError("Enter a valid Monad address (starts with 0x).");
  }
  const wallet = await requireWalletForUser(userId);
  if (wallet.custody !== "privy") {
    // Server-custody wallets withdraw via the server-signed /wallet/withdraw
    // path; only non-custodial wallets confirm a client-signed send here.
    throw new AppError("This wallet doesn't use client-signed withdrawals.");
  }
  if (destination.toLowerCase() === wallet.address.toLowerCase()) {
    // A self-transfer verifies on-chain (from===to===wallet) but moves nothing;
    // booking it would inflate the ledger/history with a phantom withdrawal.
    throw new AppError("Enter a destination other than your own wallet.");
  }

  const verified = await verifyUsdcTransferReceipt({
    hash: txHash,
    from: wallet.address,
    to: destination,
    amountCents,
  });
  if (!verified.ok) {
    logger.warn(
      { userId, txHash, reason: verified.reason },
      "client withdrawal receipt verification failed",
    );
    throw new AppError("We couldn't verify that withdrawal on-chain. Please try again.");
  }

  try {
    await transfer({
      type: "withdrawal",
      description: `USDC withdrawal to ${truncateAddress(destination, 4, 4)}`,
      userId,
      fromKey: acct.wallet(userId),
      toKey: acct.external,
      amountCents,
      onchain: { txHash, onchainStatus: "confirmed" },
    });
  } catch (e) {
    // The partial unique index rejects a second booking of the same broadcast.
    // Treat that as already-recorded so a retrying client sees success and we
    // never double-count the ledger.
    if (isUniqueViolation(e)) return { alreadyRecorded: true };
    throw e;
  }

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
  return { alreadyRecorded: false };
}
