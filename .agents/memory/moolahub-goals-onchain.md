---
name: MoolaHub Goals on-chain (GoalVault)
description: Economics + invariants for taking savings Goals on-chain via the non-custodial GoalVault, and the two correctness fixes that came out of review.
---

# MoolaHub Goals on-chain

Goals settle through a deployed Base Sepolia `GoalVault` (non-custodial: the user
signs their own deposit/withdraw; the platform key only tops up the user's gas).
Mirrors the Susu-circles on-chain design and reuses the same settlement queue +
reconciler.

## Economics (user decision)
- **Allocating to a goal = deposit into the vault, FREE.**
- **Every withdrawal charges the 2% fee** — both a partial release AND deleting a
  goal (which auto-withdraws the whole balance net of the fee). The vault takes
  the fee on-chain and routes it to the treasury.
- Ledger stays source of truth and mirrors on-chain: net → wallet, fee → fees
  account, in the same DB tx that enqueues the on-chain row.

## Graceful degradation is CONFIG-gated, not live-RPC-gated
Fee + on-chain enqueue are gated on `goalVaultEnabled()` (vault+usdc+platform key
configured), NOT on live RPC reachability. When not configured, goals run
ledger-only with NO fee. **Why:** the explicit instruction was "mirrors circles,"
and circles also gates on configuration — when configured-but-RPC-down it keeps
the row `pending` and retries rather than falling back to ledger-only/no-fee. A
review flagged this as "degradation not met"; it is intentional per the circles
precedent. Don't switch it to runtime availability.

## Sub-cent fee drift is an accepted tradeoff
Ledger fee = `Math.floor(gross*200/10000)` in cents; the vault computes 2% in
6-decimal USDC units, so for tiny withdrawals (<50c) the two can differ by <1
cent. Accepted — same property circles has and prior reviews accepted. Don't
"fix" it by adding fractional-cent ledger math.

## Two correctness invariants (came out of review — keep them)
- **deleteGoal flips status active→deleted BEFORE draining**, via a single
  compare-and-set `UPDATE ... WHERE status=active ... RETURNING`. allocate/release
  both require an *active* goal, so once the flip returns a row no concurrent op
  can move money in/out while we drain. Flipping AFTER the drain leaves a window
  where a concurrent allocate re-funds a goal we're about to close, stranding
  funds in a deleted goal. The goal *account* keeps its balance regardless of the
  goals-row status, so the drain still works post-flip.
  - **The flip alone is NOT sufficient — the money-IN path must revalidate under a
    row lock.** A pre-transaction `status=active` SELECT does not serialize against
    the flip, so `allocateToGoal` MUST re-read the goal row `SELECT ... FOR UPDATE`
    and re-check `status===ACTIVE` *inside* its own `db.transaction` BEFORE
    transfer/enqueue (mirrors the circles `.for("update")` pattern). Without it,
    delete-wins → allocate commits `wallet→goal` (+ on-chain `goal_deposit`) into a
    deleted goal → stranded (no read/withdraw path, no recovery API). The flip
    UPDATE and the FOR UPDATE contend on the same row, so they fully serialize;
    keep the wallet-balance gate OUTSIDE the tx so a slow on-chain read never holds
    the lock (the ledger transfer re-checks funds via `requireSufficientFrom`).
    Regression: `goals-race.e2e.ts` (`test:goals-race`, offline) pins both
    orderings + a concurrent stress loop.
  - **Money-OUT (`releaseFromGoal`) needs NO such guard** and is intentionally
    status-agnostic (so delete can drain a flipped goal). Over-drain is impossible:
    `requireSufficientFrom` + the `goalSpendableCents` gate are atomic in the
    locked transfer, and the worst interleaving just fails the drain → delete's
    catch rolls the goal back to active (funds intact, retryable).
- **goal_withdraw confirms the queue row + net release txn + fee txn ATOMICALLY**
  in one DB tx (`confirmGoalWithdraw`), and the reconciler's idempotency
  early-return ALSO backfills the fee txn for `goal_withdraw` rows. **Why:** one
  on-chain withdrawal settles both net and fee; confirming them in separate calls
  could crash in between and strand the fee txn `pending` forever, and the
  early-return path (net already confirmed) would never revisit it.

## Deposit/withdraw enqueue asymmetry → cap withdraw to live on-chain balance
`allocateToGoal` enqueues a `goal_deposit` ONLY if the vault is enabled *at
allocate-time*; `releaseFromGoalCore`/`deleteGoal` enqueue a `goal_withdraw` for
the FULL ledger balance whenever the vault is enabled *at withdraw-time*. A goal
funded while the vault was disabled (or whose deposit never settled) therefore has
a smaller/zero on-chain `balanceOf(owner,goalId)` than the ledger, so the withdraw
over-pulls and reverts forever with `Insufficient` (selector `0x1dc930eb`) until
it dead-letters. **Fix (chain.ts `goalWithdraw`):** read live `balanceOf` and
`gross = min(requested, onchainUnits)`; if `gross==0n` return
`{status:"confirmed", hash:"", feeCents:0, netCents:0}` (no tx) so the
already-booked pending ledger postings still get stamped by `confirmGoalWithdraw`
(which keys off transaction id, not hash — empty hash is safe, reconciler only
claims `pending` rows). `ensureGas` runs AFTER the read; `netCents` derives from
the actual (capped) `gross`. **Why this is enough today:** there are ZERO
`goal_deposit` rows in practice, so the mirror is always empty → only the
`gross==0` path is hit. **Known residual (follow-up, harmless until real on-chain
deposits exist):** in a *partial*-cap case the ledger booked fee/net on the full
requested gross while the chain charges fee on the capped gross — an accounting
drift, not a safety/retry bug. Proper cure = make enqueue symmetric (track a
per-goal on-chain-mirrored amount, only withdraw up to settled deposits) +
reconcile partial-cap fee/net. Don't expand the cap fix into that refactor without
the v2 contract deploy that actually puts deposits on-chain.

## Soft-delete is mandatory
`ledger_accounts.goalId` FKs the goals row with ON DELETE CASCADE, so a hard
delete wipes the goal's postings and corrupts the double-entry ledger. Delete =
`status="deleted"`; list/getGoal filter `status="active"`.

## Memo format
Goal queue rows use memo `goal:<goalId>` (deposit) / `goal:<goalId>:<feeTxnId>`
(withdraw). `goalFromMemo()` parses both; the feeTxnId is how the reconciler finds
the fee txn to co-confirm.
