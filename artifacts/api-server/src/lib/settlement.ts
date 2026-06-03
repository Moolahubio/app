import { eq, and, or, inArray, isNull, lt, asc, sql } from "drizzle-orm";
import {
  db,
  onchainTransfersTable,
  transactionsTable,
  contributionsTable,
  type OnchainTransfer,
} from "@workspace/db";
import { onchainEnabled, sendUsdc } from "./chain";
import { getSigningSecret } from "./wallet";
import { logger } from "./logger";

/**
 * On-chain settlement reconciler.
 *
 * The double-entry ledger is the source of truth and commits synchronously. The
 * matching USDC transfer on Base is enqueued in `onchain_transfers` and settled
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

export type QueueParams = {
  transactionId: string;
  kind: "faucet" | "withdrawal" | "contribution" | "payout";
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

async function requeue(rowId: string, reason: string): Promise<void> {
  await db
    .update(onchainTransfersTable)
    .set({ status: "pending", lastError: reason })
    .where(eq(onchainTransfersTable.id, rowId));
}

/**
 * Dead-letter a transfer: mark the queue row 'failed' (so the claim query never
 * picks it up again) and flag the linked ledger transaction 'failed' so the
 * activity feed surfaces it for an operator. The ledger itself is unchanged —
 * the money already moved in the double-entry ledger; only the on-chain mirror
 * is broken.
 */
async function markFailed(row: OnchainTransfer, reason: string): Promise<void> {
  await db.transaction(async (tx) => {
    await tx
      .update(onchainTransfersTable)
      .set({ status: "failed", lastError: reason })
      .where(eq(onchainTransfersTable.id, row.id));
    await tx
      .update(transactionsTable)
      .set({ onchainStatus: "failed" })
      .where(eq(transactionsTable.id, row.transactionId));
  });
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
    return false;
  }

  const fromPrivateKey = await resolveSourceKey(row);
  if (!fromPrivateKey) {
    // No usable signing key: this can't be settled on-chain. Don't block the
    // queue forever — mark it failed (the ledger already reflects the money).
    await markFailed(row, "source signing key unavailable");
    return false;
  }

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
