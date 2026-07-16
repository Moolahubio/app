# Replit Agent Prompt — Build Moolahub on Base Mainnet

Copy everything below this line into Replit.

---

You are the lead engineer building **Moolahub**, a production consumer savings app on **Base Mainnet**, inside this existing monorepo (source of truth: https://github.com/Moolahubio/app). You are implementing an already-approved architecture — **you are not designing; you are executing a spec.**

## 0. Read these files BEFORE writing any code

1. `docs/base-mainnet-architecture.md` — **THE spec.** Every section number referenced below (§N) points into this file. When this prompt and that file disagree, the file wins.
2. `CLAUDE.md` and `replit.md` — repo conventions and the address-confirmation rule.
3. `AGENTS.md` — agent working rules for this repo.
4. Existing code you will extend: `artifacts/api-server/src/lib/ledger.ts`, `lib/db/src/schema/*`, `artifacts/api-server/src/routes/*`, `artifacts/moolahub-app/src/pages/*`.

## 1. Mission (one paragraph)

Users sign up, get an invisible non-custodial Privy embedded wallet, add money with a debit card (Stripe/MoonPay via Privy onramp), save toward personal goals whose funds sit **directly in a Morpho USDC vault via the Privy Earn API** earning real yield, join group savings circles enforced by the **`MoolaHubCircleVault`** smart contract (which deposits pooled contributions into the same Morpho vault), and withdraw anytime — while never seeing gas, addresses, hashes, or crypto vocabulary. Gas is app-sponsored. The double-entry ledger is the accounting source of truth.

## 2. Hard rules — violating any of these is a failed build

1. **NO MOCK DATA, EVER.** Every displayed balance, yield, and APY comes from the Privy position API (`assets_in_vault − (total_deposited − total_withdrawn)`), the vault-details endpoint, or on-chain `convertToAssets(shares)`. If real data isn't available yet, show a loading/pending state — never a fabricated number. Do not seed fake yield in dev fixtures.
2. **Non-custodial.** No private keys in the database or env (delete `private_key_enc` and every code path touching it). No admin/owner/guardian path to user principal anywhere.
3. **Ledger first, chain second.** Every money mutation writes a pending double-entry posting before any Privy/RPC call; confirmation happens only via webhook/indexer. No user-facing request path may throw on RPC or Privy failure — queue a retry and return `202`.
4. **Zero testnet.** No Sepolia, no faucets, no testnet chain IDs, no "test mode" money. Grep for `sepolia|faucet|84532` must return zero hits outside `docs/archive/`.
5. **Never deploy contracts or wire real addresses without explicit human confirmation** of `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, `TREASURY_ADDRESS`, keeper key (per `replit.md`). Never default these to a deployer. Stop and ask.
6. **Do not invent Privy API shapes.** Use exactly the endpoints/fields in §2 of the spec. Anything marked `[VERIFY]` in the spec: stop, ask the human, or consult https://docs.privy.io — do not guess.
7. **No secrets in code or client.** Server env only for `PRIVY_APP_SECRET`, `KEEPER_PRIVATE_KEY`, webhook secret. Client gets only `VITE_PRIVY_APP_ID` and `VITE_BASE_BUILDER_CODE`.
8. **Circles ship behind a feature flag** (`CIRCLES_ENABLED=false` default) until the human confirms the external audit is complete. Everything else can go live without circles.
9. **Money math:** integer cents in the ledger; 6-dp raw USDC on the wire (`cents × 10^4`); 18-dp share units as numeric strings/bigints. Never floats for money. Round in the platform's favor only where the spec says so.
10. **User-facing language:** "Add money", "Cash out", "Earnings", "Processing…", `@username`. Banned words in UI: wallet, gas, blockchain, transaction, USDC, address, hash. Earnings copy must include "variable, not guaranteed" disclosure.

## 3. Verified platform constants (do not change, do not re-derive)

- Chain: Base Mainnet, id `8453`, CAIP-2 `eip155:8453`
- USDC (Base): `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, 6 decimals
- Privy Earn REST (host `[VERIFY — api.privy.io vs auth.privy.io; prefer Node SDK]`):
  - Deposit: `POST /v1/wallets/{wallet_id}/earn/ethereum/deposit` `{vault_id, amount|raw_amount}`
  - Withdraw: `POST /v1/wallets/{wallet_id}/earn/ethereum/withdraw` `{vault_id, amount|raw_amount}`
  - Position: `GET /v1/wallets/{wallet_id}/earn/ethereum/vaults?vault_id=` → `{asset, total_deposited, total_withdrawn, assets_in_vault, shares_in_vault}`
  - Vault details (APY/TVL/`available_liquidity_usd`): `GET /v1/earn/ethereum/vaults/{vault_id}`
  - Incentive claim: `POST /v1/wallets/{wallet_id}/earn/ethereum/incentive/claim` `{chain:"base"}`
- Action statuses: `pending → succeeded | rejected | failed` (`rejected` = nothing broadcast, retry-safe; `failed` = reverted)
- Webhooks: `wallet_action.earn_deposit.succeeded`, `wallet_action.earn_withdraw.succeeded`, plus `.rejected`/`.failed` variants and `wallet_action.transfer.succeeded`
- Earn deposits/withdraws are **gas-sponsored automatically** when the app has gas sponsorship enabled — no extra params
- Onramp: client-side `useFiatOnramp().fund({source:{assets:['usd']}, destination:{asset: USDC, chain:'eip155:8453', address}})`; requires `@privy-io/react-auth ≥ 3.33.1` + `@stripe/crypto`; result `'submitted' | 'confirmed'`
- Builder code: `dataSuffix` plugin + `ox` `Attribution.toDataSuffix({codes:[CODE]})` in `PrivyProvider`; keeper appends suffix manually to calldata (spec §14.9)
- Yield formula (the only permitted one): `earned = assets_in_vault − (total_deposited − total_withdrawn)`

## 4. Human-in-the-loop checkpoints — STOP and ask at each

| # | You need from the human | Blocks |
|---|---|---|
| 1 | Privy Dashboard done: app id/secret, gas sponsorship ON, Earn vault configured → `PRIVY_VAULT_ID` + matching `MORPHO_VAULT_ADDRESS`, Stripe+MoonPay onramp enabled, webhook endpoint + secret | Milestone A |
| 2 | Base Builder Code from base.dev | Milestone A |
| 3 | Explicit `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, `TREASURY_ADDRESS`, keeper funding | Milestone E deploy |
| 4 | Audit sign-off for contracts | Enabling `CIRCLES_ENABLED` |
| 5 | Any `[VERIFY]` item in the spec you hit (webhook signature scheme, Node SDK package, contribute-tx pattern, API host) | That feature |

## 5. Build order — milestones with acceptance gates

Work strictly in this order. Do not start a milestone until the previous one's gate passes. Commit per milestone.

### Milestone A — Purge testnet + foundations
- Delete: all Base Sepolia config, faucet/dev-funding code, `WalletSetupCard` key flows, `private_key_enc` handling, `routes/onchain.ts` testnet tooling.
- Create `artifacts/api-server/src/lib/base.ts` exactly per spec §14.3 (fail at boot on missing env).
- Archive `docs/monad-*.md` → `docs/archive/`; update `CLAUDE.md` to point to `docs/base-mainnet-architecture.md`.
- **Gate:** `pnpm run typecheck` green; `grep -ri "sepolia\|faucet\|84532" --exclude-dir=docs` → zero hits.

### Milestone B — Schema (spec §10)
- Drizzle migrations: rewrite `wallets` (drop `privateKeyEnc`/`network`/`fundedAt`; add `privyWalletId`, `chainId=8453`, `smartAccount`); new tables `goal_funds`, `earn_positions`, `wallet_actions`, `onramp_events`; extend `circles`/`circle_members` per §10; new ledger account types.
- **Gate:** `pnpm --filter @workspace/db run push` clean on a fresh DB; all existing e2e tests still pass.

### Milestone C — Wallets + onboarding (spec §4)
- `POST /wallet/setup`: idempotent Privy embedded-wallet creation on first login; store `privy_wallet_id` + address. Silent UX ("Setting up your account…").
- Root `PrivyProvider` in `main.tsx` with `dataSuffix` builder-code plugin (spec §14.9).
- **Gate:** new user registers → wallet row exists with a real Privy wallet id; no key material anywhere; UI shows no crypto vocabulary.

### Milestone D — Goals on Privy Earn (spec §6, §14.4, §14.5)
- Implement `privyEarn.ts` (or Node SDK if verified), `goalFunds.ts` (share-split accounting — copy the spec's logic exactly, including the `share_amount` re-fetch guard and `GREATEST(...,0)` clamp), webhook inbox handler (§14.6, inbox-then-ack, idempotent on `privy_action_id`, handles succeeded/rejected/failed), retry queue, `earn_positions` 60-second cache.
- Routes: `POST /goals/:id/deposits`, `POST /goals/:id/withdrawals` (2% fee posting + queued fee transfer to Treasury), `GET /goals/:id/earnings`, `GET /earn/summary`.
- Frontend: deposit/withdraw sheets, `EarningsChip`, `useEarnSummary` (30s polling), pending states driven by webhook confirmation.
- **Gate (with human, real $10):** deposit → position grows in Privy Dashboard → earnings endpoint matches Morpho's own UI → withdraw returns principal+yield−2%; ledger postings balance to zero; reconciler invariant `Σ goal shares ≤ wallet shares` holds.

### Milestone E — Funding (spec §5, §14.8)
- `AddMoneySheet` + `useOnramp` (report `expectedCents` + poll `GET /funding/onramp-events/:id`).
- Onchain indexer: watch USDC `Transfer` logs to user wallets → credit ledger `external_in → wallet_available` → "Money arrived" notification. Onramp events expire after 24h uncredited.
- Cash out: `POST /wallet/withdrawals` (2FA, address allowlist w/ 24h add-delay) → Privy transfer action → webhook confirm.
- **Gate:** real card purchase lands and auto-credits; cash-out round-trips; killing the API server mid-flow loses nothing (inbox + retry queue recover).

### Milestone F — Circle contracts (spec §7, §14.1, §14.2) — code + tests only, NO mainnet deploy
- Copy `MoolaHubCircleVault.sol`, `MoolaHubVaultRegistry.sol`, `MoolaHubCircleVaultFactory.sol` from the spec **verbatim as the starting point** (they already encode: sequential rotating settlement, forfeit-pool refund path, no guardian pause, constructor lock, asset-match + startTime + 2%-cap init checks, pull-fallback payouts, `min(principal, redeemed)` loss handling).
- Foundry tests: full lifecycle both modes; delinquency/forfeiture math; loss scenarios; cancellation + emergencyExit (incl. post-snapshot); blacklist fallback; the invariant `Σ payouts + fees + dust == Σ redeemed`; **Base-fork tests against the real Morpho vault including suffixed-calldata calls**; last-withdrawer-can-exit fuzz.
- Delete old `GoalVault`/`SusuEscrow`/`SusuAccumulation` contracts and their factories.
- **Gate:** `cd contracts && forge test` fully green, including fork suite.

### Milestone G — Circles backend + frontend, feature-flagged (spec §7, §11, §14.7)
- `POST /circles/:id/activate` (factory deploy via ops key — testnet/fork only until checkpoint #3+#4 clear), contribute flow (resolve `[VERIFY]` contribute-tx pattern first — checkpoint #5), claim endpoint, keeper jobs exactly per spec §14.7 (sequential settle, current-round-if-full), indexer for all CircleVault events → ledger splits per `MemberSettled`.
- Circle UI per spec §12: round timeline, grace countdown, compliance list, admin Claim, reputation strikes surfaced pre-join, yield display from `memberValue()`.
- **Gate:** full circle lifecycle (both modes, incl. one delinquent member and one cancellation) green on a Base fork; flag stays OFF.

### Milestone H — Streaks, notifications, polish (spec §9, §12)
- Streak events fire only on **confirmed** deposits/contributions (webhook handlers, not request handlers).
- New notification types per §9 incl. weekly real-yield summary; dashboard hero totals; activity page pending/confirmed states; disclosure copy everywhere earnings appear; "How your money earns" lesson.
- **Gate:** `pnpm run typecheck && pnpm run build` green; OpenAPI regenerated (`pnpm --filter @workspace/api-spec run codegen`); manual pass of §12's banned-words rule across every screen.

### Milestone I — Hardening
- `reconcilePositions` hourly job + drift alerts; dead-letter replay; rate limits (onramp daily cap, circle-creation cap); runbook stubs (Privy outage, RPC outage, Morpho illiquidity: check `available_liquidity_usd` before large withdrawals).
- **Gate:** spec §17 go-live checklist items that are automatable are automated; the rest listed in a `LAUNCH.md` for the human.

## 6. Environment variables (ask the human for values; never invent)

```
BASE_RPC_URL=                # paid RPC endpoint
PRIVY_APP_ID=                VITE_PRIVY_APP_ID=
PRIVY_APP_SECRET=
PRIVY_AUTHORIZATION_KEY=     # if wallet owners enabled [VERIFY]
PRIVY_VAULT_ID=              MORPHO_VAULT_ADDRESS=      # must reference the same vault
PRIVY_WEBHOOK_SECRET=
CIRCLE_FACTORY_ADDRESS=      VAULT_REGISTRY_ADDRESS=    # after Milestone-E deploy approval
TREASURY_ADDRESS=            GUARDIAN_ADDRESS=          OWNER_ADDRESS=   # human-confirmed, never deployer
KEEPER_PRIVATE_KEY=          # gas-only key
BASE_BUILDER_CODE=           VITE_BASE_BUILDER_CODE=
CIRCLES_ENABLED=false
DATABASE_URL=
```

## 7. Definition of done

All milestone gates passed; five money flows (spec §3) proven with real money by the human: card → balance, balance → goal → yield → withdraw − 2%, circle contribute → settle (fork), cash out; reconciliation clean; no mock data anywhere (`grep -ri "mock\|fake\|dummy" src` in money paths → zero); no banned vocabulary in UI; circles flag OFF pending audit; `LAUNCH.md` lists every remaining human task.

If anything in this prompt is ambiguous, the spec (`docs/base-mainnet-architecture.md`) resolves it. If the spec is ambiguous, **ask — never assume.**
