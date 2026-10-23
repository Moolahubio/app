> Produced 2026-10-21 by a Claude Code review team (6 auditors incl. a real build/test run) against GitHub `main` @ `e043ef1`. Companion: `docs/adr-chain-base-vs-stellar.md`, `docs/ios-app-plan.md`.

# Moolahub: what's built and where we go next

*CTO report, 2026-10-21. Everything below was checked against GitHub `main` @ `e043ef1` (2026-07-16), and all paths refer to that commit. Your local checkout is 71 commits behind. Its `CLAUDE.md` still describes Monad; main has moved to Base.*

## 1. Verdict

Moolahub is a broad, well-engineered testnet MVP. It has about 25.7k lines of TypeScript, 22 screens, a real double-entry ledger, goals, both circle types, streaks, referrals, 2FA and passkeys, and 7 languages, and every offline test passes. It is about ten chain-agnostic PRs away from a credible closed testnet beta, but it is not ready for real money in any market. The gaps are concrete:
- Nobody can get money in or out: there is no MoMo, card or GH₵ path.
- The app shows yield that doesn't exist.
- Rotating circles can get stuck.
- Accumulation pools sit in a hot wallet.
- No contract has had an external audit.
- Production is down: app.moolahub.io, moolahubapp.replit.app and moolahub.io all return Replit's "isn't live yet" 404.

## 2. Feature matrix

| Capability | Status | Evidence | Biggest gap |
|---|---|---|---|
| Sign-up / auth | Usable with gaps | `routes/auth.ts:156-284`, `lib/stepUp.ts:48-93` | Passkey RP ID and origin are taken from request headers (`routes/passkeys.ts:47-57`). No Terms or Privacy links. No 18+ check (`auth.ts:132-137`). |
| Goals | Usable with gaps | `lib/goals.ts:185-686`, `PrivyGoalForms.tsx` | `Math.floor(parseFloat(v)*100)` turns "19.99" into 1998 cents (`forms.tsx:58,128`, `goals.tsx:40,53`) |
| Rotating circles | Broken | `lib/circles.ts:110-857`, `MoolaHubSusuEscrow.sol:165-183` | Escrow deploy is silently skipped (`circles.ts:1202,1213`), then contributions are refused forever (`:356`). The ledger books the full pot (`:783`), but the contract doesn't pay it. |
| Accumulation circles | Usable with gaps (custodial) | `circles.ts:340-364,665-731` | Contributions go to the platform hot wallet (`:361`). The accumulation factory has created zero clones. |
| Wallet / add money | Usable with gaps (testnet only) | `pages/wallet.tsx:78-172`, `lib/deposits.ts:50-182` | The only ways in are USDC sent to a 0x address or the test-token faucet |
| Withdraw / cash out | Usable with gaps | `routes/wallet.ts:83-135`, `PrivyWithdrawForm.tsx` | Only to a 0x address. No Idempotency-Key, address allowlist or limits. |
| P2P | Missing | No transfer route in `api-server/src/routes/` | Needs an endpoint and a licensing review (iOS plan D11) |
| Yield | Missing (UI fakes it) | `dashboard.tsx:22,127`, `profile.tsx:281,287`, `routes/dashboard.ts:90` | Shows "+4.1% APY", "+X earned" and "450.0%". The V2 yield contracts are dormant. |
| Streaks | Done | `lib/streaks.ts:391-619` | The share card counts other members' pot money as yours (`streaks.tsx:59`) |
| Learn | Usable with gaps | `lib/lessons-data.ts` | Says USDC is "always" $1 (`:59`), describes an auto-save that doesn't exist (`:96`), promises the "entire pot" (`:30-34`) |
| Notifications | Usable with gaps | `lib/notifications.ts`, `lib/email.ts` | No push, no contribution-due reminders, English-only server text |
| Referrals | Usable with gaps (compliance-blocked) | `lib/referrals.ts:57-766` | Paying USDC for recruiting breaks App Store 3.1.5(v). Referrers can see referees' legal names (`:574,614`). Attribution happens before email verification (`auth.ts:235`). |
| Profile / security | Usable with gaps | `routes/account.ts:25-125` | Session tokens stored in plaintext (`schema/sessions.ts:9`). TOTP codes can be replayed. The delete check ignores on-chain and referral balances (`account.ts:66`). |
| i18n | Usable with gaps | `i18n/languages.ts:20-28` (7 locales, 838 keys, all complete) | No Twi, en-GH or GH₵. "Monad" appears 19 times in the English copy (`auth.json:6`). |
| Admin / ops | Stub | `routes/operations.ts:9-22` (read-only), `.replit:5` | Production is down. Background workers run inside the autoscale web process. No migrations, backups or alerts. |

## 3. Health

- **Install and typecheck:** the frozen-lockfile install passes, and the root `pnpm run typecheck` reports 0 errors.
- **Build:** passes only when `PORT` and `BASE_PATH` are set; otherwise `vite.config.ts:7-27` throws. The main JS chunk is 3.3 MB (957 kB gzipped) with no code splitting.
- **API tests:** all 14 offline e2e suites pass. The 2 on-chain suites skipped because no funded wallet was configured.
  - There are no unit tests and no frontend tests.
  - Untested: the 4 client-signed confirm endpoints, settlement reversal, and withdraw.
- **Contracts:** 96 of 96 Foundry tests pass, but the deeper invariant tests cover only the dormant V2 contracts. Slither reports 2 High findings in V2 `_setAdapter` (`MoolaHubGoalVaultV2.sol:246-255`), so the next contracts PR will probably fail CI.
- **CI:** GitHub runs only the contract checks and CodeQL. Copy-lint is disabled and currently fails. Typecheck, build and e2e run only on Replit.
- **Monad usage:** only one rotating-circle escrow has ever been created, and the Treasury has collected $0.08 in fees in total.

## 4. Chain-specific vs chain-agnostic

| Layer | Lines | Survives any chain |
|---|---|---|
| Web app (excluding shadcn components) | 11.1k | ~91%. About 1k lines across 9 files are chain-specific: the wallet provider, the 3 Privy money forms, wallet setup, `lib/onchain` and explorer links. |
| API server | 13.6k | ~82%. Chain-specific: `chain.ts` (1,521 lines), `circleChain`, the indexer, receipt verifiers, the settlement send paths and the gas top-up route. |
| DB schema | 0.9k | ~98% |
| Contracts + tests | 2.3k + 2.1k | 0% (EVM-specific by definition) |

About 86% of the TypeScript works on any chain: the ledger, the settlement state machine, the rules for goals, circles, referrals and streaks, auth, notifications, i18n, and every screen except the money buttons.

- **Base:** over 90% carries over as code, because it is the same EVM stack and the repo has run on Base Sepolia before. The work is about 2-3 PRs:
  - one chain-config module
  - real USDC instead of the test token
  - deleting the faucet
  - Privy gas sponsorship
  - updating `Deploy.s.sol:148-155`
  
  If we follow `base-mainnet-architecture.md` as written, all three current contracts get replaced.
- **Stellar:** a rewrite. About 3.5k lines of TypeScript change, and 4.4k lines of Solidity and tests move to Rust/Soroban and need a new audit. The wallet stack changes too, because Privy supports Stellar only for signing: no send and no gas sponsorship (docs.privy.io/wallets/overview/chains). On top of that come trustlines, account reserves and storage-expiry handling for long-running circles. That is weeks to months of work.
- **How to decide:** follow the chain your licensed MoMo or fiat partner settles on, because that rail is missing on either chain. The repo has already changed chains three times (Stellar → Base → Monad: `ea78424`, `fef3bb7`, `e673570`). Don't change a fourth time without a signed partner.

## 5. Where to continue

**A. Steps that pay off on any chain, in priority order**

1. **Restore production and add monitoring (S).** Re-publish the app. Add Sentry and an uptime check. Make `healthz` query the DB and report stuck settlement rows (`routes/health.ts:6-9`).
2. **Honest copy and the legal minimum (S/M).**
   - Remove the fake yield (`dashboard.tsx:22,105,124-130`, `profile.tsx:276-289`, `routes/dashboard.ts:90`).
   - Strip "Monad", "Privy" and "Save. Earn." from all 7 locales, and fix `lessons-data.ts:30-34,59,96`.
   - Add Terms/Privacy acceptance (with version), a server-side 18+ check, and an About & legal page.
   - Turn Refer & Earn off by default.
3. **Correct money handling in the web app (S).** One shared `parseAmountToCents`, a vitest test setup, and a shared loading/error component plus a global 401 handler (`App.tsx:36`). A failed balance load should never show $0 or spin forever.
4. **Move background jobs into a separate worker (M).** Create `src/worker.ts` on a Reserved VM, with a database lock so only one instance runs each job. Replace the startup requeue at `settlement.ts:955-964`, which can double-send, with time-limited leases. Move rate limits into Postgres so they hold across instances.
5. **Idempotency and a stable v1 API (M).** Add an `idempotency_keys` table and middleware on every money POST, so a retried request can't move money twice. Serve `/api/v1` with machine-readable error codes, 403 when step-up is required, cursor pagination and strict request schemas. The iOS app needs all of this (iOS plan N2/N3).
6. **Database discipline (M).** Commit versioned migrations and drop `push` from `scripts/post-merge.sh:4`. Index the postings table and make it append-only. Run a nightly backup outside Replit and one restore drill.
7. **CI gate (S).** A GitHub job that runs typecheck, build and the 14 offline e2e suites against Postgres. Lint the locale files and fix the V2 Slither findings.
8. **Security hardening (M).**
   - Pin the passkey RP ID and guard the passkey login routes.
   - Store session tokens hashed.
   - Block TOTP replay and cap 2FA and step-up attempts.
   - Return the session token in the response body for iOS (plan N1/N6/N7).
9. **Circle lifecycle, off-chain half (M).**
   - Block starting a circle until every member has a wallet.
   - Retry escrow deploys that fail.
   - Add round deadlines, reminders and stalled/cancelled states.
   - Add push notifications via APNs.
10. **Data model ready for fiat (M).** Phone number, KYC tier and limits, a GHS amount and FX snapshot on each transaction, and generic ramp-order and webhook tables. Add a GH₵ display and a "MoMo coming soon" entry point.

**B. Steps that depend on the chain decision**

- **Rotating-circle payout rule and fee model** (iOS plan D10). Once chosen, align `circles.ts:783-830` with the contract.
- **Custody:**
  - Accumulation contributions go into per-circle contracts instead of the platform wallet.
  - Move the remaining server-held keys to user-controlled wallets.
  - Contract ownership moves to a separate operator role plus a multisig (Safe).
  - The user stays the sole wallet owner (plan D4).
- **Recovering client-signed transactions:** store the transaction hash on the server, and fix and start the indexer (`onchainIndexer.ts:44-49`).
- **Gas:** Privy sponsorship on Base, or fee-bump transactions on Stellar.
- **Yield:** Privy Earn on Base; the Stellar equivalent is not yet confirmed. Earnings stay off for Ghana either way.
- **Rollout:** deploy to the chosen chain's testnet, run the live end-to-end tests on both custody paths, then retire Monad.
- **Audit:** an external audit of the final circle contract, with circles behind a feature flag until it is done.
- **Card and MoMo on-ramp:** the Base plan's Stripe (US only) and MoonPay rails don't cover MoMo. On Stellar, it is unconfirmed whether any anchor (a licensed on/off-ramp partner) serves Ghana.

## 6. Launch blockers

**For a closed testnet beta:** production back up, fake yield removed, amount parsing fixed, background workers moved out, stuck circles fixed, legal links added, and error states on every page.

**For real money, on top of those:**
1. **No money in or out.** There is no MoMo, card or GH₵ path (`lib/money.ts:9`). Ghana also needs a licensed partner, Bank of Ghana registration under the VASP Act (Act 1154, with full operation targeted for 2027) and registration with the Data Protection Commission.
2. **The "non-custodial" claim isn't true.** Some users' keys are still held by the server, accumulation pools sit in the platform's hot wallet, and that same hot key owns the circle factory. Every admin role is a single key, not a multisig.
3. **Four conflicting rotating-circle rules.**
   - The deployed contract `0x31E8…` doesn't have the reserve fix.
   - The source code removes the early lump-sum payout.
   - The Base plan drops the reserve again.
   - The ledger records a full pot payout.
   
   There is also no path for defaults or refunds.
4. **No external contract audit.**
5. **Orphaned payments.** After a user signs a payment, its transaction hash exists only in browser memory (`PrivyContributeButton.tsx:55`). Reloading the page at that point means the money moves with no ledger record, and nothing recovers it. Money routes also lack Idempotency-Keys.
6. **Ops.** Autoscale combined with the startup requeue can double-send. There are no migrations, backups or alerts. `ENABLE_TEST_FAUCET="true"` sits in the shared env (`.replit:103`), so on a real-money chain one stale flag would create spendable balance.
7. **Security:** passkey checks trust request headers, session tokens are stored in plaintext, and rate limits are tracked per process.
8. **Compliance:**
   - No KYC/AML, Terms or Privacy Policy.
   - Refer & Earn conflicts with App Store 3.1.5(v) and the Bank of Ghana/SEC February 2026 notice restricting crypto promotion.
   - The lessons contain false claims.