/**
 * End-to-end test: the accumulation Susu circle "save-and-get-it-back" flow.
 *
 * Where a rotation circle pays the full pot to one recipient per round, an
 * accumulation circle has NO per-round recipient. Every member saves into the
 * shared pool each round, and on the FINAL round every member receives their
 * own savings back (contribution × totalRounds). This is the highest-risk new
 * branch in `maybeProcessPayout` because the final round fans out into one
 * payout per member instead of a single recipient.
 *
 * Exercises the real lifecycle against a real database, using the same library
 * functions the HTTP routes call:
 *
 *   create(type=accumulation, numRounds=R) -> invite -> accept -> start ->
 *   every member contributes each of R rounds -> on the final round every
 *   member is paid back their own savings -> the circle completes.
 *
 * It asserts:
 *   - rounds are fixed at creation (numRounds) and do NOT track member count,
 *   - NO payout happens before the final round (savings just accumulate),
 *   - on the final round each member receives exactly ONE payout of
 *     contribution × totalRounds,
 *   - the final round's contributions can land CONCURRENTLY without any member
 *     being double-paid (the paidOut false->true claim is the guard),
 *   - the circle transitions to `completed` after the last round,
 *   - the pool is fully disbursed and every member is net-zero afterwards.
 *
 * Scope: on-chain USDC settlement is intentionally OUT of scope (out-of-band
 * queue + reconciler concern). We disable it (and transactional email) BEFORE
 * importing any module so the test is deterministic and fully offline — the
 * double-entry ledger postings that drive payouts and balances are identical
 * either way.
 *
 * Run: pnpm --filter @workspace/api-server test:susu-accumulation
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

// Disable on-chain settlement and email at the source. `chain.ts` snapshots the
// USDC contract address at import time and `email.ts` snapshots the Resend key,
// so these must be cleared before the dynamic imports below.
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, circlesTable, circleMembersTable, contributionsTable, ledgerAccountsTable, postingsTable, transactionsTable } =
  await import("@workspace/db");
const { eq, and, inArray } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { faucetDeposit } = await import("./deposits");
const { acct, accountBalance } = await import("./ledger");
const { onchainEnabled } = await import("./chain");
const { emailEnabled } = await import("./email");
const { createCircle, inviteToCircle, listInvitesForUser, acceptInvite, startCircle, contribute, getCircleDetail } =
  await import("./circles");

const runId = randomUUID().slice(0, 8);
const CONTRIBUTION_CENTS = 1000; // $10.00 per round
const NUM_ROUNDS = 4; // accumulation rounds are fixed at creation, NOT member count
const SHARE_CENTS = CONTRIBUTION_CENTS * NUM_ROUNDS; // what each member gets back
const DEPOSIT_CENTS = 6000; // covers all NUM_ROUNDS contributions per member

type TestUser = { id: string; email: string; name: string };

let circleId: string | null = null;
const users: TestUser[] = [];

async function makeUser(label: string): Promise<TestUser> {
  const email = `e2e-acc+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `E2E ACC ${label} ${runId}`, email }).returning();
  await createWalletForUser(u.id);
  const tu = { id: u.id, email: u.email, name: u.name };
  users.push(tu);
  return tu;
}

async function cleanup() {
  try {
    // Delete every transaction that touched the test wallets or the circle pool;
    // this cascades the postings on BOTH sides (including the shared `external`
    // account), so no orphan ledger rows are left behind.
    const keys = [
      ...users.map((u) => acct.wallet(u.id)),
      ...(circleId ? [acct.pool(circleId)] : []),
    ];
    if (keys.length) {
      const accts = await db
        .select({ id: ledgerAccountsTable.id })
        .from(ledgerAccountsTable)
        .where(inArray(ledgerAccountsTable.key, keys));
      const acctIds = accts.map((a) => a.id);
      if (acctIds.length) {
        const txnRows = await db
          .selectDistinct({ id: postingsTable.transactionId })
          .from(postingsTable)
          .where(inArray(postingsTable.accountId, acctIds));
        const txnIds = txnRows.map((r) => r.id);
        if (txnIds.length) {
          await db.delete(transactionsTable).where(inArray(transactionsTable.id, txnIds));
        }
      }
    }
    // Cascades members, invites, contributions and the pool ledger account.
    if (circleId) await db.delete(circlesTable).where(eq(circlesTable.id, circleId));
    // Cascades wallets, notifications and per-user ledger accounts.
    if (users.length) {
      await db.delete(usersTable).where(inArray(usersTable.id, users.map((u) => u.id)));
    }
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
}

async function payoutTxnCountForPool(id: string): Promise<number> {
  const rows = await db
    .selectDistinct({ id: transactionsTable.id })
    .from(postingsTable)
    .innerJoin(transactionsTable, eq(postingsTable.transactionId, transactionsTable.id))
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .where(and(eq(transactionsTable.type, "payout"), eq(ledgerAccountsTable.key, acct.pool(id))));
  return rows.length;
}

async function payoutTxnCountForWallet(userId: string): Promise<number> {
  const rows = await db
    .selectDistinct({ id: transactionsTable.id })
    .from(postingsTable)
    .innerJoin(transactionsTable, eq(postingsTable.transactionId, transactionsTable.id))
    .innerJoin(ledgerAccountsTable, eq(postingsTable.accountId, ledgerAccountsTable.id))
    .where(and(eq(transactionsTable.type, "payout"), eq(ledgerAccountsTable.key, acct.wallet(userId))));
  return rows.length;
}

async function run() {
  assert.equal(onchainEnabled(), false, "on-chain settlement must be disabled for this test");
  assert.equal(emailEnabled(), false, "email must be disabled for this test");

  // --- Setup: three members, each funded via the testnet faucet ----------
  // Member count (3) deliberately differs from round count (4) to prove
  // accumulation rounds are fixed at creation, not derived from membership.
  const creator = await makeUser("creator");
  const m2 = await makeUser("m2");
  const m3 = await makeUser("m3");
  const members = [creator, m2, m3];
  const n = members.length;

  for (const u of members) await faucetDeposit(u.id, DEPOSIT_CENTS);
  for (const u of members) {
    assert.equal(await accountBalance(acct.wallet(u.id)), DEPOSIT_CENTS, "faucet should fund each member");
  }

  // --- Create (accumulation) -> invite -> accept -------------------------
  const circle = await createCircle(creator.id, {
    name: `E2E Acc Susu ${runId}`,
    type: "accumulation",
    contributionCents: CONTRIBUTION_CENTS,
    numRounds: NUM_ROUNDS,
    frequency: "monthly",
  });
  circleId = circle.id;
  assert.equal(circle.type, "accumulation", "circle should be accumulation type");
  assert.equal(circle.totalRounds, NUM_ROUNDS, "accumulation rounds are fixed at creation");
  assert.equal(circle.payoutCents, SHARE_CENTS, "stored payout is contribution × rounds");

  for (const u of [m2, m3]) {
    await inviteToCircle(creator.id, circle.id, u.email);
    const invites = await listInvitesForUser(u.email);
    const invite = invites.find((i) => i.circleName === circle.name);
    assert.ok(invite, `pending invite for ${u.email} should exist`);
    await acceptInvite(u.id, u.email, invite.id);
  }

  // --- Start: rounds stay fixed at NUM_ROUNDS, NOT member count ----------
  await startCircle(creator.id, circle.id);
  const started = await getCircleDetail(creator.id, circle.id);
  assert.equal(started?.status, "active", "circle should be active after start");
  assert.equal(started?.currentRound, 1, "first round should be 1");
  assert.equal(started?.totalRounds, NUM_ROUNDS, "accumulation rounds do not track member count");
  assert.equal(started?.memberCount, n, "all members should be present");
  assert.notEqual(started?.totalRounds, n, "round count differs from member count by design");

  // --- Run every round ---------------------------------------------------
  for (let round = 1; round <= NUM_ROUNDS; round++) {
    const before = await getCircleDetail(creator.id, circle.id);
    assert.equal(before?.currentRound, round, `should be on round ${round}`);

    const balancesBefore = new Map<string, number>();
    for (const u of members) balancesBefore.set(u.id, await accountBalance(acct.wallet(u.id)));

    const isFinal = round === NUM_ROUNDS;

    if (isFinal) {
      // The high-risk path: every member's final contribution lands
      // CONCURRENTLY. Each `contribute` triggers `maybeProcessPayout`, so the
      // multi-member payout fan-out can run from several callers at once. The
      // paidOut false->true claim must ensure no member is paid twice.
      const results = await Promise.allSettled(members.map((u) => contribute(u.id, circle.id)));
      for (let i = 0; i < results.length; i++) {
        assert.equal(
          results[i].status,
          "fulfilled",
          `final-round contribution for member ${i} should succeed (got ${
            results[i].status === "rejected" ? (results[i] as PromiseRejectedResult).reason : "ok"
          })`,
        );
      }
    } else {
      for (let i = 0; i < members.length; i++) {
        const u = members[i];
        await contribute(u.id, circle.id);

        // Double-contribution guard (checked once, in round 1, on the first
        // member): a second contribution in the same round must be rejected and
        // must not create a second contribution row.
        if (round === 1 && i === 0) {
          await assert.rejects(
            () => contribute(u.id, circle.id),
            /already contributed this round/i,
            "a member must not contribute twice in the same round",
          );
          const rows = await db
            .select()
            .from(contributionsTable)
            .where(
              and(
                eq(contributionsTable.circleId, circle.id),
                eq(contributionsTable.userId, u.id),
                eq(contributionsTable.round, round),
              ),
            );
          assert.equal(rows.length, 1, "exactly one contribution row per member per round");
        }
      }
    }

    const after = await getCircleDetail(creator.id, circle.id);

    if (!isFinal) {
      // Accumulation has NO per-round recipient: nobody is paid before the end.
      // Each member is down exactly one contribution; the pool holds the rest.
      for (const u of members) {
        assert.equal(
          (balancesBefore.get(u.id) ?? 0) - (await accountBalance(acct.wallet(u.id))),
          CONTRIBUTION_CENTS,
          `round ${round}: member only loses their contribution, no early payout`,
        );
        assert.equal(
          await payoutTxnCountForWallet(u.id),
          0,
          `round ${round}: no payout should land before the final round`,
        );
      }
      assert.equal(
        await accountBalance(acct.pool(circle.id)),
        CONTRIBUTION_CENTS * n * round,
        `round ${round}: pool accumulates every member's savings`,
      );
      assert.equal(after?.currentRound, round + 1, "round should advance by exactly one");
      assert.equal(after?.status, "active", "circle stays active mid-accumulation");
    } else {
      // Final round: each member nets (savings back − this round's contribution)
      // and receives exactly one payout.
      for (const u of members) {
        assert.equal(
          (await accountBalance(acct.wallet(u.id))) - (balancesBefore.get(u.id) ?? 0),
          SHARE_CENTS - CONTRIBUTION_CENTS,
          "final round: member gets their savings back minus this round's contribution",
        );
        assert.equal(
          await payoutTxnCountForWallet(u.id),
          1,
          "final round: each member is paid back exactly once (no double-pay under concurrency)",
        );
      }
      assert.equal(after?.status, "completed", "circle completes after the final round");
      assert.equal(after?.currentRound, NUM_ROUNDS, "completed circle rests on the final round");
    }
  }

  // --- Whole-circle invariants ------------------------------------------
  assert.equal(
    await payoutTxnCountForPool(circle.id),
    n,
    "exactly one payout per member at the end, no double-pays",
  );
  assert.equal(await accountBalance(acct.pool(circle.id)), 0, "the pool is fully disbursed");
  for (const u of members) {
    assert.equal(
      await accountBalance(acct.wallet(u.id)),
      DEPOSIT_CENTS,
      "every member is net-zero: they get back exactly what they saved",
    );
    assert.equal(await payoutTxnCountForWallet(u.id), 1, "every member is paid back exactly once");
  }
}

let failed = false;
try {
  await run();
  console.log(`\n✓ Susu accumulation circle e2e passed (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu accumulation circle e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await pool.end();
}

process.exit(failed ? 1 : 0);
