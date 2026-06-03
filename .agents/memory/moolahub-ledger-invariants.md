---
name: MoolaHub ledger money-movement invariants
description: Non-obvious correctness rules for the double-entry ledger, circle contributions, and deposit dedup that have caused review rejections.
---

# MoolaHub ledger money-movement invariants

The double-entry ledger (`artifacts/api-server/src/lib/ledger.ts`) is the source
of truth; on-chain USDC settlement is best-effort and skipped when the platform
wallet is unfunded (testnet default). Do NOT "fail on chain error" — it would
break the whole testnet flow by design.

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
whole tx (money included) rolls back. Move external/on-chain sends to a
best-effort step AFTER commit and patch the tx hash back onto the records.

## Deposit dedup uses the BARE on-chain tx hash
**Rule:** `syncDeposits()` must dedupe incoming on-chain deposits by the bare tx
hash (`IncomingPayment.hash`), not the `opId` (`hash:logIndex`) form, and record
new deposits with the bare hash. `faucetDeposit()` records the bare hash via
`toMeta()`.
**Why:** Mismatched dedupe keys (faucet=bare hash, sync=opId) let a funded
faucet send be re-imported by `/wallet/sync`, inflating balances. Latent on
testnet but a real bug once the platform wallet is funded.
**How to apply:** keep ALL deposit sources on one canonical id (bare hash); match
the legacy `hash:logIndex` form too for old rows.
