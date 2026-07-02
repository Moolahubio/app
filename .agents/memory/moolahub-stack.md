---
name: MoolaHub stack decisions
description: Non-obvious decisions and quirks for the MoolaHub social-savings app (Monad testnet, chainId 10143) on the react-vite + Express + Drizzle rebuild
---

## Money & ledger
- Money is double-entry only: balances are always DERIVED from `postings` (sum), never stored on rows. Account keys: `wallet:<userId>`, `goal:<goalId>`, `pool:<circleId>`, `external`, `yield`, `fees`.
- **All money moves go through `ledger.transfer()`**, which runs in a DB transaction and takes per-account Postgres advisory locks (`pg_advisory_xact_lock(hashtext(key))`, transaction-scoped). Pass `requireSufficientFrom: true` for any user-funded debit so the balance check happens inside the locked transaction (prevents overdraft/double-spend races). The pre-checks in callers are only for friendly error messages, not safety.
- **Why:** derived balances + split check-then-write are otherwise racy; concurrent allocate/withdraw/contribute could drive a balance negative.

## On-chain settlement (deliberate testnet tradeoff)
- The ledger is the source of truth; on-chain USDC settles only when `onchainEnabled()` AND the platform/user wallet is funded. Faucet credits and withdrawals still book to the ledger when the chain step is skipped — by design, because the platform wallet may have no testnet gas/USDC. Do NOT "fail on chain error" or the whole testnet flow breaks.
- **Post-deploy authorizer wiring (required after any fresh chain deploy):** the contract owner must call `MoolaHubReputation.setAuthorizer(factory, true)` for BOTH the circle factory AND the accumulation factory, or reputation writes from those factories revert. It is `onlyOwner`; getter is `isAuthorizer(address)`. **Why:** deploying the factories does not auto-grant them authorizer rights; this is a separate owner tx that is easy to forget and silently breaks circle/accumulation reputation until set. The owner wallet needs testnet gas — fund it from the deployer wallet if empty.

## Auth
- **Privy is the primary auth, with passkeys (WebAuthn) as a secondary path.** Email/password was removed entirely (no `/auth/login`, `/auth/register`, no `passwordHash`, no bcrypt). Coinbase/CDP onramp removed too (no `/wallet/onramp-url`, no `@coinbase/cdp-sdk`). Wallets stay local non-custodial (viem-generated, encrypted key in DB) — unaffected by CDP removal.
- Sessions: HTTP-only cookie `moolahub_session` (30d). Must be sent on every authenticated request.
- **Privy `/auth/privy`:** identity is derived strictly from the verified token DID + server-fetched Privy profile. NEVER trust client-supplied email/name for account linking — that was an account-takeover hole. Link to an existing account only on a Privy-*verified* email match.
- The client Privy app id comes from `PRIVY_APP_ID` (valid ~25-char cuid), exposed to the client as `VITE_PRIVY_APP_ID` via vite `define`. `AuthPanel` shows a "not configured" message (and passkey-only) when `appId.length < 10`.

## Circles (Susu)
- Payout is claimed atomically: `update circle_members set paidOut=true where id=? and paidOut=false returning` — if 0 rows, another caller already paid (prevents double-pay). Round advance is a conditional update `where current_round = round` (idempotent).
- `contributions` has a unique `(circle_id, user_id, round)` constraint — the real guard against double-contribution races.

## Misc
- Lessons are static data in `artifacts/api-server/src/lib/lessons-data.ts` (not DB-driven); progress in `lesson_progress`.
- No seed/demo data and no demo login anywhere — everything is real per-user data.
- `/goals/new` is a real route that renders the Goals page with the create dialog auto-opened (it must be declared BEFORE `/goals/:id` in the wouter Switch, else "new" is treated as a goal id).
- API base `/api`; CORS `credentials: true` for cookie auth.
