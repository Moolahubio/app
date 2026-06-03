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

## Operational dependency
The platform wallet must hold Base Sepolia ETH (gas) + test USDC. When unfunded,
the reconciler attempt fails with `"gas required exceeds allowance (0)"` and the
row correctly stays `pending`. Funding is a USER step (external faucet) — cannot
be done from the sandbox.
