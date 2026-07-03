import { eq, and, or, inArray, isNull, lt, asc, desc, sql } from "drizzle-orm";
import {
  db,
  onchainTransfersTable,
  transactionsTable,
  contributionsTable,
  postingsTable,
  circlesTable,
  circleMembersTable,
  type OnchainTransfer,
} from "@workspace/db";
import { onchainEnabled, sendUsdc, mintUsdc, escrowContribute, goalDeposit, goalWithdraw } from "./chain";
import { getSigningSecret } from "./wallet";
import { notify } from "./notifications";
import { formatMoney } from "./money";
import { logger } from "./logger";

/**
 * On-chain settlement reconciler.
 *
 * The double-entry ledger is the source of truth and commits synchronously. The
 * matching USDC transfer on Monad is enqueued in `onchain_transfers` and settled
 * here, out of band. Instead of silently degrading a money movement to
 * ledger-only when the platform/user wallet is unfunded or the RPC is
 * unreachable, the transfer stays "pending" and is retried until it confirms.
 *
 * Safety:
 *  - Rows are claimed with `FOR UPDATE SKIP LOCKED` and flipped pending ->
 *    processing inside one transaction, so overlapping ticks / multiple workers
 *    never pick the same row (no double-send).
 *  - Confirm is idempotent: if the underlying transaction is already confirmed
 *    on another path, we just mark the queue row confirmed without re-sending.
 */

type Executor = Parameters<Parameters<typeof db.transaction>[0]>[0];
type DbLike = typeof db | Executor;

const RECONCILE_INTERVAL_MS = 15_000;
// Don't re-attempt a just-tried transfer on the very next tick; back off so an
// unfunded wallet (the expected testnet state) doesn't hammer the RPC.
const RETRY_BACKOFF_MS = 30_000;
const BATCH_SIZE = 10;
// After this many attempts a transfer is treated as permanently broken (e.g. an
// invalid destination address) and moved to the dead-letter state instead of
// being retried forever. Overridable so ops can tune it per environment.
const MAX_ATTEMPTS = Number(process.env.SETTLEMENT_MAX_ATTEMPTS) || 10;

// Known queue states, surfaced in the operator overview even when empty so an
// operator always sees every category at a glance.
const OVERVIEW_STATUSES = ["pending", "processing", "confirmed", "failed"] as const;
// Cap on rows fetched for the overview's per-status sample. Counts/totals are
// exact (aggregated separately); the row list is the most-recently-touched slice.
const OVERVIEW_ROW_LIMIT = 200;

export type SettlementTransferView = {
  id: string;
  kind: string;
  amountCents: number;
  attempts: number;
  status: string;
  toAddress: string;
  memo: string | null;
  lastError: string | null;
  txHash: string | null;
  lastAttemptAt: string | null;
  createdAt: string;
  updatedAt: string;
};

export type SettlementStatusGroup = {
  status: string;
  count: number;
  totalAmountCents: number;
  /** Most-recently-touched transfers in this status (a sample if count is large). */
  transfers: SettlementTransferView[];
};

export type SettlementOverview = {
  onchainEnabled: boolean;
  maxAttempts: number;
  rowLimit: number;
  /** True when the total queue size exceeds the sampled rows, so groups are partial. */
  truncated: boolean;
  groups: SettlementStatusGroup[];
};

function toView(row: OnchainTransfer): SettlementTransferView {
  return {
    id: row.id,
    kind: row.kind,
    amountCents: row.amountCents,
    attempts: row.attempts,
    status: row.status,
    toAddress: row.toAddress,
    memo: row.memo ?? null,
    lastError: row.lastError ?? null,
    txHash: row.txHash ?? null,
    lastAttemptAt: row.lastAttemptAt ? row.lastAttemptAt.toISOString() : null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

/**
 * Read-only snapshot of the on-chain settlement queue for operators: exact
 * counts and total amounts per status, plus a sample of the most-recently-
 * touched rows (capped at OVERVIEW_ROW_LIMIT) carrying the fields needed to
 * triage a stuck transfer — kind, amount, attempts, lastError, lastAttemptAt and
 * txHash. Does not mutate anything.
 */
export async function getSettlementOverview(): Promise<SettlementOverview> {
  const countRows = await db
    .select({
      status: onchainTransfersTable.status,
      count: sql<number>`count(*)::int`,
      totalAmountCents: sql<number>`coalesce(sum(${onchainTransfersTable.amountCents}), 0)::int`,
    })
    .from(onchainTransfersTable)
    .groupBy(onchainTransfersTable.status);

  const sampled = await db
    .select()
    .from(onchainTransfersTable)
    .orderBy(desc(onchainTransfersTable.updatedAt))
    .limit(OVERVIEW_ROW_LIMIT);

  const counts = new Map<string, { count: number; totalAmountCents: number }>();
  for (const r of countRows) {
    counts.set(r.status, { count: r.count, totalAmountCents: r.totalAmountCents });
  }

  const rowsByStatus = new Map<string, SettlementTransferView[]>();
  for (const row of sampled) {
    const list = rowsByStatus.get(row.status) ?? [];
    list.push(toView(row));
    rowsByStatus.set(row.status, list);
  }

  // Preserve a stable order: the known lifecycle states first, then any others.
  const ordered: string[] = [...OVERVIEW_STATUSES];
  for (const status of counts.keys()) {
    if (!ordered.includes(status)) ordered.push(status);
  }

  const totalRows = countRows.reduce((sum, r) => sum + r.count, 0);
  const groups: SettlementStatusGroup[] = ordered.map((status) => {
    const agg = counts.get(status);
    return {
      status,
      count: agg?.count ?? 0,
      totalAmountCents: agg?.totalAmountCents ?? 0,
      transfers: rowsByStatus.get(status) ?? [],
    };
  });

  return {
    onchainEnabled: onchainEnabled(),
    maxAttempts: MAX_ATTEMPTS,
    rowLimit: OVERVIEW_ROW_LIMIT,
    truncated: totalRows > sampled.length,
    groups,
  };
}

export type QueueParams = {
  transactionId: string;
  // - faucet: platform mints MockUSDC to a wallet.
  // - escrow_contribute: a member approves + contributes to the circle's escrow;
  //   the escrow auto-settles the round on the last contribution.
  // - goal_deposit: user approves + deposits USDC into their goal vault balance
  //   (free). memo carries the goal id: `goal:<goalId>`.
  // - goal_withdraw: user withdraws gross from their goal vault balance; the
  //   vault takes the 2% fee on-chain. memo carries the goal id and the ledger
  //   fee transaction id to confirm: `goal:<goalId>:<feeTxnId>`.
  // - withdrawal (and legacy contribution/payout): a direct ERC20 USDC transfer.
  kind:
    | "faucet"
    | "withdrawal"
    | "contribution"
    | "payout"
    | "escrow_contribute"
    | "goal_deposit"
    | "goal_withdraw";
  // null => the platform distributor wallet is the source.
  sourceUserId: string | null;
  toAddress: string;
  amountCents: number;
  memo?: string;
  contributionId?: string | null;
};

/**
 * Enqueue an on-chain transfer for the reconciler. Pass the caller's `tx` so the
 * queue row commits atomically with the ledger posting it settles — otherwise a
 * crash between the two would leave a "pending" transaction with nothing to
 * settle it.
 */
export async function enqueueOnchainTransfer(params: QueueParams, exec: DbLike = db): Promise<void> {
  await exec.insert(onchainTransfersTable).values({
    transactionId: params.transactionId,
    contributionId: params.contributionId ?? null,
    kind: params.kind,
    sourceUserId: params.sourceUserId,
    toAddress: params.toAddress,
    amountCents: params.amountCents,
    memo: params.memo ?? null,
    status: "pending",
  });
}

async function resolveSourceKey(row: OnchainTransfer): Promise<string | null> {
  if (row.sourceUserId === null) {
    const raw = process.env.PLATFORM_PRIVATE_KEY;
    return raw ? raw : null;
  }
  return getSigningSecret(row.sourceUserId);
}

async function markConfirmed(row: OnchainTransfer, hash: string): Promise<void> {
  await db.transaction(async (tx) => {
    await tx
      .update(onchainTransfersTable)
      .set({ status: "confirmed", txHash: hash, lastError: null })
      .where(eq(onchainTransfersTable.id, row.id));
    await tx
      .update(transactionsTable)
      .set({ txHash: hash, onchainStatus: "confirmed" })
      .where(eq(transactionsTable.id, row.transactionId));
    if (row.contributionId) {
      await tx
        .update(contributionsTable)
        .set({ txHash: hash })
        .where(eq(contributionsTable.id, row.contributionId));
    }
  });
}

/**
 * Stamp a rotation circle's payout (and fee) ledger transactions as confirmed
 * with the escrow's settlement tx hash. The escrow settles a round atomically
 * when its last member contributes (emitting RoundSettled); we mirror that by
 * confirming the matching pending payout/fee rows for this circle + round. The
 * payout rows are always created before the round can settle on-chain, so a
 * normal run finds them; the WHERE clause makes it idempotent.
 */
async function backfillPayoutSettlement(circleId: string, round: number, hash: string): Promise<void> {
  await db
    .update(transactionsTable)
    .set({ txHash: hash, onchainStatus: "confirmed" })
    .where(
      and(
        eq(transactionsTable.circleId, circleId),
        eq(transactionsTable.round, round),
        inArray(transactionsTable.type, ["payout", "fee"]),
        eq(transactionsTable.onchainStatus, "pending"),
      ),
    );
}

/** Parse `susu:<circleId>:<round>` memos into their circle id. */
function circleIdFromMemo(memo: string | null): string | null {
  if (!memo) return null;
  const parts = memo.split(":");
  return parts[0] === "susu" && parts[1] ? parts[1] : null;
}

/** Parse `susu:<circleId>:<round>` memos into circle id + round (for unwinding). */
function circleRoundFromMemo(memo: string | null): { circleId: string; round: number } | null {
  if (!memo) return null;
  const parts = memo.split(":");
  if (parts[0] !== "susu" || !parts[1] || parts[2] === undefined) return null;
  const round = Number(parts[2]);
  if (!Number.isInteger(round)) return null;
  return { circleId: parts[1], round };
}

/** Parse `payout:<circleId>` memos (accumulation savings-returned) into circle id. */
function payoutCircleFromMemo(memo: string | null): string | null {
  if (!memo) return null;
  const parts = memo.split(":");
  return parts[0] === "payout" && parts[1] ? parts[1] : null;
}

/**
 * Parse `goal:<goalId>[:<feeTxnId>]` memos. `goalId` is the on-chain key; the
 * optional `feeTxnId` is the ledger fee transaction a withdraw must confirm
 * alongside its net release (carried per-row so concurrent withdraws on the
 * same goal each confirm exactly their own fee posting).
 */
function goalFromMemo(memo: string | null): { goalId: string; feeTxnId: string | null } | null {
  if (!memo) return null;
  const parts = memo.split(":");
  if (parts[0] !== "goal" || !parts[1]) return null;
  return { goalId: parts[1], feeTxnId: parts[2] || null };
}

/** Stamp a specific pending ledger transaction confirmed with `hash`. */
async function confirmTxnById(txnId: string, hash: string): Promise<void> {
  await db
    .update(transactionsTable)
    .set({ txHash: hash, onchainStatus: "confirmed" })
    .where(and(eq(transactionsTable.id, txnId), eq(transactionsTable.onchainStatus, "pending")));
}

/**
 * Confirm a goal withdrawal atomically: the queue row, the net release txn, and
 * the fee txn all settle on the SAME on-chain withdrawal, so stamp them with the
 * tx hash in one DB transaction. This guarantees the fee txn can never be left
 * pending after the net release confirms.
 */
async function confirmGoalWithdraw(
  row: OnchainTransfer,
  hash: string,
  feeTxnId: string | null,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx
      .update(onchainTransfersTable)
      .set({ status: "confirmed", txHash: hash, lastError: null })
      .where(eq(onchainTransfersTable.id, row.id));
    await tx
      .update(transactionsTable)
      .set({ txHash: hash, onchainStatus: "confirmed" })
      .where(eq(transactionsTable.id, row.transactionId));
    if (feeTxnId) {
      await tx
        .update(transactionsTable)
        .set({ txHash: hash, onchainStatus: "confirmed" })
        .where(and(eq(transactionsTable.id, feeTxnId), eq(transactionsTable.onchainStatus, "pending")));
    }
  });
}

async function requeue(rowId: string, reason: string): Promise<void> {
  await db
    .update(onchainTransfersTable)
    .set({ status: "pending", lastError: reason })
    .where(eq(onchainTransfersTable.id, rowId));
}

/**
 * Reverse a ledger transaction by booking a mirror-image `reversal` transaction:
 * one negated posting for every posting of the original, so the two together net
 * to zero and every touched account returns to its pre-transaction balance. No
 * `requireSufficientFrom` — a reversal must ALWAYS succeed to restore balances,
 * even if an intervening spend would make the "from" side look short. Purely
 * ledger-internal (`onchainStatus: 'none'`), since it mirrors an on-chain
 * transfer that never happened. Idempotency is the caller's responsibility (the
 * CAS in `markFailed` guarantees a row is reversed at most once).
 */
async function reverseLedgerTransaction(
  tx: Executor,
  originalTxnId: string,
  description: string,
): Promise<void> {
  const [orig] = await tx
    .select()
    .from(transactionsTable)
    .where(eq(transactionsTable.id, originalTxnId));
  if (!orig) return;
  const origPostings = await tx
    .select()
    .from(postingsTable)
    .where(eq(postingsTable.transactionId, originalTxnId));
  if (origPostings.length === 0) return;
  const [rev] = await tx
    .insert(transactionsTable)
    .values({
      type: "reversal",
      description,
      userId: orig.userId,
      circleId: orig.circleId,
      round: orig.round,
      onchainStatus: "none",
    })
    .returning();
  await tx.insert(postingsTable).values(
    origPostings.map((p) => ({
      transactionId: rev.id,
      accountId: p.accountId,
      amountCents: -p.amountCents,
    })),
  );
}

/**
 * Undo a rotation round whose escrow contribution permanently failed. When the
 * final contribution fills a round, `maybeProcessPayout` books the recipient's
 * payout (and fee) as pending, claims the recipient (`paidOut = true`) and
 * advances the circle. If a contribution then dead-letters, the escrow can never
 * settle that round on-chain, so those pending payout/fee rows must be reversed
 * and the round reopened. A round already stamped 'confirmed' means the escrow
 * DID pay out on-chain — reversing then would be wrong, so we refuse and log
 * loudly for manual intervention.
 */
async function unwindCircleRound(tx: Executor, circleId: string, round: number): Promise<void> {
  const payoutRows = await tx
    .select()
    .from(transactionsTable)
    .where(
      and(
        eq(transactionsTable.circleId, circleId),
        eq(transactionsTable.round, round),
        inArray(transactionsTable.type, ["payout", "fee"]),
      ),
    );
  const confirmed = payoutRows.filter((r) => r.onchainStatus === "confirmed");
  if (confirmed.length > 0) {
    logger.error(
      { circleId, round, confirmed: confirmed.map((r) => r.id) },
      "cannot unwind circle round: payout already settled on-chain; manual reconciliation required",
    );
    return;
  }
  for (const r of payoutRows) {
    await reverseLedgerTransaction(tx, r.id, `Reversal · ${r.description}`);
  }
  // Reopen the recipient's slot so the round can refill and re-pay once retried.
  await tx
    .update(circleMembersTable)
    .set({ paidOut: false })
    .where(and(eq(circleMembersTable.circleId, circleId), eq(circleMembersTable.payoutRound, round)));
  // Roll the circle back to this round. `maybeProcessPayout` advanced it to
  // round+1 (or marked it 'completed' on the last round), so accept either.
  await tx
    .update(circlesTable)
    .set({ status: "active", currentRound: round })
    .where(
      and(
        eq(circlesTable.id, circleId),
        inArray(circlesTable.currentRound, [round, round + 1]),
      ),
    );
}

/**
 * Reverse the ledger side-effects of a dead-lettered transfer so the ledger
 * stops showing money that never moved on-chain. On-chain is the source of
 * truth: when a transfer permanently fails, its USDC never left (or never
 * arrived), so the matching ledger posting must be undone or the funds are
 * stranded (e.g. a failed withdrawal would keep the wallet debited forever,
 * blocking re-spend even though the coins are still on-chain).
 */
async function reverseForKind(tx: Executor, row: OnchainTransfer): Promise<void> {
  switch (row.kind) {
    // Simple single-transaction transfers: reverse the linked ledger txn.
    // faucet: external→wallet mint; withdrawal: wallet→external; goal_deposit:
    // wallet→goal. Undoing each restores the pre-transfer balances.
    case "faucet":
    case "withdrawal":
    case "goal_deposit":
      await reverseLedgerTransaction(tx, row.transactionId, "Reversal · on-chain transfer failed");
      return;
    // goal_withdraw settles the net release AND the fee on one on-chain
    // withdrawal, so both ledger txns must be reversed together.
    case "goal_withdraw": {
      await reverseLedgerTransaction(tx, row.transactionId, "Reversal · goal withdrawal failed");
      const parsed = goalFromMemo(row.memo);
      if (parsed?.feeTxnId) {
        await reverseLedgerTransaction(tx, parsed.feeTxnId, "Reversal · goal withdrawal fee");
      }
      return;
    }
    // A rotation contribution that never reached the escrow: reverse the ledger
    // contribution, delete the contribution record (it never settled), and
    // unwind the round it may have triggered.
    case "escrow_contribute": {
      await reverseLedgerTransaction(tx, row.transactionId, "Reversal · circle contribution failed");
      if (row.contributionId) {
        await tx.delete(contributionsTable).where(eq(contributionsTable.id, row.contributionId));
      }
      const parsed = circleRoundFromMemo(row.memo);
      if (parsed) await unwindCircleRound(tx, parsed.circleId, parsed.round);
      return;
    }
    // Accumulation savings-returned payout (platform → member wallet) that
    // failed to send: reverse the payout and reopen the member's claim so a
    // retry can pay them. This should be rare, so log it loudly.
    case "payout": {
      await reverseLedgerTransaction(tx, row.transactionId, "Reversal · payout failed");
      const circleId = payoutCircleFromMemo(row.memo);
      const [origTxn] = await tx
        .select({ userId: transactionsTable.userId })
        .from(transactionsTable)
        .where(eq(transactionsTable.id, row.transactionId));
      if (circleId && origTxn?.userId) {
        await tx
          .update(circleMembersTable)
          .set({ paidOut: false })
          .where(
            and(
              eq(circleMembersTable.circleId, circleId),
              eq(circleMembersTable.userId, origTxn.userId),
            ),
          );
      }
      logger.error(
        { rowId: row.id, circleId, txnId: row.transactionId },
        "accumulation payout dead-lettered; reversed and reopened member claim",
      );
      return;
    }
    // Legacy direct "contribution" transfers have no round machinery to unwind.
    default:
      await reverseLedgerTransaction(tx, row.transactionId, "Reversal · on-chain transfer failed");
      return;
  }
}

/**
 * Dead-letter a transfer: flip the queue row 'failed' (so the claim query never
 * picks it up again), flag the linked ledger transaction 'failed', and REVERSE
 * its ledger side-effects so the ledger matches on-chain reality (the money
 * never moved). The CAS on `status = 'processing'` makes this exactly-once: only
 * the pass that flips the row does the reversal, so a double call (e.g. a retry
 * path) can never reverse twice. All of it commits in one transaction.
 */
async function markFailed(row: OnchainTransfer, reason: string): Promise<void> {
  const reversed = await db.transaction(async (tx) => {
    const flipped = await tx
      .update(onchainTransfersTable)
      .set({ status: "failed", lastError: reason })
      .where(and(eq(onchainTransfersTable.id, row.id), eq(onchainTransfersTable.status, "processing")))
      .returning({ id: onchainTransfersTable.id });
    if (flipped.length === 0) return false;
    await tx
      .update(transactionsTable)
      .set({ onchainStatus: "failed" })
      .where(eq(transactionsTable.id, row.transactionId));
    await reverseForKind(tx, row);
    return true;
  });
  if (!reversed) return;
  logger.warn({ rowId: row.id, kind: row.kind, reason }, "settlement transfer dead-lettered and reversed");
  // Notify the source user (best-effort, outside the ledger transaction) that
  // their movement was refunded. Platform-sourced transfers (faucet/payout) have
  // no source user to notify.
  if (row.sourceUserId) {
    await notify(
      row.sourceUserId,
      {
        type: "refund",
        title: "Transfer reversed",
        body: `A ${formatMoney(row.amountCents)} transfer couldn't be completed on-chain and was returned to your balance.`,
        link: "/wallet",
      },
      { email: true },
    ).catch((e) => logger.warn({ err: e, rowId: row.id }, "refund notification failed"));
  }
}

/**
 * A transfer didn't settle this pass. Retry it (back to 'pending') unless it has
 * exhausted MAX_ATTEMPTS, in which case dead-letter it. The claim step already
 * bumped `attempts` in the DB, but the in-memory `row.attempts` still holds the
 * pre-claim value, so the attempt just made is `row.attempts + 1`.
 */
async function requeueOrFail(row: OnchainTransfer, reason: string): Promise<void> {
  const attemptsMade = row.attempts + 1;
  if (attemptsMade >= MAX_ATTEMPTS) {
    logger.warn(
      { rowId: row.id, kind: row.kind, attempts: attemptsMade, reason },
      "settlement transfer exhausted retries; dead-lettering",
    );
    await markFailed(row, reason);
    return;
  }
  await requeue(row.id, reason);
}

async function processRow(row: OnchainTransfer): Promise<boolean> {
  // Idempotency guard: if the ledger transaction is already settled (e.g. a
  // duplicate queue row or a prior partial run), don't send again.
  const [txn] = await db
    .select({ onchainStatus: transactionsTable.onchainStatus, txHash: transactionsTable.txHash })
    .from(transactionsTable)
    .where(eq(transactionsTable.id, row.transactionId));
  if (txn?.onchainStatus === "confirmed") {
    await db
      .update(onchainTransfersTable)
      .set({ status: "confirmed", txHash: txn.txHash ?? row.txHash, lastError: null })
      .where(eq(onchainTransfersTable.id, row.id));
    // Crash-recovery: a goal_withdraw confirms both the net release txn (this
    // row) and the fee txn (id in memo). If a prior pass confirmed the net txn
    // but died before the fee txn, backfill it now so the fee can't stay pending
    // forever even though it settled in the same on-chain withdrawal.
    if (row.kind === "goal_withdraw") {
      const parsed = goalFromMemo(row.memo);
      if (parsed?.feeTxnId) await confirmTxnById(parsed.feeTxnId, txn.txHash ?? row.txHash ?? "");
    }
    return false;
  }

  // Faucet mints test USDC straight to the wallet; the platform signs internally
  // (mint is permissionless), so no per-row signing key is needed.
  if (row.kind === "faucet") {
    const result = await mintUsdc({ to: row.toAddress, amountCents: row.amountCents });
    if (result.status === "confirmed") {
      await markConfirmed(row, result.hash);
      return true;
    }
    await requeueOrFail(row, result.reason);
    return false;
  }

  const fromPrivateKey = await resolveSourceKey(row);
  if (!fromPrivateKey) {
    // No usable signing key: this can't be settled on-chain. Don't block the
    // queue forever — mark it failed (the ledger already reflects the money).
    await markFailed(row, "source signing key unavailable");
    return false;
  }

  // A member contributes to the circle's escrow. When their contribution is the
  // one that fills the round, the escrow auto-settles it (RoundSettled) — we
  // then stamp the matching ledger payout/fee rows with this settlement tx hash.
  if (row.kind === "escrow_contribute") {
    const result = await escrowContribute({
      fromPrivateKey,
      escrow: row.toAddress,
      amountCents: row.amountCents,
    });
    if (result.status === "confirmed") {
      await markConfirmed(row, result.hash);
      if (result.settledRound != null) {
        const circleId = circleIdFromMemo(row.memo);
        if (circleId) {
          await backfillPayoutSettlement(circleId, result.settledRound, result.hash);
        }
      }
      return true;
    }
    await requeueOrFail(row, result.reason);
    return false;
  }

  // A user deposits into their on-chain goal vault balance (free). Signed by
  // the user's key; the memo carries the goal id used to derive the vault key.
  if (row.kind === "goal_deposit") {
    const parsed = goalFromMemo(row.memo);
    if (!parsed) {
      await markFailed(row, "goal_deposit missing goal id in memo");
      return false;
    }
    const result = await goalDeposit({
      fromPrivateKey,
      goalId: parsed.goalId,
      amountCents: row.amountCents,
    });
    if (result.status === "confirmed") {
      await markConfirmed(row, result.hash);
      return true;
    }
    await requeueOrFail(row, result.reason);
    return false;
  }

  // A user withdraws gross from their goal vault balance; the vault routes the
  // 2% fee to the treasury on-chain. We stamp the net release (this row's
  // transaction) and the matching ledger fee transaction (id from the memo)
  // with the same settlement tx hash.
  if (row.kind === "goal_withdraw") {
    const parsed = goalFromMemo(row.memo);
    if (!parsed) {
      await markFailed(row, "goal_withdraw missing goal id in memo");
      return false;
    }
    const result = await goalWithdraw({
      fromPrivateKey,
      goalId: parsed.goalId,
      grossCents: row.amountCents,
    });
    if (result.status === "confirmed") {
      // One on-chain withdrawal settles both the net release and the fee, so
      // confirm the queue row, the net release txn, and the fee txn together in
      // a single DB transaction — a crash can't leave the fee txn dangling.
      await confirmGoalWithdraw(row, result.hash, parsed.feeTxnId);
      return true;
    }
    await requeueOrFail(row, result.reason);
    return false;
  }

  // Default (withdrawal and any legacy direct transfers): a plain ERC20 send.
  const result = await sendUsdc({
    fromPrivateKey,
    to: row.toAddress,
    amountCents: row.amountCents,
    memo: row.memo ?? undefined,
  });

  if (result.status === "confirmed") {
    await markConfirmed(row, result.hash);
    return true;
  }
  // "skipped" — wallet unfunded or RPC unreachable. Both are transient on
  // testnet, so keep retrying rather than dropping to ledger-only — until the
  // attempt budget is spent, at which point it's dead-lettered.
  const reason = result.status === "skipped" ? result.reason : "queued";
  await requeueOrFail(row, reason);
  return false;
}

let running = false;

/**
 * One reconciliation pass: claim a batch of due transfers and try to settle
 * them. Safe to call concurrently — overlapping calls no-op via `running`, and
 * claiming uses row locks so even separate processes won't collide.
 */
export async function runReconciler(limit = BATCH_SIZE): Promise<{ processed: number; confirmed: number }> {
  if (!onchainEnabled()) return { processed: 0, confirmed: 0 };
  if (running) return { processed: 0, confirmed: 0 };
  running = true;
  try {
    const backoffCutoff = new Date(Date.now() - RETRY_BACKOFF_MS);
    const claimed = await db.transaction(async (tx) => {
      const rows = await tx
        .select()
        .from(onchainTransfersTable)
        .where(
          and(
            eq(onchainTransfersTable.status, "pending"),
            or(
              isNull(onchainTransfersTable.lastAttemptAt),
              lt(onchainTransfersTable.lastAttemptAt, backoffCutoff),
            ),
          ),
        )
        .orderBy(asc(onchainTransfersTable.createdAt))
        .limit(limit)
        .for("update", { skipLocked: true });
      if (rows.length === 0) return [] as OnchainTransfer[];
      const ids = rows.map((r) => r.id);
      await tx
        .update(onchainTransfersTable)
        .set({
          status: "processing",
          attempts: sql`${onchainTransfersTable.attempts} + 1`,
          lastAttemptAt: new Date(),
        })
        .where(inArray(onchainTransfersTable.id, ids));
      return rows;
    });

    let confirmed = 0;
    for (const row of claimed) {
      try {
        if (await processRow(row)) confirmed += 1;
      } catch (e) {
        const reason = e instanceof Error ? e.message : String(e);
        logger.warn({ rowId: row.id, kind: row.kind, reason }, "settlement attempt failed");
        await requeueOrFail(row, reason).catch(() => undefined);
      }
    }
    if (claimed.length > 0) {
      logger.info({ processed: claimed.length, confirmed }, "settlement reconciler pass");
    }
    return { processed: claimed.length, confirmed };
  } finally {
    running = false;
  }
}

/** Fire-and-forget nudge so a freshly enqueued transfer settles promptly. */
export function kickReconciler(): void {
  void runReconciler().catch((e) =>
    logger.warn({ err: e }, "settlement kick failed"),
  );
}

let loopStarted = false;

/**
 * Recover rows stranded in "processing" by a previous crash, then run the
 * reconciler on an interval. Single-instance assumption: any "processing" row
 * left at boot is from a dead worker, so it's safe to requeue.
 */
export async function startSettlementLoop(): Promise<void> {
  if (loopStarted) return;
  loopStarted = true;

  if (!onchainEnabled()) {
    logger.info("on-chain settlement disabled (no platform key / USDC contract); reconciler idle");
    return;
  }

  try {
    const recovered = await db
      .update(onchainTransfersTable)
      .set({ status: "pending" })
      .where(eq(onchainTransfersTable.status, "processing"))
      .returning({ id: onchainTransfersTable.id });
    if (recovered.length > 0) {
      logger.info({ recovered: recovered.length }, "requeued stranded on-chain transfers");
    }
  } catch (e) {
    logger.warn({ err: e }, "settlement startup recovery failed");
  }

  const timer = setInterval(() => {
    void runReconciler().catch((e) => logger.warn({ err: e }, "settlement reconciler tick failed"));
  }, RECONCILE_INTERVAL_MS);
  timer.unref();
  // Settle anything already queued without waiting for the first interval.
  kickReconciler();
}
