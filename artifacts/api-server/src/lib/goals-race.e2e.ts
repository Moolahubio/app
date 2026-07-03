/**
 * Offline concurrency test for the goal delete-vs-allocate race (funds-stranding
 * hardening).
 *
 * The vulnerability: allocateToGoal() validated the goal's `active` status only
 * BEFORE its transaction, so a concurrent deleteGoal() could flip the goal to
 * `deleted`, drain it, and return — and then the stale allocation would still
 * commit wallet -> goal funds (and, on-chain, enqueue a goal_deposit) into the
 * now-closed goal. Because every read/withdraw path requires status = active and
 * there is no recovery API, those funds are permanently stranded.
 *
 * The fix: allocateToGoal() re-reads the goal row FOR UPDATE and re-checks
 * status = active INSIDE its transaction, serializing against deleteGoal()'s
 * compare-and-set flip (which takes the same row lock).
 *
 * This suite runs OFFLINE (ledger-only, no vault, no fee, no email) so the
 * invariants are deterministic:
 *   1. deterministic "delete wins" — force the exact race by holding a delete's
 *      active->deleted flip open (uncommitted, row-locked) while an allocation
 *      that already passed its pre-check blocks on the row lock; committing the
 *      flip must make the allocation fail and strand nothing.
 *   2. concurrent stress — fire allocate | delete in parallel many times; whoever
 *      wins, the goal always ends deleted with a zero balance and the wallet is
 *      fully restored (no fee offline), so no funds are ever stranded.
 *
 * Run: pnpm --filter @workspace/api-server test:goals-race
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

// OFFLINE + no email. chain.ts snapshots USDC_CONTRACT_ADDRESS at import and
// email.ts snapshots RESEND_API_KEY at import, so clear them BEFORE importing.
delete process.env.USDC_CONTRACT_ADDRESS;
delete process.env.PLATFORM_PRIVATE_KEY;
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, goalsTable, transactionsTable, ledgerAccountsTable, postingsTable } =
  await import("@workspace/db");
const { eq, and, inArray } = await import("drizzle-orm");
const { createWalletForUser } = await import("./wallet");
const { acct, transfer, accountBalance } = await import("./ledger");
const { goalVaultEnabled } = await import("./chain");
const { createGoal, allocateToGoal, deleteGoal, getGoal } = await import("./goals");

const ACTIVE = "active";
const DELETED = "deleted";

const runId = randomUUID().slice(0, 8);
const START_CENTS = 100_00; // $100 available in the wallet ledger
const ALLOC_CENTS = 2_00; // $2 per allocation attempt

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

let userId: string | null = null;
const goalIds: string[] = [];

async function makeUser(): Promise<string> {
  const email = `e2e-goal-race+${runId}@moolahub.test`;
  const [u] = await db
    .insert(usersTable)
    .values({ name: `E2E race ${runId}`, email })
    .returning();
  await createWalletForUser(u.id);
  // Fund the wallet in the ledger (offline: the ledger balance is spendable).
  await transfer({
    type: "deposit",
    description: "Test funding (goal race e2e)",
    userId: u.id,
    fromKey: acct.external,
    toKey: acct.wallet(u.id),
    amountCents: START_CENTS,
    onchain: { onchainStatus: "none" },
  });
  userId = u.id;
  return u.id;
}

async function makeGoal(uid: string): Promise<string> {
  const g = await createGoal(uid, {
    name: `Race goal ${runId}-${goalIds.length}`,
    targetCents: 1_000_00,
    deadline: new Date(Date.now() + 90 * 24 * 3600 * 1000),
  });
  goalIds.push(g.id);
  return g.id;
}

/**
 * Deterministically reproduce the dangerous interleaving: a delete flips the
 * goal active->deleted first (holding the row lock), then a stale allocation
 * that already passed its pre-check tries to commit into it. The fix must reject
 * the allocation instead of stranding the funds.
 */
async function deterministicDeleteWins(uid: string): Promise<void> {
  const gId = await makeGoal(uid);
  const walletBefore = await accountBalance(acct.wallet(uid));

  // Hold a delete's active->deleted flip open: the row is claimed and locked but
  // the transaction has not committed, so other connections still read `active`.
  // `flipLocked` fires once the row lock is actually held so we can start the
  // allocation only after the flip owns the lock (otherwise the allocation could
  // legitimately win the lock first — a different, safe ordering).
  let flipLocked!: () => void;
  const flipLockedP = new Promise<void>((resolve) => {
    flipLocked = resolve;
  });
  let commitFlip!: () => void;
  const flipHeld = new Promise<void>((resolve) => {
    commitFlip = resolve;
  });
  const delTx = db.transaction(async (tx) => {
    const [row] = await tx
      .update(goalsTable)
      .set({ status: DELETED })
      .where(
        and(eq(goalsTable.id, gId), eq(goalsTable.userId, uid), eq(goalsTable.status, ACTIVE)),
      )
      .returning();
    assert.ok(row, "manual flip claimed the active goal");
    flipLocked(); // row lock now held (uncommitted)
    await flipHeld; // keep the tx open → row lock held until we commit
  });
  await flipLockedP; // ensure the flip owns the row lock before allocating

  // Start the allocation. Its pre-check reads the still-committed `active` row,
  // then it blocks on SELECT ... FOR UPDATE behind the held flip.
  const allocResult: Promise<{ ok: true } | { ok: false; err: Error }> = allocateToGoal(
    uid,
    gId,
    ALLOC_CENTS,
  ).then(
    () => ({ ok: true as const }),
    (e: unknown) => ({ ok: false as const, err: e as Error }),
  );

  await sleep(400); // give allocate time to reach and block on the row lock
  commitFlip(); // commit the delete flip → goal is now durably `deleted`
  await delTx;

  const res = await allocResult;
  assert.equal(res.ok, false, "allocation into a concurrently-deleted goal must be rejected");
  if (!res.ok) {
    assert.match(res.err.message, /Goal not found/, "rejection reason is 'Goal not found'");
  }

  // Nothing moved: the deleted goal holds no balance and the wallet is untouched.
  assert.equal(await accountBalance(acct.goal(gId)), 0, "no funds stranded in the deleted goal");
  assert.equal(
    await accountBalance(acct.wallet(uid)),
    walletBefore,
    "wallet balance unchanged by the rejected allocation",
  );
  assert.equal(await getGoal(uid, gId), null, "goal is deleted (not visible via getGoal)");
  console.log("· deterministic delete-wins: allocation rejected, zero funds stranded ✓");
}

/**
 * The safe reverse ordering: the allocation wins the row lock first (commits its
 * funds), then the delete — serialized behind it — must drain those funds back
 * to the wallet instead of leaving them behind. We control the lock queue with a
 * no-op FOR UPDATE hold: start the allocation waiting first, then the delete, so
 * on release the allocation is granted the lock before the delete.
 */
async function deterministicAllocateWins(uid: string): Promise<void> {
  const gId = await makeGoal(uid);
  const walletBefore = await accountBalance(acct.wallet(uid));

  let lockAcquired!: () => void;
  const lockAcquiredP = new Promise<void>((resolve) => {
    lockAcquired = resolve;
  });
  let releaseLock!: () => void;
  const lockHeld = new Promise<void>((resolve) => {
    releaseLock = resolve;
  });
  const holdTx = db.transaction(async (tx) => {
    await tx.select().from(goalsTable).where(eq(goalsTable.id, gId)).for("update");
    lockAcquired();
    await lockHeld;
  });
  await lockAcquiredP; // the goal row is now locked by our no-op holder

  // Queue the allocation as the FIRST waiter, then the delete as the second.
  // Postgres grants row-lock waiters in arrival order, so on release the
  // allocation acquires the lock first and commits, then the delete drains it.
  const allocP: Promise<{ ok: true } | { ok: false; err: Error }> = allocateToGoal(
    uid,
    gId,
    ALLOC_CENTS,
  ).then(
    () => ({ ok: true as const }),
    (e: unknown) => ({ ok: false as const, err: e as Error }),
  );
  await sleep(300); // let the allocation become the first waiter on the row lock
  const delP = deleteGoal(uid, gId);
  await sleep(200); // let the delete queue behind the allocation

  releaseLock();
  await holdTx;

  const allocRes = await allocP;
  await delP;

  assert.equal(allocRes.ok, true, "allocation that won the row lock should commit");
  // Serialized after the allocation, the delete drains the just-added funds:
  // nothing is stranded and the wallet is made whole (offline → no fee).
  assert.equal(
    await accountBalance(acct.goal(gId)),
    0,
    "delete drained the allocated funds — nothing stranded",
  );
  assert.equal(
    await accountBalance(acct.wallet(uid)),
    walletBefore,
    "wallet fully restored after allocate-then-drain",
  );
  assert.equal(await getGoal(uid, gId), null, "goal is deleted");
  console.log("· deterministic allocate-wins: allocation committed then fully drained by delete ✓");
}

/**
 * Fire allocate | delete in parallel repeatedly. Whoever wins the row lock, the
 * end state must always be: goal deleted, goal balance 0, wallet fully restored.
 */
async function concurrentStress(uid: string, iterations = 25): Promise<void> {
  let allocOk = 0;
  let allocRejected = 0;
  for (let i = 0; i < iterations; i++) {
    const gId = await makeGoal(uid);
    const walletBefore = await accountBalance(acct.wallet(uid));

    const [alloc, del] = await Promise.allSettled([
      allocateToGoal(uid, gId, ALLOC_CENTS),
      deleteGoal(uid, gId),
    ]);

    // Deleting a fresh, settle-free goal must always succeed.
    assert.equal(del.status, "fulfilled", `iter ${i}: delete should succeed`);
    if (alloc.status === "fulfilled") allocOk++;
    else allocRejected++;

    // Invariant independent of who won: no stranded funds, wallet made whole.
    assert.equal(
      await accountBalance(acct.goal(gId)),
      0,
      `iter ${i}: goal drained — nothing stranded`,
    );
    assert.equal(
      await accountBalance(acct.wallet(uid)),
      walletBefore,
      `iter ${i}: wallet fully restored (offline → no fee)`,
    );
    assert.equal(await getGoal(uid, gId), null, `iter ${i}: goal is deleted`);
  }
  console.log(
    `· concurrent stress: ${iterations} allocate|delete races (allocate landed ${allocOk}, rejected ${allocRejected}); no funds ever stranded ✓`,
  );
}

async function cleanup(): Promise<void> {
  try {
    const keys = [
      ...(userId ? [acct.wallet(userId)] : []),
      ...goalIds.map((g) => acct.goal(g)),
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
    if (goalIds.length) {
      await db.delete(goalsTable).where(inArray(goalsTable.id, goalIds));
    }
    if (userId) {
      await db.delete(usersTable).where(eq(usersTable.id, userId));
    }
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
}

let failed = false;
try {
  assert.equal(
    goalVaultEnabled(),
    false,
    "test must run offline (vault disabled) for deterministic ledger assertions",
  );
  const uid = await makeUser();
  await deterministicDeleteWins(uid);
  await deterministicAllocateWins(uid);
  await concurrentStress(uid);
  console.log(`\n✓ Goal delete-vs-allocate race e2e passed (runId=${runId})`);
} catch (e) {
  failed = true;
  console.error(`\n✗ Goal delete-vs-allocate race e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await pool.end();
}

process.exit(failed ? 1 : 0);
