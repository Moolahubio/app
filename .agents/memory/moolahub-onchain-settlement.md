---
name: MoolaHub on-chain settlement reconciler
description: How async USDC settlement works on Base Sepolia — persistent queue + reconciler, and the safety rules that keep it from double-sending or silently dropping transfers.
---

# MoolaHub on-chain settlement reconciler

USDC settlement is decoupled from the synchronous ledger. Money-movement flows
(faucet deposit, withdraw, circle contribute, payout) commit the ledger posting
AND insert an `onchain_transfers` queue row in ONE db tx, booking the
transaction `onchainStatus="pending"`. A background reconciler does the real
chain send out of band.

## Why async (not synchronous send)
**Why:** The old behavior sent USDC inline and, on failure (e.g. unfunded
platform wallet), silently booked the transfer as ledger-only `onchainStatus="none"`
— so the activity feed never got a real tx hash and there was no retry. The
queue makes settlement durable: a transfer stays `pending` and is retried until
it confirms, so once the platform wallet is funded everything self-heals.

## Reconciler safety rules (don't regress these)
- **No double-send:** claim a row with a conditional update gated on
  `status='pending'` (DB-level `FOR UPDATE SKIP LOCKED`) flipping it to
  `processing` before sending. Plus an in-process `running` guard so the 15s
  interval and the post-commit `kickReconciler()` can't run concurrently in the
  same process.
- **Idempotent confirm:** confirming patches `transactions.txHash` /
  `onchainStatus="confirmed"` and the contribution row; re-running is a no-op.
- **Crash recovery:** `startSettlementLoop()` at boot resets stranded
  `processing` → `pending`. Single-instance assumption; the accepted tradeoff is
  a possible double-send if the process dies AFTER the chain accepted the tx but
  BEFORE we recorded the hash (fine on testnet).
- **Backoff:** failed rows record `lastError` + `lastAttemptAt` and wait ~30s
  before the next attempt; never throw out of the reconciler.
- **Dead-letter (not infinite retry):** after `MAX_ATTEMPTS`
  (`SETTLEMENT_MAX_ATTEMPTS`, default 10) the row is marked `status='failed'`
  and the linked transaction `onchainStatus='failed'` (one tx) so activity.tsx
  surfaces it. The claim query filters `status='pending'`, so failed rows are
  never re-claimed. `requeueOrFail` makes this decision for ALL transient
  failures (RPC/skipped, thrown error, missing signing key).
  **Gotcha:** `attempts` is incremented at claim time, but the in-memory `row`
  returned from the claim holds the PRE-increment value — the attempt just made
  is `row.attempts + 1`. Use that when comparing to a max, or you're off by one.

## Rotation payout settlement is backfill-by-(circleId, round), not a queue row
Rotation payout/fee transactions are NOT enqueued. The escrow settles the round
on-chain itself when the last member contributes; the reconciler stamps the
payout/fee ledger rows confirmed by matching `(circleId, round)` when it sees
`RoundSettled` while processing that contribution (`backfillPayoutSettlement`).
- **Ordering invariant:** the payout/fee rows MUST exist before the reconciler
  can detect `RoundSettled`, or the backfill updates 0 rows and the payout is
  stranded `pending` forever (no retry path — they're not queued).
  `contribute()` therefore runs `maybeProcessPayout()` BEFORE `kickReconciler()`.
  **Why:** the on-chain contribute takes seconds while the ledger payout write is
  sub-second, so even the independent 15s interval reconciler can't outrun it —
  but only if the rows are created first. Do not move the kick before the payout.

## startCircle escrow deploy is a TOCTOU — write must be compare-and-set
`startCircle` reads `status='forming'`, deploys the escrow (seconds), then writes.
The final update is conditioned on `status='forming'` (returning rows; 0 → throw
"already started"). **Why:** without it, two concurrent starts could both write —
one with the confirmed `contractAddress`, the other with a null ledger-only
fallback that overwrites it, silently downgrading a circle that has a live escrow.
The factory keys escrows by `circleId` and returns the existing one, so the
duplicate deploy is harmless; the compare-and-set is what protects the address.

## Operational dependency
The platform wallet must hold Base Sepolia ETH (gas) + test USDC. When unfunded,
the reconciler attempt fails with `"gas required exceeds allowance (0)"` and the
row correctly stays `pending`. Funding is a USER step (external faucet) — cannot
be done from the sandbox.

## Operator observability endpoint
`GET /api/operations/settlements` is a READ-ONLY operator view of the queue
(counts/totals per status + a recent-rows sample) plus the platform wallet's live
ETH/USDC balance. It is **gated by an optional `OPERATOR_TOKEN`** (via the
`x-operator-token` header, timing-safe compared in `requireOperator`).
**Why:** the data is operationally sensitive (wallet address/balance, transfer
errors). The gate is **safe-by-default LOCKED**: when `OPERATOR_TOKEN` is unset
the route returns 503 and exposes nothing. The user explicitly declined to
provision the token secret (considers a shared bearer token a security risk), so
do NOT auto-create/request it — leave enabling it to the operator. Do not weaken
the gate to plain `requireAuth` (that would leak operator data to every user).
