import { and, eq, inArray, like, or, sql, type SQL } from "drizzle-orm";
import { db, goalsTable, onchainTransfersTable } from "@workspace/db";
import { AppError } from "./errors";
import { usdcBalanceStrict, goalVaultBalanceStrict, onchainEnabled, goalVaultEnabled } from "./chain";
import { getWalletForUser } from "./wallet";
import { accountBalance, acct, userBalances } from "./ledger";

/**
 * On-chain balances are the single source of truth for what a user can spend
 * and for what we display — WHEN on-chain settlement is configured. The
 * double-entry ledger still records every movement, but a real USDC balance on
 * Monad — not the ledger — decides whether a withdrawal, goal release, or circle
 * contribution is allowed.
 *
 * A movement debits the ledger immediately, but its matching USDC transfer
 * settles out of band via the reconciler. Between those two moments the ledger
 * already reflects the spend while the chain does not, so "spendable" is the
 * confirmed on-chain balance MINUS every not-yet-settled outbound transfer. This
 * prevents spending the same funds twice while a transfer is in flight.
 *
 * When on-chain settlement is NOT configured (offline dev/test — no platform key
 * / USDC / vault), there is no chain to read and money moves ledger-only. Each
 * gate below falls back to the ledger balance so those environments stay fully
 * functional; production, which has every secret, is always strict on-chain.
 */

const PENDING_STATES = ["pending", "processing"] as const;

// Outbound kinds that leave a user's wallet: the ledger has already debited the
// wallet, but the chain still shows the funds until the transfer settles. We
// subtract these from the confirmed on-chain balance so in-flight spends can't
// be double-spent. `goal_withdraw` is excluded — it is an INFLOW to the wallet.
// `faucet`/`payout` have a null source (platform), so they never match here.
const WALLET_OUT_KINDS = ["withdrawal", "escrow_contribute", "goal_deposit"] as const;

const BALANCE_UNAVAILABLE_MSG =
  "We couldn't verify your on-chain balance right now. Please try again in a moment.";

/** Matches `goal:<goalId>` and `goal:<goalId>:<feeTxnId>` settlement memos. */
function goalMemoFilter(goalId: string) {
  return or(
    eq(onchainTransfersTable.memo, `goal:${goalId}`),
    like(onchainTransfersTable.memo, `goal:${goalId}:%`),
  );
}

async function sumPending(where: SQL | undefined): Promise<number> {
  const [r] = await db
    .select({ s: sql<number>`coalesce(sum(${onchainTransfersTable.amountCents}), 0)::int` })
    .from(onchainTransfersTable)
    .where(where);
  return Number(r?.s ?? 0);
}

/** Total not-yet-settled USDC leaving a user's wallet (in cents). */
export async function pendingWalletOutCents(userId: string): Promise<number> {
  return sumPending(
    and(
      eq(onchainTransfersTable.sourceUserId, userId),
      inArray(onchainTransfersTable.status, [...PENDING_STATES]),
      inArray(onchainTransfersTable.kind, [...WALLET_OUT_KINDS]),
    ),
  );
}

/** Total not-yet-settled withdrawals leaving a specific goal vault balance. */
export async function pendingGoalWithdrawCents(userId: string, goalId: string): Promise<number> {
  return sumPending(
    and(
      eq(onchainTransfersTable.sourceUserId, userId),
      inArray(onchainTransfersTable.status, [...PENDING_STATES]),
      eq(onchainTransfersTable.kind, "goal_withdraw"),
      goalMemoFilter(goalId),
    ),
  );
}

/**
 * Whether any deposit or withdrawal for a goal is still settling. `deleteGoal`
 * refuses to close a goal in this state: a deposit that confirms after the drain
 * would strand funds in a deleted goal's vault balance with no way to recover.
 */
export async function pendingGoalTransfersExist(userId: string, goalId: string): Promise<boolean> {
  const [r] = await db
    .select({ c: sql<number>`count(*)::int` })
    .from(onchainTransfersTable)
    .where(
      and(
        eq(onchainTransfersTable.sourceUserId, userId),
        inArray(onchainTransfersTable.status, [...PENDING_STATES]),
        inArray(onchainTransfersTable.kind, ["goal_deposit", "goal_withdraw"]),
        goalMemoFilter(goalId),
      ),
    );
  return Number(r?.c ?? 0) > 0;
}

/**
 * Spendable wallet balance in cents for GATING money movement: confirmed
 * on-chain balance minus in-flight outbound transfers. THROWS a user-safe
 * AppError when the balance can't be read, so a spend fails closed rather than
 * proceeding against an unknown balance.
 */
export async function walletSpendableCents(userId: string, address: string): Promise<number> {
  // Offline/ledger-only: no chain to read; the ledger already reflects in-flight
  // spends (it debits synchronously), so its wallet balance IS the spendable one.
  if (!onchainEnabled()) return accountBalance(acct.wallet(userId));
  let confirmed: number;
  try {
    confirmed = await usdcBalanceStrict(address);
  } catch {
    throw new AppError(BALANCE_UNAVAILABLE_MSG);
  }
  const pendingOut = await pendingWalletOutCents(userId);
  return confirmed - pendingOut;
}

/**
 * Spendable goal-vault balance in cents for GATING releases/deletes: confirmed
 * on-chain goal balance minus in-flight goal withdrawals. THROWS a user-safe
 * AppError when unreadable (fail closed).
 */
export async function goalSpendableCents(
  ownerAddress: string,
  userId: string,
  goalId: string,
): Promise<number> {
  // Offline/ledger-only: the goal's ledger account balance is authoritative.
  if (!goalVaultEnabled()) return accountBalance(acct.goal(goalId));
  let confirmed: number;
  try {
    confirmed = await goalVaultBalanceStrict(ownerAddress, goalId);
  } catch {
    throw new AppError(BALANCE_UNAVAILABLE_MSG);
  }
  const pendingWithdraw = await pendingGoalWithdrawCents(userId, goalId);
  return confirmed - pendingWithdraw;
}

export type GoalBalanceView = { cents: number; balanceUnavailable: boolean };

/**
 * On-chain balance per goal for DISPLAY. Reads each goal's vault balance in
 * parallel; a goal whose read fails reports `balanceUnavailable` (so the UI can
 * show "unavailable" instead of a misleading 0). With no wallet there can be no
 * on-chain balance, so every goal is a confirmed 0.
 */
export async function goalBalancesView(
  ownerAddress: string | null,
  goalIds: string[],
): Promise<Record<string, GoalBalanceView>> {
  const out: Record<string, GoalBalanceView> = {};
  if (goalIds.length === 0) return out;
  // Offline/ledger-only: display each goal's ledger account balance.
  if (!goalVaultEnabled()) {
    await Promise.all(
      goalIds.map(async (id) => {
        out[id] = { cents: await accountBalance(acct.goal(id)), balanceUnavailable: false };
      }),
    );
    return out;
  }
  if (!ownerAddress) {
    for (const id of goalIds) out[id] = { cents: 0, balanceUnavailable: false };
    return out;
  }
  await Promise.all(
    goalIds.map(async (id) => {
      try {
        const cents = await goalVaultBalanceStrict(ownerAddress, id);
        out[id] = { cents, balanceUnavailable: false };
      } catch {
        out[id] = { cents: 0, balanceUnavailable: true };
      }
    }),
  );
  return out;
}

export type UserBalanceSummary = {
  /** Spendable now: confirmed on-chain wallet balance minus in-flight outflows. */
  availableCents: number;
  /** In-flight outbound wallet transfers not yet settled on-chain. */
  pendingCents: number;
  /** Confirmed on-chain balance held across the user's active goal vaults. */
  allocatedCents: number;
  /** Everything the user holds on-chain: confirmed wallet + goal allocations. */
  totalCents: number;
  /** True when any on-chain read failed, so figures may be understated. */
  balanceUnavailable: boolean;
};

async function activeGoalIds(userId: string): Promise<string[]> {
  const rows = await db
    .select({ id: goalsTable.id })
    .from(goalsTable)
    .where(and(eq(goalsTable.userId, userId), eq(goalsTable.status, "active")));
  return rows.map((r) => r.id);
}

/**
 * The user's balance summary for DISPLAY (wallet + dashboard), sourced entirely
 * from on-chain reads. Never throws: an unreadable balance surfaces as
 * `balanceUnavailable` with conservative 0s rather than a misleading number.
 */
export async function userOnchainBalanceSummary(userId: string): Promise<UserBalanceSummary> {
  // Offline/ledger-only: display straight from the ledger (nothing settles
  // on-chain, so there are no in-flight outflows to net out).
  if (!onchainEnabled()) {
    const b = await userBalances(userId);
    return {
      availableCents: b.availableCents,
      pendingCents: 0,
      allocatedCents: b.allocatedCents,
      totalCents: b.totalCents,
      balanceUnavailable: false,
    };
  }
  const wallet = await getWalletForUser(userId);
  if (!wallet) {
    return {
      availableCents: 0,
      pendingCents: 0,
      allocatedCents: 0,
      totalCents: 0,
      balanceUnavailable: false,
    };
  }

  const goalIds = await activeGoalIds(userId);
  const pendingOut = await pendingWalletOutCents(userId);

  let confirmedWallet = 0;
  let walletUnavailable = false;
  try {
    confirmedWallet = await usdcBalanceStrict(wallet.address);
  } catch {
    walletUnavailable = true;
  }

  const goalViews = await goalBalancesView(wallet.address, goalIds);
  let allocated = 0;
  let goalUnavailable = false;
  for (const id of goalIds) {
    const v = goalViews[id];
    if (!v) continue;
    allocated += v.cents;
    if (v.balanceUnavailable) goalUnavailable = true;
  }

  return {
    availableCents: Math.max(0, confirmedWallet - pendingOut),
    pendingCents: pendingOut,
    allocatedCents: allocated,
    totalCents: confirmedWallet + allocated,
    balanceUnavailable: walletUnavailable || goalUnavailable,
  };
}
