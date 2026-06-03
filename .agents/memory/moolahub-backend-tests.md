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
