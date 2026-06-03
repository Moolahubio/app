/**
 * End-to-end test: the full Susu circle "save together" rotation.
 *
 * Exercises the real circle lifecycle against a real database, using the same
 * library functions the HTTP routes call (routes are thin wrappers around
 * `lib/circles`):
 *
 *   create -> invite -> accept -> start -> every member contributes a round ->
 *   the pot pays out to the round's recipient -> the round advances by one,
 *   repeated until the rotation completes.
 *
 * It asserts the payout / round-advance behaviour that was hardened against
 * double-pay and double-advance races:
 *   - exactly one payout lands in each round's correct recipient wallet,
 *   - the round advances exactly once per filled round (no skips/double-advance),
 *   - a member cannot contribute twice in the same round (the unique
 *     (circle_id, user_id, round) constraint),
 *   - the pot is fully disbursed and every member is net-zero after a full
 *     rotation (each pays N contributions and receives the pot once).
 *
 * Scope: on-chain USDC settlement is intentionally OUT of scope here. It is an
 * out-of-band queue + reconciler concern (covered by separate work). We disable
 * it (and transactional email) BEFORE importing any module so the test is
 * deterministic and fully offline — the double-entry ledger postings, which
 * drive payouts and balances, are identical either way.
 *
 * Run: pnpm --filter @workspace/api-server test:susu
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
const DEPOSIT_CENTS = 5000; // plenty to cover every round

type TestUser = { id: string; email: string; name: string };

let circleId: string | null = null;
const users: TestUser[] = [];

async function makeUser(label: string): Promise<TestUser> {
  const email = `e2e+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `E2E ${label} ${runId}`, email }).returning();
  await createWalletForUser(u.id);
  const tu = { id: u.id, email: u.email, name: u.name };
  users.push(tu);
  return tu;
}

async function cleanup() {
  try {
    // Delete every transaction that touched the test wallets or the circle pot;
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
  const creator = await makeUser("creator");
  const m2 = await makeUser("m2");
  const m3 = await makeUser("m3");
  const members = [creator, m2, m3];
  const n = members.length;
  const pot = CONTRIBUTION_CENTS * n;

  for (const u of members) await faucetDeposit(u.id, DEPOSIT_CENTS);
  for (const u of members) {
    assert.equal(await accountBalance(acct.wallet(u.id)), DEPOSIT_CENTS, "faucet should fund each member");
  }

  // --- Create -> invite -> accept ---------------------------------------
  const circle = await createCircle(creator.id, {
    name: `E2E Susu ${runId}`,
    contributionCents: CONTRIBUTION_CENTS,
    frequency: "monthly",
  });
  circleId = circle.id;

  for (const u of [m2, m3]) {
    await inviteToCircle(creator.id, circle.id, u.email);
    const invites = await listInvitesForUser(u.email);
    const invite = invites.find((i) => i.circleName === circle.name);
    assert.ok(invite, `pending invite for ${u.email} should exist`);
    await acceptInvite(u.id, u.email, invite.id);
  }

  // --- Start: rotation locks to members.length rounds --------------------
  await startCircle(creator.id, circle.id);
  const started = await getCircleDetail(creator.id, circle.id);
  assert.equal(started?.status, "active", "circle should be active after start");
  assert.equal(started?.currentRound, 1, "first round should be 1");
  assert.equal(started?.totalRounds, n, "total rounds should equal member count");
  assert.equal(started?.memberCount, n, "all members should be present");

  // --- Run every round ---------------------------------------------------
  for (let round = 1; round <= n; round++) {
    const before = await getCircleDetail(creator.id, circle.id);
    assert.equal(before?.currentRound, round, `should be on round ${round}`);

    // Recipient is the member whose payoutRound matches this round.
    const [recipientMember] = await db
      .select()
      .from(circleMembersTable)
      .where(and(eq(circleMembersTable.circleId, circle.id), eq(circleMembersTable.payoutRound, round)));
    assert.ok(recipientMember, `round ${round} should have a recipient`);
    const recipientId = recipientMember.userId;
    const recipientBefore = await accountBalance(acct.wallet(recipientId));

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

    // The pot paid out to exactly this round's recipient (received pot, paid
    // their own contribution): net change is pot - contribution.
    const recipientAfter = await accountBalance(acct.wallet(recipientId));
    assert.equal(
      recipientAfter - recipientBefore,
      pot - CONTRIBUTION_CENTS,
      `round ${round} recipient should net the pot minus their own contribution`,
    );
    assert.equal(
      await payoutTxnCountForWallet(recipientId),
      1,
      `round ${round} recipient should have received exactly one payout`,
    );

    // The round advanced exactly once (no skip / double-advance).
    const after = await getCircleDetail(creator.id, circle.id);
    if (round < n) {
      assert.equal(after?.currentRound, round + 1, "round should advance by exactly one");
      assert.equal(after?.status, "active", "circle stays active mid-rotation");
    } else {
      assert.equal(after?.status, "completed", "circle completes after the final round");
      assert.equal(after?.currentRound, n, "completed circle rests on the final round");
    }
  }

  // --- Whole-rotation invariants ----------------------------------------
  assert.equal(await payoutTxnCountForPool(circle.id), n, "exactly one payout per round, no double-pays");
  assert.equal(await accountBalance(acct.pool(circle.id)), 0, "the pot is fully disbursed");
  for (const u of members) {
    assert.equal(
      await accountBalance(acct.wallet(u.id)),
      DEPOSIT_CENTS,
      "every member is net-zero after a full rotation",
    );
    assert.equal(await payoutTxnCountForWallet(u.id), 1, "every member receives the pot exactly once");
  }
}

let failed = false;
try {
  await run();
  console.log(`\n✓ Susu circle save-together e2e passed (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu circle save-together e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await pool.end();
}

process.exit(failed ? 1 : 0);
