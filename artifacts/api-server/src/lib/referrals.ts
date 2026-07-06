import { randomBytes } from "node:crypto";
import { and, desc, eq, gt, inArray, isNull, ne, or, sql } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import {
  db,
  referralCodesTable,
  referralsTable,
  referralEarningsTable,
  referralWithdrawalsTable,
  transactionsTable,
  postingsTable,
  ledgerAccountsTable,
  streaksTable,
  usersTable,
} from "@workspace/db";
import { acct, accountBalance, transfer } from "./ledger";
import { onchainEnabled } from "./chain";
import { enqueueOnchainTransfer, kickReconciler } from "./settlement";
import { requireWalletForUser, getWalletForUser } from "./wallet";
import { getAllowedOrigins } from "./origins";
import { AppError } from "./errors";
import { notify } from "./notifications";
import { formatMoney } from "./money";
import { logger } from "./logger";

type Executor = Parameters<Parameters<typeof db.transaction>[0]>[0];
type DbLike = typeof db | Executor;

/**
 * Refer & Earn business logic.
 *
 * Design (see docs/referral-program.md):
 *  - Earnings accrue via an idempotent SWEEP over confirmed platform-fee
 *    transactions (never inline hooks), so no critical money path is touched and
 *    each fee produces at most one earning (unique on sourceTransactionId).
 *  - Commission is booked from whichever account the fee landed in — `fees` for
 *    goal-withdrawal fees, `external` for circle-payout fees — into the
 *    referrer's `referral:<userId>` ledger account.
 *  - "Pending" earnings are derived read-only from unconfirmed fees; only
 *    settled fees produce a stored, withdrawable earning.
 */

// The single per-user account streak marker (mirrors streaks.ts ACCOUNT).
const ACCOUNT_STREAK = "account";
const ACTIVE_STREAK_STATUSES = ["active", "frozen"] as const;

// Earning rate tiers, keyed by the referrer's number of ACTIVE referred savers.
// "100+" is read as "more than 100" so the explicit "51–100 → 17.5%" band holds.
export type ReferralTier = {
  index: number;
  key: "starter" | "builder" | "connector" | "leader" | "champion";
  min: number; // inclusive lower bound of active savers for this tier
  rateBps: number;
};

export const REFERRAL_TIERS: ReferralTier[] = [
  { index: 0, key: "starter", min: 0, rateBps: 1000 },
  { index: 1, key: "builder", min: 6, rateBps: 1250 },
  { index: 2, key: "connector", min: 21, rateBps: 1500 },
  { index: 3, key: "leader", min: 51, rateBps: 1750 },
  { index: 4, key: "champion", min: 101, rateBps: 2000 },
];

export const MIN_WITHDRAW_CENTS = 10_000; // $100
export const MAX_MONTHLY_WITHDRAW_CENTS = 100_000; // $1,000

const ACCRUAL_INTERVAL_MS = 20_000;
const ACCRUAL_BATCH = 500;

export function tierForActiveCount(n: number): ReferralTier {
  let tier = REFERRAL_TIERS[0];
  for (const t of REFERRAL_TIERS) if (n >= t.min) tier = t;
  return tier;
}

function nextTier(t: ReferralTier): ReferralTier | null {
  return REFERRAL_TIERS[t.index + 1] ?? null;
}

/** Current calendar month as `YYYY-MM` (UTC), used for the monthly cap. */
function currentPeriod(): string {
  return new Date().toISOString().slice(0, 7);
}

// -------------------------------------------------------------- referral codes

// No ambiguous characters (I, O, 0, 1) so codes are easy to read and share.
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 7;

function generateCode(): string {
  const bytes = randomBytes(CODE_LENGTH);
  let out = "";
  for (let i = 0; i < CODE_LENGTH; i++) out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  return out;
}

/**
 * Return the user's referral code, generating (and persisting) an immutable one
 * on first use. Retries on the (rare) code collision; a concurrent creation for
 * the same user resolves to the row that won the race.
 */
export async function getOrCreateReferralCode(userId: string): Promise<string> {
  const [existing] = await db
    .select({ code: referralCodesTable.code })
    .from(referralCodesTable)
    .where(eq(referralCodesTable.userId, userId));
  if (existing) return existing.code;

  for (let attempt = 0; attempt < 8; attempt++) {
    const code = generateCode();
    const inserted = await db
      .insert(referralCodesTable)
      .values({ userId, code })
      .onConflictDoNothing()
      .returning({ code: referralCodesTable.code });
    if (inserted.length > 0) return inserted[0].code;
    // Conflict: either this user already has a code (race) or the code collided.
    const [again] = await db
      .select({ code: referralCodesTable.code })
      .from(referralCodesTable)
      .where(eq(referralCodesTable.userId, userId));
    if (again) return again.code;
    // Otherwise it was a code collision — loop and try a fresh code.
  }
  throw new AppError("Couldn't generate a referral code. Please try again.");
}

/** Build the public sign-up link for a code (best-effort server origin). */
function referralLink(code: string): string {
  const origin = getAllowedOrigins()[0];
  const base = origin ? origin.replace(/\/+$/, "") : "";
  return `${base}/register?ref=${code}`;
}

/**
 * Attribute a new sign-up to a referrer by code. Called during registration.
 * Invalid/self/duplicate codes are ignored SILENTLY and never fail registration
 * (the `refereeId` unique constraint makes re-attribution a no-op). Pass the
 * caller's `tx` to commit attribution atomically with the user row.
 */
export async function attributeReferral(
  refereeId: string,
  code: string | null | undefined,
  exec: DbLike = db,
): Promise<void> {
  try {
    const trimmed = (code ?? "").trim().toUpperCase();
    if (!trimmed) return;
    const [codeRow] = await exec
      .select({ userId: referralCodesTable.userId })
      .from(referralCodesTable)
      .where(eq(referralCodesTable.code, trimmed));
    if (!codeRow) return; // unknown code
    if (codeRow.userId === refereeId) return; // self-referral
    await exec
      .insert(referralsTable)
      .values({ referrerId: codeRow.userId, refereeId })
      .onConflictDoNothing();
  } catch (e) {
    // Attribution is best-effort; a failure must never block a sign-up.
    logger.warn({ err: e, refereeId }, "[referrals] attribution failed (ignored)");
  }
}

// -------------------------------------------------------------- active savers

/** Count a referrer's referees who are currently active savers. */
async function countActiveReferrals(referrerId: string, exec: DbLike = db): Promise<number> {
  const [r] = await exec
    .select({ c: sql<number>`count(*)::int` })
    .from(referralsTable)
    .innerJoin(
      streaksTable,
      and(
        eq(streaksTable.userId, referralsTable.refereeId),
        eq(streaksTable.commitmentType, ACCOUNT_STREAK),
        inArray(streaksTable.status, [...ACTIVE_STREAK_STATUSES]),
        gt(streaksTable.currentCount, 0),
      ),
    )
    .where(eq(referralsTable.referrerId, referrerId));
  return Number(r?.c ?? 0);
}

// -------------------------------------------------------------- accrual sweep

type FeeCandidate = {
  id: string;
  userId: string | null;
  circleId: string | null;
  round: number | null;
};

/** Resolve the referee (fee-paying user) for a confirmed fee transaction. */
async function resolveReferee(c: FeeCandidate): Promise<string | null> {
  if (c.userId) return c.userId; // goal-withdrawal fee carries the owner
  if (c.circleId != null && c.round != null) {
    // Circle-payout fee is booked pool→external with a null userId; the fee is
    // borne by the round's payout recipient, so resolve via the payout txn.
    const [payout] = await db
      .select({ userId: transactionsTable.userId })
      .from(transactionsTable)
      .where(
        and(
          eq(transactionsTable.type, "payout"),
          eq(transactionsTable.circleId, c.circleId),
          eq(transactionsTable.round, c.round),
        ),
      )
      .limit(1);
    return payout?.userId ?? null;
  }
  return null;
}

/** The account key the fee landed in, and its amount (the positive posting). */
async function feeDestination(txnId: string): Promise<{ key: string; feeCents: number } | null> {
  const [row] = await db
    .select({ key: ledgerAccountsTable.key, amountCents: postingsTable.amountCents })
    .from(postingsTable)
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .where(and(eq(postingsTable.transactionId, txnId), gt(postingsTable.amountCents, 0)))
    .limit(1);
  if (!row) return null;
  return { key: row.key, feeCents: Number(row.amountCents) };
}

async function accrueOne(c: FeeCandidate): Promise<boolean> {
  const refereeId = await resolveReferee(c);
  let referrerId: string | null = null;
  if (refereeId) {
    const [ref] = await db
      .select({ referrerId: referralsTable.referrerId })
      .from(referralsTable)
      .where(eq(referralsTable.refereeId, refereeId));
    referrerId = ref?.referrerId ?? null;
  }

  const dest = await feeDestination(c.id);
  const feeCents = dest?.feeCents ?? 0;
  const feeAccountKey = dest?.key ?? null;

  const hasReferrer = !!referrerId && !!refereeId && referrerId !== refereeId;

  // No attributable referrer (or nothing to earn): record a 'skipped' marker so
  // the sweep never reconsiders this fee.
  if (!hasReferrer || feeCents <= 0 || !feeAccountKey) {
    await db
      .insert(referralEarningsTable)
      .values({
        sourceTransactionId: c.id,
        referrerId: hasReferrer ? referrerId : null,
        refereeId: refereeId ?? null,
        feeCents,
        rateBps: 0,
        commissionCents: 0,
        status: "skipped",
      })
      .onConflictDoNothing();
    return false;
  }

  const activeCount = await countActiveReferrals(referrerId!);
  const rateBps = tierForActiveCount(activeCount).rateBps;
  const commissionCents = Math.floor((feeCents * rateBps) / 10_000);

  if (commissionCents <= 0) {
    await db
      .insert(referralEarningsTable)
      .values({
        sourceTransactionId: c.id,
        referrerId,
        refereeId,
        feeCents,
        rateBps,
        commissionCents: 0,
        status: "skipped",
      })
      .onConflictDoNothing();
    return false;
  }

  // Book the earning row + ledger credit atomically; the unique constraint on
  // sourceTransactionId makes a concurrent sweep a no-op.
  await db.transaction(async (tx) => {
    const inserted = await tx
      .insert(referralEarningsTable)
      .values({
        sourceTransactionId: c.id,
        referrerId,
        refereeId,
        feeCents,
        rateBps,
        commissionCents,
        status: "earned",
      })
      .onConflictDoNothing()
      .returning({ id: referralEarningsTable.id });
    if (inserted.length === 0) return; // already accrued
    await transfer({
      type: "referral_earning",
      description: "Referral commission",
      userId: referrerId,
      fromKey: feeAccountKey,
      toKey: acct.referral(referrerId!),
      amountCents: commissionCents,
      tx,
    });
  });
  return true;
}

/**
 * Idempotently accrue referral commission for every confirmed platform-fee
 * transaction not yet processed. Safe to run repeatedly and concurrently.
 * Returns the number of earnings booked this pass.
 */
export async function accrueReferralEarnings(limit = ACCRUAL_BATCH): Promise<number> {
  const candidates = await db
    .select({
      id: transactionsTable.id,
      userId: transactionsTable.userId,
      circleId: transactionsTable.circleId,
      round: transactionsTable.round,
    })
    .from(transactionsTable)
    .leftJoin(referralEarningsTable, eq(referralEarningsTable.sourceTransactionId, transactionsTable.id))
    .where(
      and(
        eq(transactionsTable.type, "fee"),
        eq(transactionsTable.onchainStatus, "confirmed"),
        isNull(referralEarningsTable.id),
      ),
    )
    .orderBy(transactionsTable.createdAt)
    .limit(limit);

  let booked = 0;
  for (const c of candidates) {
    try {
      if (await accrueOne(c)) booked++;
    } catch (e) {
      logger.error({ err: e, txnId: c.id }, "[referrals] accrual failed for fee txn");
    }
  }
  return booked;
}

let accrualTimer: ReturnType<typeof setInterval> | null = null;

/** Start the background accrual loop (mirrors startStreakLoop in index.ts). */
export function startReferralAccrualLoop(): void {
  if (accrualTimer) return;
  const run = async () => {
    try {
      await accrueReferralEarnings();
    } catch (e) {
      logger.error({ err: e }, "[referrals] accrual loop error");
    }
  };
  void run();
  accrualTimer = setInterval(run, ACCRUAL_INTERVAL_MS);
  if (typeof accrualTimer.unref === "function") accrualTimer.unref();
}

// -------------------------------------------------------------- pending earnings

/**
 * Read-only estimate of commission from fees that haven't settled on-chain yet,
 * at the referrer's CURRENT rate. Never stored; shown for transparency until the
 * underlying fees confirm and become real earnings.
 */
async function pendingCommissionCents(referrerId: string, rateBps: number): Promise<number> {
  // Goal-withdrawal fees (fee txn carries the referee's userId).
  const [goal] = await db
    .select({ s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)::int` })
    .from(transactionsTable)
    .innerJoin(
      postingsTable,
      and(eq(postingsTable.transactionId, transactionsTable.id), gt(postingsTable.amountCents, 0)),
    )
    .innerJoin(referralsTable, eq(referralsTable.refereeId, transactionsTable.userId))
    .where(
      and(
        eq(transactionsTable.type, "fee"),
        eq(transactionsTable.onchainStatus, "pending"),
        eq(referralsTable.referrerId, referrerId),
      ),
    );

  // Circle-payout fees (null userId; recipient resolved via the payout txn).
  const payoutTxn = alias(transactionsTable, "payout_txn");
  const [circle] = await db
    .select({ s: sql<number>`coalesce(sum(${postingsTable.amountCents}), 0)::int` })
    .from(transactionsTable)
    .innerJoin(
      postingsTable,
      and(eq(postingsTable.transactionId, transactionsTable.id), gt(postingsTable.amountCents, 0)),
    )
    .innerJoin(
      payoutTxn,
      and(
        eq(payoutTxn.type, "payout"),
        eq(payoutTxn.circleId, transactionsTable.circleId),
        eq(payoutTxn.round, transactionsTable.round),
      ),
    )
    .innerJoin(referralsTable, eq(referralsTable.refereeId, payoutTxn.userId))
    .where(
      and(
        eq(transactionsTable.type, "fee"),
        eq(transactionsTable.onchainStatus, "pending"),
        isNull(transactionsTable.userId),
        eq(referralsTable.referrerId, referrerId),
      ),
    );

  const pendingFee = Number(goal?.s ?? 0) + Number(circle?.s ?? 0);
  return Math.floor((pendingFee * rateBps) / 10_000);
}

// -------------------------------------------------------------- overview

export type ReferralRefereeView = {
  name: string;
  username: string | null;
  joinedAt: string;
  status: "active" | "inactive" | "pending";
  /** Non-monetary activity signal (current savings-streak length). */
  activityCount: number;
  /** Commission THIS referrer earned from this referee (their own data). */
  feesEarnedCents: number;
};

export type ReferralOverview = {
  code: string;
  link: string;
  tier: {
    key: ReferralTier["key"];
    rateBps: number;
    minActive: number;
    nextTierKey: ReferralTier["key"] | null;
    nextTierRateBps: number | null;
    nextTierAtActive: number | null;
  };
  activeReferrals: number;
  totalReferred: number;
  pendingCents: number;
  availableCents: number;
  lifetimeCents: number;
  withdrawal: {
    minCents: number;
    maxMonthlyCents: number;
    withdrawnThisMonthCents: number;
    remainingThisMonthCents: number;
    hasWallet: boolean;
  };
  referrals: ReferralRefereeView[];
};

async function sumWithdrawnThisMonth(userId: string, period: string, exec: DbLike = db): Promise<number> {
  const [r] = await exec
    .select({ s: sql<number>`coalesce(sum(${referralWithdrawalsTable.amountCents}), 0)::int` })
    .from(referralWithdrawalsTable)
    .leftJoin(transactionsTable, eq(transactionsTable.id, referralWithdrawalsTable.transactionId))
    .where(
      and(
        eq(referralWithdrawalsTable.userId, userId),
        eq(referralWithdrawalsTable.period, period),
        // A withdrawal whose on-chain send dead-lettered is reversed on the
        // ledger; don't let it consume the user's monthly allowance.
        or(isNull(transactionsTable.onchainStatus), ne(transactionsTable.onchainStatus, "failed")),
      ),
    );
  return Number(r?.s ?? 0);
}

export async function getReferralOverview(userId: string): Promise<ReferralOverview> {
  const code = await getOrCreateReferralCode(userId);

  const rows = await db
    .select({
      refereeId: referralsTable.refereeId,
      name: usersTable.name,
      username: usersTable.username,
      joinedAt: referralsTable.createdAt,
      streakStatus: streaksTable.status,
      currentCount: streaksTable.currentCount,
      bestCount: streaksTable.bestCount,
    })
    .from(referralsTable)
    .innerJoin(usersTable, eq(usersTable.id, referralsTable.refereeId))
    .leftJoin(
      streaksTable,
      and(eq(streaksTable.userId, referralsTable.refereeId), eq(streaksTable.commitmentType, ACCOUNT_STREAK)),
    )
    .where(eq(referralsTable.referrerId, userId))
    .orderBy(desc(referralsTable.createdAt));

  const feeRows = await db
    .select({
      refereeId: referralEarningsTable.refereeId,
      s: sql<number>`coalesce(sum(${referralEarningsTable.commissionCents}), 0)::int`,
    })
    .from(referralEarningsTable)
    .where(and(eq(referralEarningsTable.referrerId, userId), eq(referralEarningsTable.status, "earned")))
    .groupBy(referralEarningsTable.refereeId);
  const feeByReferee = new Map<string, number>();
  for (const r of feeRows) if (r.refereeId) feeByReferee.set(r.refereeId, Number(r.s));

  let activeReferrals = 0;
  const referrals: ReferralRefereeView[] = rows.map((r) => {
    const active =
      !!r.streakStatus &&
      (ACTIVE_STREAK_STATUSES as readonly string[]).includes(r.streakStatus) &&
      (r.currentCount ?? 0) > 0;
    if (active) activeReferrals++;
    const status: ReferralRefereeView["status"] = active
      ? "active"
      : (r.bestCount ?? 0) > 0
        ? "inactive"
        : "pending";
    return {
      name: r.name,
      username: r.username ?? null,
      joinedAt: r.joinedAt.toISOString(),
      status,
      activityCount: r.currentCount ?? 0,
      feesEarnedCents: feeByReferee.get(r.refereeId) ?? 0,
    };
  });

  const tier = tierForActiveCount(activeReferrals);
  const next = nextTier(tier);

  const availableCents = await accountBalance(acct.referral(userId));
  const [lt] = await db
    .select({ s: sql<number>`coalesce(sum(${referralEarningsTable.commissionCents}), 0)::int` })
    .from(referralEarningsTable)
    .where(and(eq(referralEarningsTable.referrerId, userId), eq(referralEarningsTable.status, "earned")));
  const lifetimeCents = Number(lt?.s ?? 0);
  const pendingCents = await pendingCommissionCents(userId, tier.rateBps);

  const period = currentPeriod();
  const withdrawnThisMonthCents = await sumWithdrawnThisMonth(userId, period);
  const wallet = await getWalletForUser(userId);

  return {
    code,
    link: referralLink(code),
    tier: {
      key: tier.key,
      rateBps: tier.rateBps,
      minActive: tier.min,
      nextTierKey: next?.key ?? null,
      nextTierRateBps: next?.rateBps ?? null,
      nextTierAtActive: next?.min ?? null,
    },
    activeReferrals,
    totalReferred: rows.length,
    pendingCents,
    availableCents,
    lifetimeCents,
    withdrawal: {
      minCents: MIN_WITHDRAW_CENTS,
      maxMonthlyCents: MAX_MONTHLY_WITHDRAW_CENTS,
      withdrawnThisMonthCents,
      remainingThisMonthCents: Math.max(0, MAX_MONTHLY_WITHDRAW_CENTS - withdrawnThisMonthCents),
      hasWallet: !!wallet,
    },
    referrals,
  };
}

// -------------------------------------------------------------- withdrawal

/**
 * Withdraw available referral earnings to the user's wallet. When on-chain is
 * enabled the payout is sent as USDC (platform → the user's wallet address) via
 * the settlement queue; offline it credits the wallet ledger balance directly.
 * Enforces the min-per-withdrawal and max-per-month limits, atomically.
 */
export async function withdrawReferralEarnings(
  userId: string,
  amountCents: number,
): Promise<{ amountCents: number }> {
  if (!Number.isInteger(amountCents) || amountCents <= 0) {
    throw new AppError("Enter a valid amount.");
  }
  if (amountCents < MIN_WITHDRAW_CENTS) {
    throw new AppError(`The minimum withdrawal is ${formatMoney(MIN_WITHDRAW_CENTS)}.`);
  }

  const settle = onchainEnabled();
  let toAddress: string | null = null;
  if (settle) {
    const wallet = await requireWalletForUser(userId);
    toAddress = wallet.address;
  }

  const period = currentPeriod();
  const already = await sumWithdrawnThisMonth(userId, period);
  const remaining = MAX_MONTHLY_WITHDRAW_CENTS - already;
  if (remaining < MIN_WITHDRAW_CENTS) {
    throw new AppError(
      `You've reached your ${formatMoney(MAX_MONTHLY_WITHDRAW_CENTS)} monthly withdrawal limit. Please try again next month.`,
    );
  }
  if (amountCents > remaining) {
    throw new AppError(`That's over your remaining monthly limit of ${formatMoney(remaining)}.`);
  }
  const available = await accountBalance(acct.referral(userId));
  if (available < amountCents) throw new AppError("You don't have that much in available earnings.");

  const wd = await db.transaction(async (tx) => {
    // Serialize concurrent withdrawals for this user BEFORE reading the monthly
    // sum: a per-user transaction-scoped advisory lock ensures the cap re-check
    // below sees every already-committed withdrawal. Without it, two concurrent
    // requests would both read the same monthSum and each pass the cap check,
    // then serialize only on the per-account balance lock inside transfer() —
    // letting a user with a large balance exceed the monthly cap. This lock key
    // is distinct from the account keys transfer() locks and is always taken
    // first, so there is no deadlock with the account-ordered locks that follow.
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${`referral-wd:${userId}`}))`);
    const monthSum = await sumWithdrawnThisMonth(userId, period, tx);
    if (monthSum + amountCents > MAX_MONTHLY_WITHDRAW_CENTS) {
      throw new AppError(
        `That's over your remaining monthly limit of ${formatMoney(Math.max(0, MAX_MONTHLY_WITHDRAW_CENTS - monthSum))}.`,
      );
    }
    const toKey = settle ? acct.external : acct.wallet(userId);
    const txn = await transfer({
      type: "referral_withdrawal",
      description: settle ? "Referral earnings withdrawal" : "Referral earnings moved to wallet",
      userId,
      fromKey: acct.referral(userId),
      toKey,
      amountCents,
      onchain: { onchainStatus: settle ? "pending" : "none" },
      requireSufficientFrom: true,
      tx,
    });
    const [row] = await tx
      .insert(referralWithdrawalsTable)
      .values({ userId, transactionId: txn.id, amountCents, period })
      .returning({ id: referralWithdrawalsTable.id });
    if (settle && toAddress) {
      await enqueueOnchainTransfer(
        {
          transactionId: txn.id,
          kind: "payout",
          sourceUserId: null,
          toAddress,
          amountCents,
          memo: `referral:${row.id}`,
        },
        tx,
      );
    }
    return row;
  });

  if (settle) kickReconciler();
  await notify(
    userId,
    {
      type: "withdrawal",
      title: "Referral earnings withdrawal",
      body: `${formatMoney(amountCents)} of referral earnings is on its way to your wallet.`,
      link: "/referrals",
    },
    { email: true },
  ).catch((e) => logger.warn({ err: e, userId, wd }, "referral withdrawal notification failed"));

  return { amountCents };
}
