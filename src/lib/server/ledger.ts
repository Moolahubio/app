import "server-only";
import { db } from "@/lib/db";
import type { Prisma } from "@prisma/client";

/**
 * Double-entry ledger. Every money movement is a Transaction with postings
 * that sum to zero. Balances are always derived, never stored.
 *
 * Account keys:
 *   wallet:<userId>  (available, unallocated balance in the user's wallet)
 *   goal:<goalId>    (allocated to a goal — still in the wallet, earmarked)
 *   pool:<circleId>  (a Susu circle's escrowed pot)
 *   external         (the outside world: fiat rails)
 *   yield            (yield source: Blend lending)
 *   fees             (platform fees)
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
  if (key === "external") return { key, kind: "external", label: "Fiat rail" };
  if (key === "yield") return { key, kind: "yield", label: "Yield (Blend)" };
  if (key === "fees") return { key, kind: "fees", label: "Platform fees" };
  throw new Error(`Unknown ledger account key: ${key}`);
}

async function ensureAccount(key: string) {
  const seed = describe(key);
  try {
    return await db.ledgerAccount.upsert({ where: { key }, update: {}, create: seed });
  } catch {
    // Concurrent transfers may race to create the same shared account
    // (e.g. "external"). The loser of the race just reads the winner's row.
    const existing = await db.ledgerAccount.findUnique({ where: { key } });
    if (existing) return existing;
    throw new Error(`Could not resolve ledger account: ${key}`);
  }
}

export type OnchainMeta = {
  txHash?: string | null;
  onchainStatus?: string;
  onchainXdr?: string | null;
};

/** Move `amountCents` from one account to another atomically. */
export async function transfer(params: {
  type: string;
  description: string;
  userId?: string | null;
  fromKey: string;
  toKey: string;
  amountCents: number;
  onchain?: OnchainMeta;
}) {
  if (params.amountCents <= 0) throw new Error("amount must be positive");
  // Resolve accounts first (idempotent), then write the balanced transaction as
  // a single atomic create with its two postings.
  const from = await ensureAccount(params.fromKey);
  const to = await ensureAccount(params.toKey);
  return db.transaction.create({
    data: {
      type: params.type,
      description: params.description,
      userId: params.userId ?? null,
      txHash: params.onchain?.txHash ?? null,
      onchainStatus: params.onchain?.onchainStatus ?? "none",
      onchainXdr: params.onchain?.onchainXdr ?? null,
      postings: {
        create: [
          { accountId: from.id, amountCents: -params.amountCents },
          { accountId: to.id, amountCents: params.amountCents },
        ],
      },
    },
  });
}

async function sumWhere(where: Prisma.PostingWhereInput): Promise<number> {
  const r = await db.posting.aggregate({ _sum: { amountCents: true }, where });
  return r._sum.amountCents ?? 0;
}

export async function accountBalance(key: string): Promise<number> {
  return sumWhere({ account: { key } });
}

/** A user's wallet view: available, allocated-to-goals, and the total. */
export async function userBalances(userId: string) {
  const goalIds = (
    await db.goal.findMany({ where: { userId }, select: { id: true } })
  ).map((g) => g.id);

  const [availableCents, allocatedCents, yieldEarnedCents] = await Promise.all([
    sumWhere({ account: { key: acct.wallet(userId) } }),
    goalIds.length
      ? sumWhere({ account: { goalId: { in: goalIds }, kind: "goal" } })
      : Promise.resolve(0),
    // yield credited into this user's wallet (positive postings on wallet from yield txns)
    sumWhere({
      account: { key: acct.wallet(userId) },
      transaction: { type: "yield" },
    }),
  ]);
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
  amountCents: number; // signed effect on the user's available balance
  txHash: string | null;
  onchainStatus: string;
  createdAt: Date;
};

/**
 * A user's activity feed: transactions touching their available wallet,
 * with the signed effect on that balance.
 */
export async function userActivity(userId: string, limit = 50): Promise<ActivityRow[]> {
  const postings = await db.posting.findMany({
    where: { account: { key: acct.wallet(userId) } },
    include: { transaction: true },
    orderBy: { transaction: { createdAt: "desc" } },
    take: limit,
  });
  return postings.map((p) => ({
    id: p.transaction.id,
    type: p.transaction.type,
    description: p.transaction.description,
    amountCents: p.amountCents,
    txHash: p.transaction.txHash,
    onchainStatus: p.transaction.onchainStatus,
    createdAt: p.transaction.createdAt,
  }));
}

export async function goalBalances(userId: string): Promise<Record<string, number>> {
  const goalIds = (
    await db.goal.findMany({ where: { userId }, select: { id: true } })
  ).map((g) => g.id);
  const out: Record<string, number> = {};
  if (!goalIds.length) return out;
  const accounts = await db.ledgerAccount.findMany({
    where: { goalId: { in: goalIds }, kind: "goal" },
    include: { postings: { select: { amountCents: true } } },
  });
  for (const a of accounts) {
    if (a.goalId) out[a.goalId] = a.postings.reduce((s, p) => s + p.amountCents, 0);
  }
  return out;
}
