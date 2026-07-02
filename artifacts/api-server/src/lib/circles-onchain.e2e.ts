/**
 * On-chain end-to-end test: a rotation Susu circle settled through the REAL
 * Monad Testnet escrow contracts (CircleFactory + Susu escrow + MockUSDC).
 *
 * Unlike `circles.e2e.ts` (which runs fully offline against the ledger), this
 * test keeps on-chain settlement ENABLED and drives the actual reconciler so
 * every economic step is mirrored on-chain and verifiable on the Monad explorer:
 *
 *   faucet-mint MockUSDC -> deploy escrow via factory on startCircle ->
 *   each member contributes (approve + contribute) into the escrow ->
 *   the escrow auto-settles the round on the last contribution (RoundSettled) ->
 *   the matching ledger payout/fee rows are stamped confirmed with that tx hash.
 *
 * It requires a funded platform wallet (gas) and a reachable RPC. If either is
 * missing it SKIPS (exit 0) rather than failing, so it never blocks CI on a
 * cold testnet — the offline suite already guards the ledger invariants.
 *
 * Run: pnpm --filter @workspace/api-server test:susu-onchain
 */
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

// Keep USDC_CONTRACT_ADDRESS and PLATFORM_PRIVATE_KEY (on-chain must stay ON),
// but disable transactional email so the test sends no real messages. email.ts
// snapshots the Resend key at import, so clear it before the dynamic imports.
delete process.env.RESEND_API_KEY;

const { db, pool, usersTable, circlesTable, circleMembersTable, transactionsTable, ledgerAccountsTable, postingsTable, onchainTransfersTable } =
  await import("@workspace/db");
const { eq, and, inArray, or } = await import("drizzle-orm");
const { createWalletForUser, getWalletForUser } = await import("./wallet");
const { acct, transfer } = await import("./ledger");
const { onchainEnabled, escrowEnabled, isValidAddress, usdcBalance, mintUsdc, ensureGas, platformBalances, explorerUrl } =
  await import("./chain");
const { runReconciler } = await import("./settlement");
const { createCircle, inviteToCircle, listInvitesForUser, acceptInvite, startCircle, contribute, getCircleDetail } =
  await import("./circles");

const runId = randomUUID().slice(0, 8);
const CONTRIBUTION_CENTS = 50; // $0.50 per round — keep testnet spend tiny
const FAUCET_CENTS = 200; // mint plenty of MockUSDC to cover contributions
const EXPLORER = explorerUrl();

type TestUser = { id: string; email: string; name: string };

let circleId: string | null = null;
const users: TestUser[] = [];

async function makeUser(label: string): Promise<TestUser> {
  const email = `e2e-onchain+${label}+${runId}@moolahub.test`;
  const [u] = await db.insert(usersTable).values({ name: `E2E ${label} ${runId}`, email }).returning();
  await createWalletForUser(u.id);
  const tu = { id: u.id, email: u.email, name: u.name };
  users.push(tu);
  return tu;
}

/** Count this circle's escrow_contribute rows still awaiting settlement. */
async function pendingEscrowRows(cId: string): Promise<number> {
  // Memo is `susu:<circleId>:<round>`; filter the prefix in memory since the
  // query layer has no prefix match for our needs here.
  const all = await db
    .select({ memo: onchainTransfersTable.memo })
    .from(onchainTransfersTable)
    .where(
      and(
        eq(onchainTransfersTable.kind, "escrow_contribute"),
        or(eq(onchainTransfersTable.status, "pending"), eq(onchainTransfersTable.status, "processing")),
      ),
    );
  return all.filter((r) => (r.memo ?? "").startsWith(`susu:${cId}:`)).length;
}

/**
 * Drive the reconciler until this circle's escrow rows are all settled (or a
 * time budget elapses). Polls the DB rather than trusting runReconciler's return
 * value, which can no-op when a background `kickReconciler` already holds the
 * single-flight `running` guard. Tolerates the 30s requeue backoff on a flaky
 * testnet tx by simply continuing to poll.
 */
async function settleCircle(cId: string, budgetMs = 90_000): Promise<void> {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    await runReconciler();
    if ((await pendingEscrowRows(cId)) === 0) return;
    await new Promise((r) => setTimeout(r, 2000));
  }
}

async function cleanup() {
  try {
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
    if (circleId) await db.delete(circlesTable).where(eq(circlesTable.id, circleId));
    if (users.length) {
      await db.delete(usersTable).where(inArray(usersTable.id, users.map((u) => u.id)));
    }
  } catch (e) {
    console.error("[cleanup] failed:", e);
  }
}

async function run(): Promise<"ran" | "skipped"> {
  if (!onchainEnabled() || !escrowEnabled()) {
    console.log("· on-chain or escrow not configured — skipping on-chain e2e");
    return "skipped";
  }
  const pb = await platformBalances();
  if (!pb.reachable || BigInt(pb.ethWei ?? "0") === 0n) {
    console.log(`· platform wallet unfunded/unreachable (eth=${pb.ethFormatted}) — skipping on-chain e2e`);
    return "skipped";
  }
  console.log(`· platform ${pb.address} funded with ${pb.ethFormatted} ETH; running on-chain flow`);

  // --- Setup: two members, funded with MockUSDC on-chain ------------------
  // Fund on-chain directly (awaited, sequential nonces) for determinism, and
  // mirror the credit in the ledger so contribute()'s balance check passes.
  // This is the same mint the faucet enqueues, just driven synchronously.
  const creator = await makeUser("creator");
  const m2 = await makeUser("m2");
  const members = [creator, m2];
  const n = members.length;

  for (const u of members) {
    const w = await getWalletForUser(u.id);
    assert.ok(w, "member wallet provisioned");
    const mint = await mintUsdc({ to: w!.address, amountCents: FAUCET_CENTS });
    assert.equal(mint.status, "confirmed", `MockUSDC mint to ${u.name} should confirm: ${JSON.stringify(mint)}`);
    // Pre-fund gas synchronously while the live reconciler is idle (no escrow
    // rows yet). With members already holding gas, settlement's ensureGas
    // no-ops, so no platform-wallet sends happen during the round — which keeps
    // this test process and the running API-server reconciler from colliding on
    // the shared platform-wallet nonce.
    await ensureGas(w!.address);
    // The public RPC is load-balanced; a balance read right after the mint
    // receipt can hit a lagging node and report 0. Poll until it catches up.
    let onchain = 0;
    for (let i = 0; i < 8; i++) {
      onchain = await usdcBalance(w!.address);
      if (onchain >= CONTRIBUTION_CENTS) break;
      await new Promise((r) => setTimeout(r, 1500));
    }
    assert.ok(
      onchain >= CONTRIBUTION_CENTS,
      `member ${u.name} must hold minted MockUSDC on-chain (got ${onchain}c)`,
    );
    await transfer({
      type: "deposit",
      description: "Test USDC (on-chain e2e funding)",
      userId: u.id,
      fromKey: acct.external,
      toKey: acct.wallet(u.id),
      amountCents: FAUCET_CENTS,
      onchain: { onchainStatus: "none" },
    });
  }

  // --- Create -> invite -> accept -> start (deploys the escrow) -----------
  const circle = await createCircle(creator.id, {
    name: `E2E Onchain ${runId}`,
    contributionCents: CONTRIBUTION_CENTS,
    frequency: "monthly",
  });
  circleId = circle.id;

  await inviteToCircle(creator.id, circle.id, m2.email);
  const invites = await listInvitesForUser(m2.email);
  const invite = invites.find((i) => i.circleName === circle.name);
  assert.ok(invite, "pending invite should exist");
  await acceptInvite(m2.id, m2.email, invite!.id);

  await startCircle(creator.id, circle.id);
  const started = await getCircleDetail(creator.id, circle.id);
  assert.equal(started?.status, "active", "circle active after start");
  assert.equal(started?.totalRounds, n, "rounds equal member count");
  assert.ok(started?.contractAddress, "rotation circle must have a deployed escrow address");
  assert.ok(isValidAddress(started!.contractAddress!), "escrow address must be a valid address");
  console.log(`· escrow deployed: ${EXPLORER}/address/${started!.contractAddress}`);

  // --- Round 1: every member contributes; the escrow settles the round ----
  for (const u of members) await contribute(u.id, circle.id);
  await settleCircle(circle.id);

  // Every contribution is recorded on-chain with a tx hash visible in history.
  const detail = await getCircleDetail(creator.id, circle.id);
  const round1 = (detail?.history ?? []).filter((h) => h.round === 1);
  assert.ok(round1.length >= 1, "creator should have a round-1 contribution in history");
  for (const h of round1) {
    assert.ok(h.txHash, `round-1 contribution ${h.id} must carry an on-chain tx hash`);
    console.log(`· contribution tx: ${EXPLORER}/tx/${h.txHash}`);
  }

  // The escrow auto-settled round 1: the recipient's payout (and fee) ledger
  // rows are stamped confirmed with the settlement tx hash.
  const [recipientMember] = await db
    .select()
    .from(circleMembersTable)
    .where(and(eq(circleMembersTable.circleId, circle.id), eq(circleMembersTable.payoutRound, 1)));
  assert.ok(recipientMember, "round 1 has a recipient");

  const payoutRows = await db
    .select()
    .from(transactionsTable)
    .where(
      and(
        eq(transactionsTable.circleId, circle.id),
        eq(transactionsTable.round, 1),
        inArray(transactionsTable.type, ["payout", "fee"]),
      ),
    );
  assert.ok(payoutRows.length >= 1, "round 1 should have payout/fee ledger rows");
  const payout = payoutRows.find((r) => r.type === "payout");
  assert.ok(payout, "round 1 payout row exists");
  assert.equal(payout!.onchainStatus, "confirmed", "payout must be confirmed on-chain after RoundSettled");
  assert.ok(payout!.txHash, "payout must carry the settlement tx hash");
  console.log(`· round-1 settlement tx: ${EXPLORER}/tx/${payout!.txHash}`);

  // The on-chain economics mirror the protocol fee: rotation circles expose a
  // non-zero feeBps and the round books a confirmed fee transaction.
  assert.ok((detail!.feeBps ?? 0) > 0, "rotation circle should expose a non-zero feeBps");
  const fee = payoutRows.find((r) => r.type === "fee");
  assert.ok(fee, "round 1 should book a fee transaction mirroring the on-chain fee");
  assert.equal(fee!.onchainStatus, "confirmed", "fee row confirmed alongside the payout");
  return "ran";
}

let failed = false;
let outcome: "ran" | "skipped" = "skipped";
try {
  outcome = await run();
  if (outcome === "ran") {
    console.log(`\n✓ Susu circle ON-CHAIN e2e passed (runId=${runId})`);
  } else {
    console.log(`\n· Susu circle ON-CHAIN e2e skipped (runId=${runId})`);
  }
} catch (e) {
  failed = true;
  console.error(`\n✗ Susu circle ON-CHAIN e2e FAILED (runId=${runId})\n`, e);
} finally {
  await cleanup();
  await pool.end();
}

process.exit(failed ? 1 : 0);
