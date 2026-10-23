/**
 * Refer & Earn engine smoke test against the real DB (OFFLINE / ledger-only).
 * Run: pnpm --filter @workspace/api-server run test:referrals
 *
 * Validates the whole backend contract:
 *  - code generation (format + idempotency)
 *  - attribution (valid / self / invalid / duplicate are all handled safely)
 *  - tier rate table across every boundary
 *  - idempotent accrual sweep over confirmed platform-fee transactions
 *    (goal-fee path via userId, circle-fee path via the payout join), including
 *    'skipped' markers that prevent re-scanning unattributable fees
 *  - overview projection (earnings, active count, privacy: no referee balances)
 *  - withdrawal limits (min per withdrawal, $1,000 monthly cap) + offline
 *    ledger settlement (referral -> wallet)
 *  - the REFERRAL_REWARDS_ENABLED flag: off by default (no accrual, a fee seen
 *    while off is never paid retroactively, withdrawals refused), then on for
 *    the rest of the engine checks
 *
 * chain.ts snapshots USDC_CONTRACT_ADDRESS at import and email.ts snapshots
 * RESEND_API_KEY at import, so clear them BEFORE importing for deterministic
 * offline behavior (no on-chain settlement, no outbound email).
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;
// Rewards default to OFF; the flag is read per call, so the test flips it below.
delete process.env.REFERRAL_REWARDS_ENABLED;

const {
  db,
  usersTable,
  circlesTable,
  referralsTable,
  referralEarningsTable,
  referralWithdrawalsTable,
} = await import("@workspace/db");
const { purgeTestData } = await import("@workspace/db/testing");
const { eq, and } = await import("drizzle-orm");
const { acct, transfer, accountBalance } = await import("./ledger");
const { onchainEnabled } = await import("./chain");
const { recordSave } = await import("./streaks");
const {
  getOrCreateReferralCode,
  attributeReferral,
  accrueReferralEarnings,
  getReferralOverview,
  withdrawReferralEarnings,
  referralRewardsEnabled,
  tierForActiveCount,
  MIN_WITHDRAW_CENTS,
  MAX_MONTHLY_WITHDRAW_CENTS,
} = await import("./referrals");

const CODE_RE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{7}$/;

async function mkUser(label: string): Promise<string> {
  const id = randomUUID();
  await db.insert(usersTable).values({
    id,
    name: `${label} ${id.slice(0, 6)}`,
    email: `ref-${label}-${id}@test.local`,
    username: `ref_${label}_${id.slice(0, 8)}`.toLowerCase(),
    timezone: "UTC",
  });
  return id;
}

async function confirmedFee(opts: {
  amountCents: number;
  userId?: string | null;
  circleId?: string | null;
  round?: number | null;
  fromKey: string;
  toKey: string;
}): Promise<string> {
  const txn = await transfer({
    type: "fee",
    description: "test platform fee",
    userId: opts.userId ?? null,
    circleId: opts.circleId ?? null,
    round: opts.round ?? null,
    fromKey: opts.fromKey,
    toKey: opts.toKey,
    amountCents: opts.amountCents,
    onchain: { onchainStatus: "confirmed" },
  });
  return txn.id;
}

async function main() {
  assert.equal(onchainEnabled(), false, "test must run offline (on-chain disabled)");

  // ---- tier rate table (every boundary) ----
  const cases: Array<[number, number, string]> = [
    [0, 1000, "starter"],
    [5, 1000, "starter"],
    [6, 1250, "builder"],
    [20, 1250, "builder"],
    [21, 1500, "connector"],
    [50, 1500, "connector"],
    [51, 1750, "leader"],
    [100, 1750, "leader"],
    [101, 2000, "champion"],
    [5000, 2000, "champion"],
  ];
  for (const [n, bps, key] of cases) {
    const t = tierForActiveCount(n);
    assert.equal(t.rateBps, bps, `tier bps for ${n} active should be ${bps}, got ${t.rateBps}`);
    assert.equal(t.key, key, `tier key for ${n} active should be ${key}, got ${t.key}`);
  }

  const referrer = await mkUser("referrer");
  const referee = await mkUser("referee");
  const stranger = await mkUser("stranger");
  const referrer2 = await mkUser("cap");
  const referrer3 = await mkUser("circle");
  const referee3 = await mkUser("circleref");
  const created = [referrer, referee, stranger, referrer2, referrer3, referee3];
  let createdCircleId: string | null = null;

  try {
    // ---- code generation ----
    const code = await getOrCreateReferralCode(referrer);
    assert.ok(CODE_RE.test(code), `code should match format, got "${code}"`);
    assert.equal(await getOrCreateReferralCode(referrer), code, "code must be stable/idempotent");

    // ---- attribution ----
    // self-referral is ignored
    await attributeReferral(referrer, code);
    // invalid code is ignored
    await attributeReferral(referee, "ZZZZZZZ");
    let refRows = await db.select().from(referralsTable).where(eq(referralsTable.referrerId, referrer));
    assert.equal(refRows.length, 0, "no attribution yet (self + invalid ignored)");

    // valid attribution
    await attributeReferral(referee, code);
    // duplicate attribution is a no-op (refereeId is unique)
    await attributeReferral(referee, code);
    const code2 = await getOrCreateReferralCode(stranger);
    // a referee can never be reassigned to a new referrer
    await attributeReferral(referee, code2);
    refRows = await db.select().from(referralsTable).where(eq(referralsTable.refereeId, referee));
    assert.equal(refRows.length, 1, "exactly one referral row for the referee");
    assert.equal(refRows[0].referrerId, referrer, "referrer is locked to the first attributer");

    // ---- make the referee an active saver ----
    await recordSave(referee, `save-${randomUUID()}`, new Date("2026-02-02T12:00:00Z"));

    // ---- rewards OFF (the default): nothing accrues, withdrawals refused ----
    assert.equal(referralRewardsEnabled(), false, "currency rewards are off by default");
    const offFeeTxn = await confirmedFee({
      amountCents: 100_000,
      userId: referee,
      fromKey: acct.external,
      toKey: acct.fees,
    });
    assert.equal(await accrueReferralEarnings(), 0, "no earnings book while rewards are off");
    assert.equal(await accountBalance(acct.referral(referrer)), 0, "no commission credited while off");
    const offRow = (
      await db
        .select()
        .from(referralEarningsTable)
        .where(eq(referralEarningsTable.sourceTransactionId, offFeeTxn))
    )[0];
    assert.ok(offRow && offRow.status === "skipped" && offRow.commissionCents === 0, "fee seen while off is closed out as skipped");
    await assert.rejects(
      () => withdrawReferralEarnings(referrer, MIN_WITHDRAW_CENTS),
      /paused/i,
      "withdrawals are refused while rewards are off",
    );
    const offOv = await getReferralOverview(referrer);
    assert.equal(offOv.rewardsEnabled, false, "overview tells the app rewards are off");
    assert.equal(offOv.code, code, "the invite code still works while rewards are off");

    // ---- rewards ON for the rest of the engine checks ----
    process.env.REFERRAL_REWARDS_ENABLED = "true";
    assert.equal(referralRewardsEnabled(), true, "flag is read per call");
    await accrueReferralEarnings();
    assert.equal(
      await accountBalance(acct.referral(referrer)),
      0,
      "turning rewards back on never pays out a fee from the off period",
    );

    // ---- accrual: goal-fee path (fee carries the referee's userId) ----
    const feeCents = 200_000; // $2,000 fee
    const feeTxn = await confirmedFee({
      amountCents: feeCents,
      userId: referee,
      fromKey: acct.external,
      toKey: acct.fees,
    });

    const booked = await accrueReferralEarnings();
    assert.ok(booked >= 1, "at least one earning booked");

    const expectedCommission = Math.floor((feeCents * 1000) / 10_000); // 10% base = 20000
    assert.equal(
      await accountBalance(acct.referral(referrer)),
      expectedCommission,
      "referrer's referral balance equals the booked commission",
    );
    const earnRow = (
      await db
        .select()
        .from(referralEarningsTable)
        .where(eq(referralEarningsTable.sourceTransactionId, feeTxn))
    )[0];
    assert.ok(earnRow, "earning row exists for the fee");
    assert.equal(earnRow.status, "earned", "status earned");
    assert.equal(earnRow.rateBps, 1000, "rate locked at base 10%");
    assert.equal(earnRow.commissionCents, expectedCommission, "commission recorded");

    // ---- idempotency: a second sweep must NOT double-credit ----
    await accrueReferralEarnings();
    assert.equal(
      await accountBalance(acct.referral(referrer)),
      expectedCommission,
      "re-running the sweep does not double-credit",
    );
    const earnCount = (
      await db
        .select()
        .from(referralEarningsTable)
        .where(eq(referralEarningsTable.sourceTransactionId, feeTxn))
    ).length;
    assert.equal(earnCount, 1, "exactly one earning row per fee");

    // ---- 'skipped': a fee with no attributable referrer is marked, not credited ----
    const orphanFee = await confirmedFee({
      amountCents: 50_000,
      userId: stranger, // stranger was never referred
      fromKey: acct.external,
      toKey: acct.fees,
    });
    await accrueReferralEarnings();
    const orphanRow = (
      await db
        .select()
        .from(referralEarningsTable)
        .where(eq(referralEarningsTable.sourceTransactionId, orphanFee))
    )[0];
    assert.ok(orphanRow, "orphan fee produces a marker row");
    assert.equal(orphanRow.status, "skipped", "unattributable fee is skipped");
    assert.equal(orphanRow.commissionCents, 0, "no commission on skipped fee");

    // ---- accrual: circle-fee path (null userId; recipient via payout join) ----
    await attributeReferral(referee3, await getOrCreateReferralCode(referrer3));
    await recordSave(referee3, `save-${randomUUID()}`, new Date("2026-02-03T12:00:00Z"));
    // a real circle row (pool ledger account + transaction.circleId both FK to circles)
    const [circleRow] = await db
      .insert(circlesTable)
      .values({ name: "Test Circle", createdById: referrer3, contributionCents: 100_000 })
      .returning();
    const circleId = circleRow.id;
    createdCircleId = circleId;
    const round = 1;
    // the round's payout to the referee (carries userId + circle context)
    await transfer({
      type: "payout",
      description: "test circle payout",
      userId: referee3,
      circleId,
      round,
      fromKey: acct.pool(circleId),
      toKey: acct.wallet(referee3),
      amountCents: 300_000,
      onchain: { onchainStatus: "confirmed" },
    });
    // the circle fee (null userId, positive posting on external)
    const circleFeeCents = 100_000;
    const circleFeeTxn = await confirmedFee({
      amountCents: circleFeeCents,
      userId: null,
      circleId,
      round,
      fromKey: acct.pool(circleId),
      toKey: acct.external,
    });
    await accrueReferralEarnings();
    const circleEarn = (
      await db
        .select()
        .from(referralEarningsTable)
        .where(eq(referralEarningsTable.sourceTransactionId, circleFeeTxn))
    )[0];
    assert.ok(circleEarn, "circle fee produces an earning");
    assert.equal(circleEarn.status, "earned", "circle fee attributed via payout join");
    assert.equal(circleEarn.referrerId, referrer3, "referrer resolved from circle payout recipient");
    assert.equal(
      await accountBalance(acct.referral(referrer3)),
      Math.floor((circleFeeCents * 1000) / 10_000),
      "circle-fee commission credited to referrer3",
    );

    // ---- overview projection ----
    const ov = await getReferralOverview(referrer);
    assert.equal(ov.code, code, "overview returns the stable code");
    assert.equal(ov.rewardsEnabled, true, "overview reports rewards on");
    assert.ok(ov.link.includes(`ref=${code}`), "overview link carries the code");
    assert.equal(ov.activeReferrals, 1, "one active referral");
    assert.equal(ov.totalReferred, 1, "one total referral");
    assert.equal(ov.availableCents, expectedCommission, "available equals booked commission");
    assert.equal(ov.lifetimeCents, expectedCommission, "lifetime equals booked commission");
    assert.equal(ov.tier.key, "starter", "starter tier at 1 active");
    assert.equal(ov.tier.rateBps, 1000, "10% base rate");
    assert.equal(ov.tier.nextTierAtActive, 6, "next tier at 6 active");
    assert.equal(ov.withdrawal.minCents, MIN_WITHDRAW_CENTS, "min withdrawal exposed");
    assert.equal(ov.withdrawal.maxMonthlyCents, MAX_MONTHLY_WITHDRAW_CENTS, "monthly cap exposed");
    assert.equal(ov.referrals.length, 1, "one referee in the list");
    assert.equal(ov.referrals[0].status, "active", "referee shown active");
    assert.equal(ov.referrals[0].feesEarnedCents, expectedCommission, "per-referee earnings are the referrer's own");
    // privacy: the referee view exposes NO balance/amount fields of the referee
    assert.ok(
      !("balanceCents" in ov.referrals[0]) && !("savedCents" in ov.referrals[0]),
      "referee balances are never exposed",
    );

    // ---- withdrawal (offline: referral -> wallet ledger transfer) ----
    // below the minimum is rejected
    await assert.rejects(
      () => withdrawReferralEarnings(referrer, MIN_WITHDRAW_CENTS - 1),
      /minimum withdrawal/i,
      "below-min withdrawal rejected",
    );
    // more than available is rejected
    await assert.rejects(
      () => withdrawReferralEarnings(referrer, expectedCommission + 1),
      /available earnings/i,
      "over-balance withdrawal rejected",
    );
    // a valid withdrawal settles referral -> wallet offline
    await withdrawReferralEarnings(referrer, MIN_WITHDRAW_CENTS);
    assert.equal(
      await accountBalance(acct.referral(referrer)),
      expectedCommission - MIN_WITHDRAW_CENTS,
      "referral balance reduced by withdrawal",
    );
    assert.equal(
      await accountBalance(acct.wallet(referrer)),
      MIN_WITHDRAW_CENTS,
      "offline withdrawal credits the wallet ledger",
    );
    const wdRows = await db
      .select()
      .from(referralWithdrawalsTable)
      .where(eq(referralWithdrawalsTable.userId, referrer));
    assert.equal(wdRows.length, 1, "one withdrawal recorded");
    assert.match(wdRows[0].period, /^\d{4}-\d{2}$/, "period is YYYY-MM");

    // ---- monthly cap ($1,000) ----
    // seed a large balance directly on the ledger for a clean cap test
    await transfer({
      type: "referral_earning",
      description: "seed",
      userId: referrer2,
      fromKey: acct.external,
      toKey: acct.referral(referrer2),
      amountCents: 150_000,
    });
    await withdrawReferralEarnings(referrer2, 60_000);
    await withdrawReferralEarnings(referrer2, 40_000); // total 100_000 = cap
    await assert.rejects(
      () => withdrawReferralEarnings(referrer2, MIN_WITHDRAW_CENTS),
      /monthly/i,
      "withdrawal beyond the monthly cap is rejected",
    );
    const capOv = await getReferralOverview(referrer2);
    assert.equal(capOv.withdrawal.withdrawnThisMonthCents, 100_000, "monthly total tracked");
    assert.equal(capOv.withdrawal.remainingThisMonthCents, 0, "no monthly allowance remaining");

    console.log(
      "✅ referrals.e2e passed: codes, attribution, tiers, idempotent accrual (goal + circle), skipped markers, overview privacy, withdrawal min/cap + offline settlement",
    );
  } finally {
    // Postings are append-only and no longer cascade away, so purge explicitly:
    // every ledger transaction of these users and the circle (fees, payouts,
    // commissions, withdrawals) with all its postings, then the circle and the
    // users, whose deletion cascades the referral_* rows and streaks.
    await purgeTestData({ userIds: created, circleIds: createdCircleId ? [createdCircleId] : [] });
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
