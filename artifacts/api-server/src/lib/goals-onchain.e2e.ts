/**
 * On-chain end-to-end test: a savings Goal settled through the REAL Base Sepolia
 * GoalVault contract (+ MockUSDC).
 *
 * Unlike an offline ledger test, this keeps on-chain settlement ENABLED and
 * drives the actual reconciler so every economic step is mirrored on-chain and
 * verifiable on Basescan:
 *
 *   faucet-mint MockUSDC -> allocate to goal (approve + deposit into the vault,
 *   FREE) -> partial release (withdraw gross; the vault sends net and routes the
 *   2% fee to the treasury in one tx) -> delete goal (auto-withdraw the full
 *   remaining balance net of the fee, then soft-delete).
 *
 * It requires a funded platform wallet (gas) and a reachable RPC. If either is
 * missing it SKIPS (exit 0) rather than failing, so it never blocks CI on a
 * cold testnet.
 *
 * Run: pnpm --filter @workspace/api-server test:goals-onchain
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

// On-chain must stay ON, but disable transactional email so the test sends no
// real messages. email.ts snapshots the Resend key at import, so clear it first.
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, goalsTable, transactionsTable, ledgerAccountsTable, postingsTable, onchainTransfersTable } =
  await import("@workspace/db");
const { eq, and, inArray, or } = await import("drizzle-orm");
const { createWalletForUser, getWalletForUser } = await import("./wallet");
const { acct, transfer, accountBalance, goalBalances } = await import("./ledger");
const { onchainEnabled, goalVaultEnabled, goalVaultContract, goalVaultBalance, isValidAddress, usdcBalance, mintUsdc, ensureGas, platformBalances, explorerUrl } =
  await import("./chain");
const { runReconciler } = await import("./settlement");
const { createGoal, allocateToGoal, releaseFromGoal, deleteGoal, getGoal, listGoals } =
  await import("./goals");

const runId = randomUUID().slice(0, 8);
const FAUCET_CENTS = 400; // mint plenty of MockUSDC
const ALLOCATE_CENTS = 200; // $2.00 allocated into the goal
const RELEASE_CENTS = 100; // $1.00 partial release
const EXPLORER = explorerUrl();

type TestUser = { id: string; email: string; name: string };

let goalId: string | null = null;
const users: TestUser[] = [];

async function makeUser(label: string): Promise<TestUser> {
  const email = `e2e-goal-onchain+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `E2E ${label} ${runId}`, email }).returning();
  await createWalletForUser(u.id);
  const tu = { id: u.id, email: u.email, name: u.name };
  users.push(tu);
  return tu;
}

/** Count this goal's pending goal_deposit/goal_withdraw rows. */
async function pendingGoalRows(gId: string): Promise<number> {
  const all = await db
    .select({ memo: onchainTransfersTable.memo })
    .from(onchainTransfersTable)
    .where(
      and(
        inArray(onchainTransfersTable.kind, ["goal_deposit", "goal_withdraw"]),
        or(eq(onchainTransfersTable.status, "pending"), eq(onchainTransfersTable.status, "processing")),
      ),
    );
  return all.filter((r) => (r.memo ?? "").startsWith(`goal:${gId}`)).length;
}

/** Drive the reconciler until this goal's queue rows are all settled (or budget elapses). */
async function settleGoal(gId: string, budgetMs = 90_000): Promise<void> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    await runReconciler();
    if ((await pendingGoalRows(gId)) === 0) return;
    await new Promise((r) => setTimeout(r, 2000));
  }
}

async function cleanup() {
  try {
    const keys = [
      ...users.map((u) => acct.wallet(u.id)),
      ...(goalId ? [acct.goal(goalId)] : []),
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
    if (goalId) await db.delete(goalsTable).where(eq(goalsTable.id, goalId));
    if (users.length) {
      await db.delete(usersTable).where(inArray(usersTable.id, users.map((u) => u.id)));
    }
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
}

async function run(): Promise<"ran" | "skipped"> {
  if (!onchainEnabled() || !goalVaultEnabled()) {
    console.log("· on-chain or goal vault not configured — skipping on-chain e2e");
    return "skipped";
  }
  const pb = await platformBalances();
  if (!pb.reachable || BigInt(pb.ethWei ?? "0") === 0n) {
    console.log(`· platform wallet unfunded/unreachable (eth=${pb.ethFormatted}) — skipping on-chain e2e`);
    return "skipped";
  }
  const vault = goalVaultContract();
  console.log(`· platform ${pb.address} funded with ${pb.ethFormatted} ETH; vault ${EXPLORER}/address/${vault}`);

  // --- Setup: one saver, funded with MockUSDC on-chain --------------------
  const saver = await makeUser("saver");
  const w = await getWalletForUser(saver.id);
  assert.ok(w, "saver wallet provisioned");
  const mint = await mintUsdc({ to: w!.address, amountCents: FAUCET_CENTS });
  assert.equal(mint.status, "confirmed", `MockUSDC mint should confirm: ${JSON.stringify(mint)}`);
  await ensureGas(w!.address);
  let onchain = 0;
  for (let i = 0; i < 8; i++) {
    onchain = await usdcBalance(w!.address);
    if (onchain >= ALLOCATE_CENTS) break;
    await new Promise((r) => setTimeout(r, 1500));
  }
  assert.ok(onchain >= ALLOCATE_CENTS, `saver must hold minted MockUSDC on-chain (got ${onchain}c)`);
  // Mirror the credit in the ledger so allocate()'s balance check passes.
  await transfer({
    type: "deposit",
    description: "Test USDC (on-chain goal e2e funding)",
    userId: saver.id,
    fromKey: acct.external,
    toKey: acct.wallet(saver.id),
    amountCents: FAUCET_CENTS,
    onchain: { onchainStatus: "none" },
  });

  // --- Create the goal ----------------------------------------------------
  const goal = await createGoal(saver.id, {
    name: `E2E Goal ${runId}`,
    targetCents: 100_000,
    deadline: new Date(Date.now() + 90 * 24 * 3600 * 1000),
  });
  goalId = goal.id;
  assert.equal(goal.onchain, true, "created goal should report on-chain enabled");
  assert.ok(goal.vaultAddress && isValidAddress(goal.vaultAddress), "goal exposes a valid vault address");
  assert.ok((goal.feeBps ?? 0) > 0, "on-chain goal exposes a non-zero feeBps");

  // --- Allocate (free deposit into the vault) -----------------------------
  await allocateToGoal(saver.id, goal.id, ALLOCATE_CENTS);
  await settleGoal(goal.id);

  const afterAlloc = await getGoal(saver.id, goal.id);
  assert.ok(afterAlloc, "goal still active after allocate");
  assert.equal(afterAlloc!.savedCents, ALLOCATE_CENTS, "ledger goal balance equals allocation");
  const depositRow = (afterAlloc!.history ?? []).find((h) => h.type === "goal_allocate");
  assert.ok(depositRow, "allocation appears in history");
  assert.equal(depositRow!.onchainStatus, "confirmed", "deposit confirmed on-chain");
  assert.ok(depositRow!.txHash, "deposit carries an on-chain tx hash");
  console.log(`· deposit tx: ${EXPLORER}/tx/${depositRow!.txHash}`);

  // On-chain vault balance mirrors the allocation (no fee on deposit).
  let vaultBal = 0;
  for (let i = 0; i < 8; i++) {
    vaultBal = await goalVaultBalance(w!.address, goal.id);
    if (vaultBal >= ALLOCATE_CENTS) break;
    await new Promise((r) => setTimeout(r, 1500));
  }
  assert.ok(vaultBal >= ALLOCATE_CENTS, `on-chain vault balance should reflect deposit (got ${vaultBal}c)`);

  // --- Partial release (charges the 2% fee on-chain) ----------------------
  const walletBefore = await accountBalance(acct.wallet(saver.id));
  const release = await releaseFromGoal(saver.id, goal.id, RELEASE_CENTS);
  assert.equal(release.grossCents, RELEASE_CENTS, "release gross equals requested");
  assert.ok(release.feeCents > 0, "release charges a non-zero fee");
  assert.equal(release.netCents, RELEASE_CENTS - release.feeCents, "net = gross - fee");
  await settleGoal(goal.id);

  // The ledger booked net to the wallet and fee to platform fees.
  const walletAfter = await accountBalance(acct.wallet(saver.id));
  assert.equal(walletAfter - walletBefore, release.netCents, "wallet credited the net amount");
  const balancesAfterRelease = await goalBalances(saver.id);
  assert.equal(
    balancesAfterRelease[goal.id] ?? 0,
    ALLOCATE_CENTS - RELEASE_CENTS,
    "goal balance reduced by the full gross",
  );

  const afterRelease = await getGoal(saver.id, goal.id);
  const releaseRow = (afterRelease!.history ?? []).find((h) => h.type === "goal_release");
  assert.ok(releaseRow, "release appears in history");
  assert.equal(releaseRow!.onchainStatus, "confirmed", "release confirmed on-chain");
  assert.ok(releaseRow!.txHash, "release carries the settlement tx hash");
  const feeRow = (afterRelease!.history ?? []).find((h) => h.type === "fee");
  assert.ok(feeRow, "fee row mirrors the on-chain withdrawal fee");
  assert.equal(feeRow!.onchainStatus, "confirmed", "fee confirmed alongside the release");
  assert.equal(feeRow!.txHash, releaseRow!.txHash, "fee shares the release settlement tx");
  console.log(`· release tx: ${EXPLORER}/tx/${releaseRow!.txHash} (fee ${release.feeCents}c)`);

  // --- Delete the goal (auto-withdraw the remaining balance net of fee) ----
  const remainingBefore = balancesAfterRelease[goal.id] ?? 0;
  const walletBeforeDelete = await accountBalance(acct.wallet(saver.id));
  const del = await deleteGoal(saver.id, goal.id);
  assert.equal(del.ok, true, "delete reports ok");
  assert.equal(del.withdrawnGrossCents, remainingBefore, "delete withdraws the full remaining balance");
  assert.ok(del.feeCents > 0, "delete charges a withdrawal fee on the remaining balance");
  assert.equal(del.withdrawnNetCents, remainingBefore - del.feeCents, "delete net = remaining - fee");
  await settleGoal(goal.id);

  const walletAfterDelete = await accountBalance(acct.wallet(saver.id));
  assert.equal(
    walletAfterDelete - walletBeforeDelete,
    del.withdrawnNetCents,
    "wallet credited the net of the auto-withdraw",
  );

  // Soft-deleted: gone from listings and getGoal, balance drained.
  const stillThere = await getGoal(saver.id, goal.id);
  assert.equal(stillThere, null, "deleted goal not returned by getGoal");
  const list = await listGoals(saver.id);
  assert.ok(!list.some((g) => g.id === goal.id), "deleted goal not in listGoals");
  const balancesFinal = await goalBalances(saver.id);
  assert.equal(balancesFinal[goal.id] ?? 0, 0, "goal balance fully drained after delete");
  console.log(`· goal deleted; ${del.withdrawnNetCents}c returned net of ${del.feeCents}c fee`);

  return "ran";
}

let failed = false;
let outcome: "ran" | "skipped" = "skipped";
try {
  outcome = await run();
  if (outcome === "ran") {
    console.log(`\n✓ Goal ON-CHAIN e2e passed (runId=${runId})`);
  } else {
    console.log(`\n· Goal ON-CHAIN e2e skipped (runId=${runId})`);
  }
} catch (e) {
  failed = true;
  console.error(`\n✗ Goal ON-CHAIN e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await pool.end();
}

process.exit(failed ? 1 : 0);
