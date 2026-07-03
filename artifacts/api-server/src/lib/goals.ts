import { eq, and, asc, desc, inArray } from "drizzle-orm";
import { AppError } from "./errors";
import {
  db,
  goalsTable,
  transactionsTable,
  postingsTable,
  ledgerAccountsTable,
} from "@workspace/db";
import { acct, transfer, accountBalance } from "./ledger";
import { notify } from "./notifications";
import { formatMoney } from "./money";
import {
  goalVaultEnabled,
  goalVaultContract,
  goalVaultBalanceStrict,
  explorerUrl,
  networkName,
} from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { getWalletForUser, requireWalletForUser } from "./wallet";
import { recordSave } from "./streaks";
import {
  walletSpendableCents,
  goalSpendableCents,
  goalBalancesView,
  pendingGoalTransfersExist,
} from "./onchainBalances";

// Platform fee on every goal withdrawal, mirroring the on-chain GoalVault's
// feeBps (2%). Deposits are free; every withdrawal (including the auto-withdraw
// on delete) charges the fee. On-chain settlement is required for all goal
// movement, so the fee always applies.
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
  const wallet = await getWalletForUser(userId);
  const goals = await db
    .select()
    .from(goalsTable)
    .where(and(eq(goalsTable.userId, userId), eq(goalsTable.status, ACTIVE)))
    .orderBy(asc(goalsTable.createdAt));
  // On-chain vault balance is the displayed "saved" amount — the ledger is only
  // the movement journal, the chain is the source of truth.
  const balances = await goalBalancesView(
    wallet?.address ?? null,
    goals.map((g) => g.id),
  );
  return goals.map((g) => ({
    ...g,
    savedCents: balances[g.id]?.cents ?? 0,
    balanceUnavailable: balances[g.id]?.balanceUnavailable ?? false,
  }));
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
  const wallet = await getWalletForUser(userId);
  const [balances, history] = await Promise.all([
    goalBalancesView(wallet?.address ?? null, [goalId]),
    goalHistory(goalId),
  ]);
  return {
    ...goal,
    savedCents: balances[goalId]?.cents ?? 0,
    balanceUnavailable: balances[goalId]?.balanceUnavailable ?? false,
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
  return {
    ...goal,
    savedCents: 0,
    balanceUnavailable: false,
    ...goalOnchainMeta(),
    history: [] as GoalHistoryItem[],
  };
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
  const settle = goalVaultEnabled();
  const vault = goalVaultContract();
  const wallet = await requireWalletForUser(userId);
  // Gate on the spendable wallet balance: real on-chain (confirmed minus
  // in-flight outflows) when the vault is configured, else the ledger balance.
  if ((await walletSpendableCents(userId, wallet.address)) < amountCents) {
    throw new AppError("Insufficient available balance");
  }

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
      onchain: { onchainStatus: settle ? "pending" : "none" },
    });
    if (settle && vault) {
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

  if (settle) kickReconciler();

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
  const settle = goalVaultEnabled();
  const vault = goalVaultContract();
  const wallet = await requireWalletForUser(userId);
  // Gate on the spendable savings balance: real on-chain vault balance (confirmed
  // minus in-flight withdrawals) when configured, else the goal's ledger balance.
  if ((await goalSpendableCents(wallet.address, userId, goalId)) < amountCents) {
    throw new AppError("Insufficient savings balance");
  }

  // The 2% withdrawal fee is charged by the on-chain vault; offline (ledger-only)
  // there is no vault to take it, so releases run fee-free.
  const feeCents = settle ? feeCentsOf(amountCents) : 0;
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
      onchain: { onchainStatus: settle ? "pending" : "none" },
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
        onchain: { onchainStatus: settle ? "pending" : "none" },
      });
      feeTxnId = feeTxn.id;
    }

    if (settle && vault) {
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

  if (settle) kickReconciler();

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

  try {
    // Refuse to close while a deposit/withdraw for this goal is still settling: a
    // deposit that confirms after we drain would strand funds in a closed goal's
    // vault balance with no way to recover them. (Offline there are no pending
    // transfers, so this is a no-op.)
    if (await pendingGoalTransfersExist(userId, goalId)) {
      throw new AppError(
        "This goal has a transfer still settling. Please try again once it completes.",
      );
    }

    // Drain the goal's balance back to the wallet: the REAL on-chain vault
    // balance when configured, else the goal's ledger account balance offline.
    const wallet = await getWalletForUser(userId);
    let balanceCents = 0;
    if (goalVaultEnabled()) {
      if (wallet) {
        try {
          balanceCents = await goalVaultBalanceStrict(wallet.address, goalId);
        } catch {
          throw new AppError(
            "We couldn't verify your savings balance right now. Please try again in a moment.",
          );
        }
      }
    } else {
      balanceCents = await accountBalance(acct.goal(goalId));
    }

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
  } catch (e) {
    // Roll the soft-delete back so a failed close doesn't hide a goal that still
    // holds an on-chain balance we never drained.
    await db
      .update(goalsTable)
      .set({ status: ACTIVE })
      .where(
        and(
          eq(goalsTable.id, goalId),
          eq(goalsTable.userId, userId),
          eq(goalsTable.status, DELETED),
        ),
      )
      .catch(() => undefined);
    throw e;
  }
}
