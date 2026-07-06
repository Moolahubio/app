---
name: MoolaHub ledger money-movement invariants
description: Non-obvious correctness rules for the double-entry ledger, circle contributions, and deposit dedup that have caused review rejections.
---

# MoolaHub ledger money-movement invariants

The double-entry ledger (`artifacts/api-server/src/lib/ledger.ts`) is the source
of truth and commits synchronously. On-chain USDC settlement is now ASYNC via a
persistent queue + reconciler — see [onchain settlement reconciler](moolahub-onchain-settlement.md).
Do NOT "fail the user request on chain error": the ledger still commits; the
chain transfer is booked `onchainStatus="pending"` and retried, never silently
dropped to ledger-only `"none"` (that was the old behavior, replaced).

## Reservation + posting must be ONE transaction
**Rule:** Any flow guarded by a uniqueness constraint (e.g. circle
contributions, unique `(circle_id,user_id,round)`) MUST do the uniqueness
reservation (`onConflictDoNothing ... returning`) and the `ledger.transfer()`
posting inside the SAME db transaction. `transfer()` accepts an optional `tx` to
compose within a caller transaction.
**Why:** A prior version moved money in `transfer()`'s own committed tx and
inserted the contribution row afterward in a separate statement — under
concurrency both transfers committed but only one insert won, double-debiting
the user. Code review rejected it twice.
**How to apply:** reserve first inside the tx; 0 rows returned → throw so the
whole tx (money included) rolls back. Enqueue the on-chain settlement row in the
SAME tx (atomic with the ledger posting); the reconciler does the actual send
out of band and patches the tx hash back onto the records.

## Period caps need their OWN per-user advisory lock (not the balance lock)
**Rule:** Any "max X per calendar period" cap (e.g. the referral withdrawal
monthly cap, min $100 / max $1,000 per UTC month) must serialize concurrent
requests for that user by taking a dedicated transaction-scoped advisory lock
(`pg_advisory_xact_lock(hashtext('referral-wd:'||userId))`) at the TOP of the tx,
*before* re-reading the period sum — then re-check the cap under that lock.
**Why:** `ledger.transfer()` only locks the two *accounts* it moves between, and
only to prevent overdraft. Two concurrent withdrawals both read the same
month-sum before either transfer runs, both pass the cap check, then serialize
harmlessly on the balance lock — so a user with a big balance withdraws up to 2×
the monthly cap. The balance can't go negative, but the cap is bypassed. A naive
"re-check inside the tx" does NOT fix this; the re-check must run under a lock
taken before the read.
**How to apply:** the cap lock key is distinct from account keys and is always
acquired first, so it can't deadlock with transfer()'s account-ordered locks.

## Deposit dedup uses the BARE on-chain tx hash
**Rule:** `syncDeposits()` must dedupe incoming on-chain deposits by the bare tx
hash (`IncomingPayment.hash`), not the `opId` (`hash:logIndex`) form, and record
new deposits with the bare hash. The reconciler writes the bare on-chain hash
onto the faucet transaction when it confirms, so a faucet send can't be
re-imported by sync.
**Why:** Mismatched dedupe keys (faucet=bare hash, sync=opId) let a funded
faucet send be re-imported by `/wallet/sync`, inflating balances. Latent on
testnet but a real bug once the platform wallet is funded.
**How to apply:** keep ALL deposit sources on one canonical id (bare hash); match
the legacy `hash:logIndex` form too for old rows.
