import { eq, and, inArray, desc, sql } from "drizzle-orm";
import {
  db,
  ledgerAccountsTable,
  transactionsTable,
  postingsTable,
  goalsTable,
} from "@workspace/db";

/**
 * Double-entry ledger. Every money movement is a transaction with postings
 * that sum to zero. Balances are always derived, never stored.
 *
 * Account keys:
 *   wallet:<userId>  available, unallocated balance in the user's wallet
 *   goal:<goalId>    allocated to a goal (still in the wallet, earmarked)
 *   pool:<circleId>  a Susu circle's escrowed pot
 *   external         the outside world: on-chain USDC in/out
 *   yield            yield source
 *   fees             platform fees
 */
export const acct = {
  wallet: (userId: string) => `wallet:${userId}`,
  goal: (goalId: string) => `goal:${goalId}`,
  pool: (circleId: string) => `pool:${circleId}`,
  external: "external",
  yield: "yield",
  fees: "fees",
};

type AccountSeed = {
  key: string;
  kind: string;
  label: string;
  userId?: string;
  goalId?: string;
  circleId?: string;
};

function describe(key: string): AccountSeed {
  if (key.startsWith("wallet:"))
    return { key, kind: "available", label: "Wallet", userId: key.slice(7) };
  if (key.startsWith("goal:"))
    return { key, kind: "goal", label: "Goal allocation", goalId: key.slice(5) };
  if (key.startsWith("pool:"))
    return { key, kind: "pool", label: "Circle pot", circleId: key.slice(5) };
  if (key === "external") return { key, kind: "external", label: "External (on-chain)" };
  if (key === "yield") return { key, kind: "yield", label: "Yield" };
  if (key === "fees") return { key, kind: "fees", label: "Platform fees" };
  throw new Error(`Unknown ledger account key: ${key}`);
}

type Executor = Parameters<Parameters<typeof db.transaction>[0]>[0];
type DbLike = typeof db | Executor;

export class InsufficientFundsError extends Error {
  constructor(message = "Insufficient balance") {
    super(message);
    this.name = "InsufficientFundsError";
  }
}

async function ensureAccount(key: string, exec: DbLike = db) {
  const seed = describe(key);
  await exec.insert(ledgerAccountsTable).values(seed).onConflictDoNothing({
    target: ledgerAccountsTable.key,
  });
  const [existing] = await exec
    .select()
    .from(ledgerAccountsTable)
    .where(eq(ledgerAccountsTable.key, key));
  if (!existing) throw new Error(`Could not resolve ledger account: ${key}`);
  return existing;
}

export type OnchainMeta = {
  txHash?: string | null;
  onchainStatus?: string;
  onchainXdr?: string | null;
};

/**
 * Move `amountCents` from one account to another atomically.
 *
 * Runs inside a DB transaction and takes a per-account Postgres advisory lock
 * (transaction-scoped, auto-released at commit) so concurrent transfers
 * touching the same account are serialized. When `requireSufficientFrom` is
 * set, the source balance is checked *inside* the locked transaction, which
 * makes the check-then-move sequence race-safe and prevents overdrafts /
 * double-spends. Locks are acquired in a stable key order to avoid deadlocks.
 */
type TransferParams = {
  type: string;
  description: string;
  userId?: string | null;
  fromKey: string;
  toKey: string;
  amountCents: number;
  onchain?: OnchainMeta;
  requireSufficientFrom?: boolean;
  /** Circle context, for rotation contributions/payouts/fees. */
  circleId?: string | null;
  round?: number | null;
};

async function runTransfer(tx: Executor, params: TransferParams) {
  const from = await ensureAccount(params.fromKey, tx);
  const to = await ensureAccount(params.toKey, tx);

  for (const key of [params.fromKey, params.toKey].sort()) {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${key}))`);
  }

  if (params.requireSufficientFrom) {
    const bal = await accountBalance(params.fromKey, tx);
    if (bal < params.amountCents) throw new InsufficientFundsError();
  }

  const [txn] = await tx
    .insert(transactionsTable)
    .values({
      type: params.type,
      description: params.description,
      userId: params.userId ?? null,
      circleId: params.circleId ?? null,
      round: params.round ?? null,
      txHash: params.onchain?.txHash ?? null,
      onchainStatus: params.onchain?.onchainStatus ?? "none",
      onchainXdr: params.onchain?.onchainXdr ?? null,
    })
    .returning();
  await tx.insert(postingsTable).values([
    { transactionId: txn.id, accountId: from.id, amountCents: -params.amountCents },
    { transactionId: txn.id, accountId: to.id, amountCents: params.amountCents },
  ]);
  return txn;
}

/**
 * Move `amountCents` from one account to another atomically.
 *
 * Runs inside a DB transaction and takes a per-account Postgres advisory lock
 * (transaction-scoped, auto-released at commit) so concurrent transfers
 * touching the same account are serialized. When `requireSufficientFrom` is
 * set, the source balance is checked *inside* the locked transaction, which
 * makes the check-then-move sequence race-safe and prevents overdrafts /
 * double-spends. Locks are acquired in a stable key order to avoid deadlocks.
 *
 * Pass an existing `tx` to compose this posting with other writes (e.g. a
 * uniqueness reservation) in the *same* transaction, so they commit or roll
 * back together.
 */
export async function transfer(params: TransferParams & { tx?: Executor }) {
  if (params.amountCents <= 0) throw new Error("amount must be positive");
  if (params.tx) return runTransfer(params.tx, params);
  return db.transaction((tx) => runTransfer(tx, params));
}

export async function accountBalance(key: string, exec: DbLike = db): Promise<number> {
  const [r] = await exec
    .select({ s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)` })
    .from(postingsTable)
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .where(eq(ledgerAccountsTable.key, key));
  return Number(r?.s ?? 0);
}

/** A user's wallet view: available, allocated-to-goals, and the total. */
export async function userBalances(userId: string) {
  const goals = await db
    .select({ id: goalsTable.id })
    .from(goalsTable)
    .where(eq(goalsTable.userId, userId));
  const goalIds = goals.map((g) => g.id);

  const availableCents = await accountBalance(acct.wallet(userId));

  let allocatedCents = 0;
  if (goalIds.length) {
    const [r] = await db
      .select({ s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)` })
      .from(postingsTable)
      .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
      .where(
        and(inArray(ledgerAccountsTable.goalId, goalIds), eq(ledgerAccountsTable.kind, "goal")),
      );
    allocatedCents = Number(r?.s ?? 0);
  }

  const [yr] = await db
    .select({ s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)` })
    .from(postingsTable)
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .innerJoin(transactionsTable, eq(postingsTable.transactionId, transactionsTable.id))
    .where(and(eq(ledgerAccountsTable.key, acct.wallet(userId)), eq(transactionsTable.type, "yield")));
  const yieldEarnedCents = Number(yr?.s ?? 0);

  return {
    availableCents,
    allocatedCents,
    totalCents: availableCents + allocatedCents,
    yieldEarnedCents,
  };
}

export type ActivityRow = {
  id: string;
  type: string;
  description: string;
  amountCents: number;
  txHash: string | null;
  onchainStatus: string;
  createdAt: Date;
};

/** A user's activity feed: transactions touching their available wallet. */
export async function userActivity(userId: string, limit = 50): Promise<ActivityRow[]> {
  const rows = await db
    .select({
      id: transactionsTable.id,
      type: transactionsTable.type,
      description: transactionsTable.description,
      amountCents: postingsTable.amountCents,
      txHash: transactionsTable.txHash,
      onchainStatus: transactionsTable.onchainStatus,
      createdAt: transactionsTable.createdAt,
    })
    .from(postingsTable)
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .innerJoin(transactionsTable, eq(postingsTable.transactionId, transactionsTable.id))
    .where(eq(ledgerAccountsTable.key, acct.wallet(userId)))
    .orderBy(desc(transactionsTable.createdAt))
    .limit(limit);
  return rows;
}

export async function goalBalances(userId: string): Promise<Record<string, number>> {
  const goals = await db
    .select({ id: goalsTable.id })
    .from(goalsTable)
    .where(eq(goalsTable.userId, userId));
  const goalIds = goals.map((g) => g.id);
  const out: Record<string, number> = {};
  if (!goalIds.length) return out;
  const rows = await db
    .select({
      goalId: ledgerAccountsTable.goalId,
      s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)`,
    })
    .from(ledgerAccountsTable)
    .leftJoin(postingsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .where(and(inArray(ledgerAccountsTable.goalId, goalIds), eq(ledgerAccountsTable.kind, "goal")))
    .groupBy(ledgerAccountsTable.goalId);
  for (const r of rows) {
    if (r.goalId) out[r.goalId] = Number(r.s ?? 0);
  }
  return out;
}
