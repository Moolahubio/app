---
name: MoolaHub backend integration/e2e tests
description: How to run deterministic, offline backend flow tests against the real DB (Susu rotation, ledger flows).
---

# Running MoolaHub backend flow tests

Backend flow tests (e.g. the Susu circle rotation) call the real `lib/*` service
functions against the real database via `tsx`, the same path the HTTP routes use
(routes are thin wrappers). Example runner: `pnpm --filter @workspace/api-server test:susu`.

## Make them deterministic and offline
On-chain settlement and email are configured in dev (secrets present), so a naive
test would spend testnet funds and send real emails to fake addresses. Disable both
**before importing any module**, because the values are snapshotted at import time:
- `chain.ts` captures `USDC_CONTRACT_ADDRESS` into a module-level const at import;
  `onchainEnabled()` also needs `PLATFORM_PRIVATE_KEY`. Delete both env vars first.
- `email.ts` captures `RESEND_API_KEY` into a const at import. Delete it first.

Because ESM imports hoist, the pattern is: `delete process.env.X` at the very top,
then `await import(...)` everything dynamically. The double-entry ledger postings
(which drive payouts/balances) are identical whether or not on-chain is enabled —
only the async USDC send is skipped — so ledger assertions stay valid.

**Why:** the ledger is the source of truth and commits synchronously; on-chain
settlement is an out-of-band queue + reconciler concern, tested/owned separately.

## Running the ON-chain e2e suites (test:goals-onchain / test:susu-onchain)
These KEEP `USDC_CONTRACT_ADDRESS`+`PLATFORM_PRIVATE_KEY` (on-chain ON) and drive
the real reconciler against Monad; they SKIP (exit 0) only if the platform wallet
is unfunded or the RPC is unreachable. Two harness traps make them hard to run:
- `tsx` **block-buffers stdout when writing to a file/pipe**, so `pnpm ... | tail`
  or `> file` shows nothing until the process exits — a mid-run kill loses ALL output.
- They exceed the bash tool's 120s cap (multiple ~90s settle-loop budgets), so a
  single blocking bash call gets SIGKILL'd (exit -1) mid-flight, and a SIGKILL skips
  the `finally` cleanup → can orphan test users/goals/circles.
**How to run/verify:** either (a) run them via a Replit workflow + `restart_workflow`
(logs are captured to /tmp/logs reliably, as the offline `circles`/`auth tests`
workflows do), or (b) prove the on-chain op directly with `cast send` (e.g.
`mint(addr,units)` from `$PLATFORM_PRIVATE_KEY`) + query `onchain_transfers` for
`confirmed` rows with real tx hashes. Never run the two on-chain suites in parallel
(shared platform key → nonce collisions).

**The running api-server IS a competing signer.** Its `startSettlementLoop`
reconciler claims pending `onchain_transfers` (SKIP LOCKED) and tops up user gas
from the SAME `$PLATFORM_PRIVATE_KEY`. So an on-chain e2e run while the api-server
workflow is up collides on the platform nonce — symptoms: mint/approve revert with
"An existing transaction had higher priority" (platform nonce) or the user wallet's
`approve` reverts "Signer had insufficient balance" (its `ensureGas` top-up got
stuck). Fix: stop the api-server first (kill its node tree by explicit PID, or via
a workflow that isn't running concurrently), then run ONE on-chain process.
**Recovery once polluted:** stuck low-priority platform txs block the nonce queue,
so even isolated reruns keep failing for MINUTES until the mempool drains — waiting
~75s is often not enough. Don't hammer it; each retry adds more stuck txs.

## Side-effect notes
- Importing `settlement.ts` is side-effect free: the reconciler interval only
  starts via `startSettlementLoop()` (called from `index.ts`), never at import.
- `tsx` resolves workspace TS packages directly (`@workspace/db` exports `./src`,
  and the base tsconfig sets `customConditions: ["workspace"]`).

## Clean up after yourself
These run against the shared dev DB (all data is real per-user). Always clean up in
a `finally`. Robust order: delete every transaction whose postings touch the test
wallets or circle pot (cascades postings on BOTH sides, including the shared
`external` account → no orphan postings), then delete the circle (cascades members,
invites, contributions, pool ledger account), then delete the users (cascades
wallets, notifications, per-user ledger accounts). Verify with: zero leftover test
users/circles and zero orphan postings.
