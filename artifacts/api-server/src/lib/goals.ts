import { eq, and, asc, desc, inArray } from "drizzle-orm";
import { AppError } from "./errors";
import {
  db,
  goalsTable,
  transactionsTable,
  postingsTable,
  ledgerAccountsTable,
} from "@workspace/db";
import { acct, transfer, accountBalance, goalBalances } from "./ledger";
import { notify } from "./notifications";
import { formatMoney } from "./money";
import { goalVaultEnabled, goalVaultContract, explorerUrl, networkName } from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { requireWalletForUser } from "./wallet";
import { recordSave } from "./streaks";

// Platform fee on every goal withdrawal, mirroring the on-chain GoalVault's
// feeBps (2%). Deposits are free. When the vault isn't configured/reachable,
// goals run ledger-only with no fee (graceful degradation, like circles).
const FEE_BPS = Number(process.env.GOAL_FEE_BPS) || 200;

function feeCentsOf(grossCents: number): number {
  return Math.floor((grossCents * FEE_BPS) / 10_000);
}

const ACTIVE = "active";
const DELETED = "deleted";

export type GoalHistoryItem = {
  id: string;
  type: string;
  amountCents: number;
  txHash: string | null;
  onchainStatus: string;
  createdAt: string;
};

/** On-chain transactions touching a goal's ledger account, newest first. */
async function goalHistory(goalId: string): Promise<GoalHistoryItem[]> {
  const rows = await db
    .select({
      id: transactionsTable.id,
      type: transactionsTable.type,
      amountCents: postingsTable.amountCents,
      txHash: transactionsTable.txHash,
      onchainStatus: transactionsTable.onchainStatus,
      createdAt: transactionsTable.createdAt,
    })
    .from(transactionsTable)
    .innerJoin(postingsTable, eq(postingsTable.transactionId, transactionsTable.id))
    .innerJoin(ledgerAccountsTable, eq(ledgerAccountsTable.id, postingsTable.accountId))
    .where(eq(ledgerAccountsTable.key, acct.goal(goalId)))
    .orderBy(desc(transactionsTable.createdAt))
    .limit(25);
  return rows.map((r) => ({
    id: r.id,
    type: r.type,
    amountCents: r.amountCents,
    txHash: r.txHash ?? null,
    onchainStatus: r.onchainStatus,
    createdAt: r.createdAt.toISOString(),
  }));
}

/** The on-chain surface for a goal: vault address, explorer, fee, network. */
function goalOnchainMeta() {
  const vault = goalVaultContract();
  const onchain = goalVaultEnabled();
  return {
    onchain,
    vaultAddress: vault,
    explorerUrl: vault ? explorerUrl() : null,
    network: networkName(),
    feeBps: onchain ? FEE_BPS : 0,
  };
}

export async function listGoals(userId: string) {
  const [goals, balances] = await Promise.all([
    db
      .select()
      .from(goalsTable)
      .where(and(eq(goalsTable.userId, userId), eq(goalsTable.status, ACTIVE)))
      .orderBy(asc(goalsTable.createdAt)),
    goalBalances(userId),
  ]);
  return goals.map((g) => ({ ...g, savedCents: balances[g.id] ?? 0 }));
}

export async function getGoal(userId: string, goalId: string) {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(
      and(
        eq(goalsTable.id, goalId),
        eq(goalsTable.userId, userId),
        eq(goalsTable.status, ACTIVE),
      ),
    );
  if (!goal) return null;
  const [balances, history] = await Promise.all([goalBalances(userId), goalHistory(goalId)]);
  return {
    ...goal,
    savedCents: balances[goalId] ?? 0,
    ...goalOnchainMeta(),
    history,
  };
}

export async function createGoal(
  userId: string,
  input: {
    name: string;
    emoji?: string;
    targetCents: number;
    deadline: Date;
    frequency?: string;
    autoSaveCents?: number | null;
    color?: string;
    imageUrl?: string | null;
  },
) {
  const [goal] = await db
    .insert(goalsTable)
    .values({
      userId,
      name: input.name,
      emoji: input.emoji || "🎯",
      targetCents: input.targetCents,
      deadline: input.deadline,
      frequency: input.frequency || "weekly",
      autoSaveCents: input.autoSaveCents ?? null,
      color: input.color || "jade",
      imageUrl: input.imageUrl ?? null,
    })
    .returning();
  return { ...goal, savedCents: 0, ...goalOnchainMeta(), history: [] as GoalHistoryItem[] };
}

/**
 * Allocate available wallet funds into a goal. The ledger moves wallet -> goal
 * synchronously (source of truth); when the vault is configured the same amount
 * is deposited on-chain via the settlement queue (deposits are free). Both
 * commit in one DB transaction so a crash can't leave a pending posting with
 * nothing to settle it.
 */
export async function allocateToGoal(userId: string, goalId: string, amountCents: number) {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(
      and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId), eq(goalsTable.status, ACTIVE)),
    );
  if (!goal) throw new AppError("Goal not found");
  await requireWalletForUser(userId);
  if ((await accountBalance(acct.wallet(userId))) < amountCents) {
    throw new AppError("Insufficient available balance");
  }

  const onchain = goalVaultEnabled();
  const vault = goalVaultContract();

  const txn = await db.transaction(async (tx) => {
    const t = await transfer({
      tx,
      type: "goal_allocate",
      description: `Allocation → ${goal.name}`,
      userId,
      fromKey: acct.wallet(userId),
      toKey: acct.goal(goalId),
      amountCents,
      requireSufficientFrom: true,
      onchain: onchain ? { onchainStatus: "pending" } : undefined,
    });
    if (onchain && vault) {
      await enqueueOnchainTransfer(
        {
          transactionId: t.id,
          kind: "goal_deposit",
          sourceUserId: userId,
          toAddress: vault,
          amountCents,
          memo: `goal:${goalId}`,
        },
        tx,
      );
    }
    return t;
  });

  if (onchain) kickReconciler();

  // Light the savings streak for this goal. Derived/non-financial and never
  // throws, so a streak hiccup can't affect the committed allocation.
  await recordSave(userId, txn.id);

  await notify(userId, {
    type: "goal",
    title: `Added to ${goal.name}`,
    body: `${formatMoney(amountCents)} moved into ${goal.name}.`,
    link: `/goals/${goalId}`,
  });
  return txn;
}

export type ReleaseResult = {
  grossCents: number;
  netCents: number;
  feeCents: number;
};

/**
 * Release `amountCents` (gross) from a goal back to the wallet. When the vault
 * is configured every withdrawal charges the 2% fee: the ledger books net to
 * the wallet and fee to platform fees, and one on-chain withdraw settles both
 * (the vault takes the fee on-chain). Without the vault, goals run ledger-only
 * with no fee.
 */
export async function releaseFromGoal(
  userId: string,
  goalId: string,
  amountCents: number,
): Promise<ReleaseResult> {
  const [goal] = await db
    .select()
    .from(goalsTable)
    .where(
      and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId), eq(goalsTable.status, ACTIVE)),
    );
  if (!goal) throw new AppError("Goal not found");
  return releaseFromGoalCore(userId, goalId, goal.name, amountCents, true);
}

/**
 * The release workhorse. Operates on a goal regardless of its row status (the
 * goal *account* still holds the balance), so `deleteGoal` can drain a goal it
 * has already flipped to "deleted". Validates the balance, books net + fee,
 * enqueues one on-chain withdraw, and optionally notifies the user.
 */
async function releaseFromGoalCore(
  userId: string,
  goalId: string,
  goalName: string,
  amountCents: number,
  notifyUser: boolean,
): Promise<ReleaseResult> {
  const goal = { name: goalName };
  const balances = await goalBalances(userId);
  if ((balances[goalId] ?? 0) < amountCents) throw new AppError("Insufficient goal balance");

  const onchain = goalVaultEnabled();
  const vault = goalVaultContract();
  const feeCents = onchain ? feeCentsOf(amountCents) : 0;
  const netCents = amountCents - feeCents;

  await db.transaction(async (tx) => {
    const netTxn = await transfer({
      tx,
      type: "goal_release",
      description: `Released from ${goal.name}`,
      userId,
      fromKey: acct.goal(goalId),
      toKey: acct.wallet(userId),
      amountCents: netCents,
      requireSufficientFrom: true,
      onchain: onchain ? { onchainStatus: "pending" } : undefined,
    });

    let feeTxnId: string | null = null;
    if (feeCents > 0) {
      const feeTxn = await transfer({
        tx,
        type: "fee",
        description: `Withdrawal fee · ${goal.name}`,
        userId,
        fromKey: acct.goal(goalId),
        toKey: acct.fees,
        amountCents: feeCents,
        requireSufficientFrom: true,
        onchain: { onchainStatus: "pending" },
      });
      feeTxnId = feeTxn.id;
    }

    if (onchain && vault) {
      await enqueueOnchainTransfer(
        {
          transactionId: netTxn.id,
          kind: "goal_withdraw",
          sourceUserId: userId,
          toAddress: vault,
          amountCents,
          memo: feeTxnId ? `goal:${goalId}:${feeTxnId}` : `goal:${goalId}`,
        },
        tx,
      );
    }
  });

  if (onchain) kickReconciler();

  if (notifyUser) {
    await notify(userId, {
      type: "goal",
      title: `Withdrawn from ${goal.name}`,
      body:
        feeCents > 0
          ? `${formatMoney(netCents)} returned to your available balance (after a ${formatMoney(feeCents)} fee).`
          : `${formatMoney(netCents)} returned to your available balance.`,
      link: `/goals/${goalId}`,
    });
  }

  return { grossCents: amountCents, netCents, feeCents };
}

export type DeleteGoalResult = {
  ok: true;
  withdrawnGrossCents: number;
  withdrawnNetCents: number;
  feeCents: number;
};

/**
 * Delete a goal, automatically withdrawing its entire balance back to the
 * wallet first (net of the 2% withdrawal fee when the vault is configured).
 * Soft-delete (status -> "deleted"): the goal's ledger account is FK'd to the
 * goals row with ON DELETE CASCADE, so a hard delete would wipe its postings
 * and corrupt the double-entry ledger. Deleted goals are filtered from all
 * listings.
 */
export async function deleteGoal(userId: string, goalId: string): Promise<DeleteGoalResult> {
  // Atomically claim the goal by flipping active -> deleted in a single
  // compare-and-set. allocateToGoal and releaseFromGoal both require an *active*
  // goal, so once this returns a row no concurrent op can move money into or out
  // of it — we then drain the remaining balance safely. (Flipping AFTER the
  // drain would leave a window where a concurrent allocate re-funds a goal we're
  // about to close, stranding those funds in a deleted goal.)
  const [goal] = await db
    .update(goalsTable)
    .set({ status: DELETED })
    .where(
      and(eq(goalsTable.id, goalId), eq(goalsTable.userId, userId), eq(goalsTable.status, ACTIVE)),
    )
    .returning();
  if (!goal) throw new AppError("Goal not found");

  const balances = await goalBalances(userId);
  const balanceCents = balances[goalId] ?? 0;

  let released: ReleaseResult = { grossCents: 0, netCents: 0, feeCents: 0 };
  if (balanceCents > 0) {
    released = await releaseFromGoalCore(userId, goalId, goal.name, balanceCents, false);
  }

  await notify(userId, {
    type: "goal",
    title: `Deleted ${goal.name}`,
    body:
      balanceCents > 0
        ? `Goal closed. ${formatMoney(released.netCents)} returned to your available balance${
            released.feeCents > 0 ? ` (after a ${formatMoney(released.feeCents)} fee)` : ""
          }.`
        : `Goal closed.`,
    link: `/goals`,
  });

  return {
    ok: true,
    withdrawnGrossCents: released.grossCents,
    withdrawnNetCents: released.netCents,
    feeCents: released.feeCents,
  };
}
