# Moolahub — Base Mainnet Production Architecture

**Status:** Draft v1 · July 16, 2026
**Supersedes:** `docs/monad-migration-plan.md` and `docs/monad-build-plan.md` (Monad migration cancelled — Base Mainnet is the launch chain).
**Owner:** Jerry
**Repo:** https://github.com/Moolahubio/app

---

## 0. Decisions locked (July 16, 2026)

| Decision | Choice |
|---|---|
| Chain | **Base Mainnet (8453)** — replaces Monad plan entirely. No testnet references anywhere in product code or copy. |
| Wallets | **Privy embedded wallets, non-custodial** (keys in Privy TEE, user-controlled). The current server-side `private_key_enc` custom wallet is **eliminated**. |
| Gas | **App-sponsored everywhere** (Privy gas sponsorship, app-pays mode). Users never see gas, addresses, or the word "blockchain." |
| Personal goal yield | **Privy Earn** → Morpho USDC vault on Base. One wallet per user, one Earn position; goals are **ledger-split share allocations**. Deposits/withdrawals go directly to/from the Morpho vault. |
| Group savings | **On-chain `MoolaHubCircleVault`** (one clone per circle). Contributions collect into the contract and are atomically deposited into the same Morpho vault; settlement redeems from Morpho and distributes to members. Requires audit before launch. |
| Rotating float yield | Round recipient gets **pot + yield accrued during the round**. |
| Missed rotating contribution | **Grace period → strike → stall/cancel** (carried from current SusuEscrow rules). |
| Accumulation delinquency | Miss ≥1 round → forfeit all yield; receive `principal − 2% × principal` (under a Morpho loss: `redeemed − 2% × redeemed`, since principal may not be fully there). Forfeited yield (as of the settlement snapshot) redistributed pro-rata to compliant members. |
| Fees | **2% of withdrawal amount** (compliant: 2% of principal+yield; delinquent: 2% of principal; cancellation: fee-free). |
| On-ramp | **Stripe + MoonPay via Privy `useFiatOnramp`**. Moolahub collects no KYC (providers handle identity checks in their own flow). No Bridge bank deposits (would require a Moolahub KYC program). |
| Off-ramp | **Deferred to phase 2.** Withdrawal to external wallet address ships at launch; the off-ramp slot is designed but unfilled. |
| Yield accuracy | **No mock data.** All displayed yield derives from Privy position API (`assets_in_vault − (total_deposited − total_withdrawn)`) or on-chain `convertToAssets(shares) − principal`. |
| Ledger | The double-entry ledger (`ledger_accounts` + `postings`, integer cents) **remains the source of truth**. On-chain calls are best-effort; no request path throws on RPC failure. |

---

## 1. Executive summary

Moolahub becomes a production savings app on Base Mainnet where users save in USD (USDC under the hood), earn real Morpho lending yield on both personal goals and group circles, fund their account with a debit card, and withdraw at any time — without ever encountering gas, seed phrases, addresses, or crypto vocabulary.

Two money paths, one yield source:

1. **Personal goals** — user's own Privy wallet ⇄ Morpho vault via **Privy Earn API** (approval + deposit handled by Privy in one call, gas auto-sponsored).
2. **Circles (group savings)** — member wallets → **`MoolaHubCircleVault`** contract → same Morpho vault via direct ERC-4626 calls. The contract enforces rounds, payouts, forfeiture, and distribution; a backend keeper triggers settlements so users experience them as automatic.

Everything else — auth, streaks, notifications, learn, activity — carries over from the existing codebase with the ledger as the accounting backbone.

**What gets deleted:** server-held private keys, all Base Sepolia/testnet config, faucet/dev-funding code, `MoolaHubGoalVault` + `MoolaHubSusuEscrow` + `MoolaHubSusuAccumulation` (replaced by Privy Earn for goals and `MoolaHubCircleVault` for circles).

---

## 2. Verified platform facts (do not improvise)

All of the following were verified against the Privy docs on July 16, 2026. Anything not listed here must be re-verified before use.

| Fact | Value | Source |
|---|---|---|
| Base Mainnet chain ID | `8453` / CAIP-2 `eip155:8453` | Privy docs |
| USDC on Base | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 decimals) | Privy docs |
| Privy Earn vaults on Base (self-serve) | Gauntlet USDC Prime `0x050cE30b927Da55177A4914EC73480238BAD56f0`; Steakhouse Prime Instant `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` | docs.privy.io/wallets/actions/earn/overview |
| Earn deposit | `POST /v1/wallets/{wallet_id}/earn/ethereum/deposit` `{vault_id, amount \| raw_amount}` — Privy handles ERC-20 approval + deposit in one call | docs.privy.io/wallets/actions/earn/deposit |
| Earn withdraw | `POST /v1/wallets/{wallet_id}/earn/ethereum/withdraw` `{vault_id, amount \| raw_amount}` — up to `assets_in_vault` | docs.privy.io/wallets/actions/earn/withdraw |
| Earn position | `GET /v1/wallets/{wallet_id}/earn/ethereum/vaults?vault_id=` → `{asset, total_deposited, total_withdrawn, assets_in_vault, shares_in_vault}` | docs.privy.io/wallets/actions/earn/get-vault-position |
| Earned yield formula | `assets_in_vault − (total_deposited − total_withdrawn)` | Privy docs (verbatim) |
| Incentive claim | `POST /v1/wallets/{wallet_id}/earn/ethereum/incentive/claim` `{chain: "base"}` — chain-level, all vaults | Privy docs |
| Action lifecycle | `pending → succeeded \| rejected \| failed`; `rejected` = safe to retry (nothing broadcast); `failed` = reverted on-chain | Privy docs |
| Earn webhooks | `wallet_action.earn_deposit.succeeded`, `wallet_action.earn_withdraw.succeeded` | Privy docs |
| Gas sponsorship | App-pays mode on Base Mainnet via **EIP-7702 + paymasters** (wallets upgraded to smart accounts, no separate 4337 account needed). Earn deposit/withdraw/claim **auto-sponsored** when enabled — no extra params | docs.privy.io/wallets/gas-and-asset-management/gas/overview |
| Transfer action | `POST /v1/wallets/{wallet_id}/transfer` — USDC transfers, sponsored in app-pays mode | docs.privy.io/wallets/actions/transfer/overview |
| Fiat onramp | `useFiatOnramp().fund({source, destination})` from `@privy-io/react-auth` — providers **Stripe, Meld, MoonPay, Coinbase**, routed by availability/region. Mainnet only. Returns `'submitted' \| 'confirmed'` | docs.privy.io/wallets/funding/fiat-onramp |
| Stripe embedded onramp | Requires `@privy-io/react-auth` ≥ 3.33.1 + `@stripe/crypto`. Debit/credit, Apple Pay, Google Pay, ACH. **US only (excl. NY)**, KYC via Stripe Link (provider-side, not Moolahub). USDC on Base supported | docs.privy.io/wallets/funding/fiat-onramp |
| Earn fee wrapper | Optional: Privy deploys a wrapper capturing up to 50% of *yield* as shares to an admin wallet. `vault_id` comes from Dashboard setup. Admin wallet must be secured with an authorization key before production | docs.privy.io/wallets/actions/earn/setup |
| Earn setup prerequisite | Vault configured in Dashboard (Wallet infrastructure → Earn); copy `vault_id`; register webhook endpoint | docs.privy.io/wallets/actions/earn/setup |
| Vault details (APY/TVL/liquidity) | `GET /v1/earn/ethereum/vaults/{vault_id}` — vault-level info incl. current APY and `available_liquidity_usd`. This is the **only** permitted source for the displayed APY | docs.privy.io/wallets/actions/earn/get-vault-details |
| API hosts | Privy docs show both `api.privy.io/api/v1/...` and `auth.privy.io/api/v1/...` for Earn endpoints | **[VERIFY]** canonical host with the Node SDK — SDK preferred over raw REST |
| Base Builder Codes | ERC-8021 attribution suffix appended to tx data unlocks Base builder rewards. Privy `dataSuffix` plugin (`@privy-io/react-auth` ≥ 3.22.0 + `ox` lib) auto-appends to all **client-side** txs (EOA `transaction.data` + 4337 `userOp.callData`). Code registered at base.dev → Settings → Builder Codes. Suffix applies on all chains (fine — we're Base-only). Not supported with the wagmi adapter (we don't use wagmi) | docs.privy.io/recipes/evm/base-builder-codes |

**[VERIFY] before build:** exact Privy webhook signature-verification scheme; Node SDK package/version for `privy.wallets().earn()`; MoonPay geographic coverage for your launch markets; whether the fee wrapper's `vault_id` is required even at 0% fee.

---

## 3. System architecture

```
┌───────────────────────────────── Browser ─────────────────────────────────┐
│  moolahub-app (Vite/React)                                                │
│  Privy SDK: auth · embedded wallet · useFiatOnramp (Stripe/MoonPay)       │
│  Shows: USD balances, goals, circles, streaks. Never: gas/addresses/chain │
└───────────────┬───────────────────────────────────────────┬──────────────┘
                │ REST (api-client-react, OpenAPI codegen)   │ Privy modal
                ▼                                            ▼
┌────────────── api-server (Express 5) ──────────┐   ┌─────────────────────┐
│ routes/  · auth (Privy token) · zod validation │   │  Privy              │
│ lib/ledger.ts   double-entry, cents, SOT       │   │  · TEE key mgmt     │
│ lib/privyEarn.ts  Earn REST client             │◄──┤  · Earn API         │
│ lib/circleChain.ts  viem → CircleVault         │   │  · gas sponsorship  │
│ lib/keeper.ts   round/settlement jobs          │   │  · onramp routing   │
│ lib/onchainIndexer.ts  events → ledger         │   │  · webhooks         │
│ routes/webhooks.ts  Privy action webhooks      │   └──────────┬──────────┘
└───────┬──────────────────────────┬─────────────┘              │
        ▼                          ▼                            ▼
┌───────────────┐    ┌──────────────────────── Base Mainnet ───────────────┐
│  Postgres     │    │  USDC ── Privy Earn (user wallet positions)         │
│  (Drizzle)    │    │           └─► Morpho USDC vault (ERC-4626)  ◄─┐     │
│  ledger = SOT │    │  MoolaHubCircleVault clones ──────────────────┘     │
└───────────────┘    │  MoolaHubCircleVaultFactory · VaultRegistry         │
                     │  MoolaHubTreasury (fees) · MoolaHubReputation       │
                     └─────────────────────────────────────────────────────┘
```

### Component responsibilities

- **Frontend** never signs raw transactions or shows chain concepts. It calls Moolahub REST endpoints for everything except (a) Privy auth and (b) the onramp modal, which must run client-side.
- **api-server** owns all business rules. Every money movement writes ledger postings first (`pending`), then triggers the on-chain action, then confirms via webhook/indexer. RPC failure never fails a request — it queues a retry.
- **Privy** holds keys (TEE), executes Earn/transfer actions, sponsors gas, routes onramp providers.
- **Contracts** enforce circle rules only. Personal goals have **no Moolahub contract** — funds go straight from the user's wallet into Morpho via Privy Earn.
- **Keeper** (in-process scheduled jobs at launch; extractable later) advances rounds, triggers settlements, reconciles positions.

### The five money flows

| # | Flow | Path |
|---|---|---|
| 1 | Fund account | Card → Stripe/MoonPay (Privy modal) → USDC lands in user's wallet → indexer credits ledger `wallet_available` |
| 2 | Goal deposit | `POST /goals/:id/deposits` → Privy Earn deposit (wallet → Morpho) → webhook `succeeded` → shares assigned to goal in ledger |
| 3 | Circle contribution | `POST /circles/:id/contributions` → user wallet calls `CircleVault.contribute()` (sponsored) → contract deposits to Morpho → indexer confirms |
| 4 | Settlement/claim | Keeper (or member after grace) calls `settleRound`/`settle` → contract redeems Morpho shares → pays members/recipient − fee → indexer posts principal/yield/fee split to ledger |
| 5 | Platform withdrawal | `POST /wallet/withdrawals` from `wallet_available` → Privy transfer USDC → external address. (If available balance is short, the user explicitly withdraws from a goal first — never automatic, see §8.) |

---

## 4. Identity, onboarding & wallets

### Onboarding flow (target: < 60 seconds to funded-ready)

1. **Sign up** — email (+ optional passkey) via existing auth, or Privy social login. Existing email-verification, 2FA, passkey flows carry over unchanged.
2. **Wallet creation** — on first login, backend calls Privy to create an **embedded wallet** for the user (`wallets` row stores `privy_wallet_id` + `address`; **no private key material ever touches Moolahub**). Silent — the user sees "Setting up your account…", never "wallet".
3. **Profile** — name, avatar, savings intent (drives goal suggestions). Existing `complete-profile` page.
4. **First action prompt** — "Add money" (onramp) or "Create a goal" (deposits can wait).

### Wallet model

- One embedded wallet per user, upgraded to a smart account automatically by Privy's EIP-7702 gas sponsorship — this is transparent; no separate smart-wallet contract to manage.
- **Non-custodial guarantee:** keys live in Privy's TEE, controlled by the user's auth. Moolahub's API credentials can *initiate* actions only within configured Privy **policies** (allowlist: `earn` actions on our `vault_id`, `transfer` of USDC, calls to allowlisted CircleVault addresses). Set an authorization key as wallet owner so Privy actions require a signature Moolahub holds — and document that policy config in the runbook. **[VERIFY]** final policy JSON against Privy policy language before launch.
- The old `WalletSetupCard` / `private_key_enc` flow is deleted. Migration for existing users: created wallets are new (previous chain was a testnet; no mainnet funds exist to migrate).

### Base Builder Code attribution (ERC-8021)

Moolahub registers a Builder Code at [base.dev](https://base.dev) (Settings → Builder Codes) so Base attributes our onchain activity and pays builder rewards. Attribution is an ERC-8021 data suffix on transaction calldata — invisible to users, ignored by contracts (ABI decoding reads only the bytes it needs; trailing attribution bytes are inert).

Moolahub has **three transaction origins**, each needing its own treatment:

| Origin | Transactions | Attribution mechanism |
|---|---|---|
| Client-side (Privy React SDK) | Circle `contribute()` if the M2 spike lands client-side; any future user-signed tx | Privy `dataSuffix` plugin in `PrivyProvider` config — automatic for everything (§14.9). Requires `@privy-io/react-auth` ≥ 3.22.0 (we already require ≥ 3.33.1 for Stripe onramp) + `ox` |
| Server-initiated Privy actions | Earn deposit/withdraw/claim, USDC transfers | **[VERIFY with Privy]** — the recipe documents only the React plugin; whether wallet-action APIs accept a data suffix is undocumented. Ask Privy (§18). Not launch-blocking: rewards are additive, nothing breaks without it |
| Keeper (our own viem EOA) | `settleRound`, `beginSettlement`, `settle`, factory `createCircle` | We build the calldata ourselves — append the suffix manually (§14.9 helper) |

Onramp provider transfers (Stripe/MoonPay → user wallet) originate from provider infrastructure and cannot carry our attribution.

### Invisible-blockchain UX rules (product law)

1. All amounts render as **USD** (`$12.50`), never token units. Internally: cents in ledger, 6-dp raw USDC on the wire, 18-dp shares in Morpho accounting.
2. Never show: gas, addresses, hashes, "transaction", "wallet", "blockchain", "USDC". Say: "Add money", "Move to goal", "Cash out", "Processing…".
3. Recipients are `@username`, resolved server-side to addresses.
4. Every action returns instantly with a `pending` ledger entry; confirmation arrives via webhook → notification. Pending money is visible but marked "Processing".
5. Yield is shown as "Earnings" with live values from the position API — never an extrapolated or hardcoded number. APY shown is the vault's **current** APY from vault details, labeled "variable".

---

## 5. Funding — on-ramp (and the off-ramp slot)

### On-ramp (launch)

Client-side via Privy modal; Stripe and MoonPay enabled in the Privy Dashboard (Meld/Coinbase off). Flow:

1. User taps **Add money** → `AddMoneySheet` → amount picker ($10 minimum) → `fund()` from `useFiatOnramp` with `destination = {asset: USDC_BASE, chain: 'eip155:8453', address: userWallet}`.
2. Provider modal handles card entry, Apple/Google Pay, and **provider-side KYC** (Stripe Link / MoonPay's own). Moolahub stores no identity documents.
3. `fund()` resolves `confirmed` (show success + "money arriving shortly") or `submitted` (show pending). Client immediately `POST /funding/onramp-events` so the backend has a record to reconcile.
4. **Actual credit is trust-minimized:** the onchain indexer watches USDC `Transfer` logs to user wallet addresses; on arrival it posts `external_in → wallet_available` in the ledger and fires a "Money arrived 🎉" notification. Card settlements can take minutes; the UI's pending state covers this.

Notes: Stripe path is US-only (excl. NY) today — MoonPay covers most other regions; Privy routes by region automatically. Card purchases can take minutes→days (debit approves more reliably than credit); set expectations in UI copy.

### Crypto deposit (power users, hidden by default)

A "Receive from crypto wallet" option in settings reveals the user's address + QR. Same indexer credits it. No new infrastructure.

### Off-ramp (phase 2 — designed slot)

`POST /wallet/withdrawals` today supports `destination: {type: 'address'}` only. The API shape reserves `{type: 'bank'}`; when a provider is chosen (candidates: Bridge liquidation addresses, MoonPay sell, Coinbase offramp — all need KYC evaluation), it plugs into the same withdrawal pipeline after the Earn-withdraw leg. Nothing else changes.

---

## 6. Personal goals & yield (Privy Earn)

### Model: one wallet, one position, ledger-split goals

The user's wallet holds **one** Earn position in the configured Morpho vault (`PRIVY_VAULT_ID`). Each goal owns a slice of that position, tracked in the ledger as **share units** — the same unit Morpho uses, so attribution is exact, not estimated.

- `goal_funds` table: per goal — `principal_cents` (cost basis) and `shares_raw` (vault shares owned by this goal, 18-dp bigint as numeric string).
- **Deposit:** `POST /goals/:id/deposits {amountCents}` → **pending** ledger posting `wallet_available → goal_saved` → Privy Earn deposit for `raw_amount = cents × 10^4`. On the `wallet_action.earn_deposit.succeeded` webhook, the action's `share_amount` is credited to the goal's `shares_raw` and the posting is confirmed. (If `share_amount` is missing from the webhook payload, re-fetch the action until it's populated — never credit zero shares silently.)
- **Withdraw:** compute the goal's current value; withdraw the requested amount via Earn withdraw; on success, decrement the goal's `shares_raw` by the action's redeemed `share_amount`, post `goal_saved → wallet_available` minus `fee` posting (2% → `platform_fees`), then a sponsored USDC transfer of the fee to Treasury. Fee is taken on the withdrawal amount per business rules.
- **Goal value (live, no mocks):**
  `goal_value = assets_in_vault × goal_shares_raw / wallet_shares_total`
  `goal_yield = goal_value − goal_net_principal`
  Position fields come from the Earn position endpoint; the backend caches them in `earn_positions` (refreshed on read if older than 60s) so dashboards don't hammer Privy.
- **Invariant (reconciler-enforced):** `Σ goal_shares_raw(user) ≤ shares_in_vault(wallet)`, with any excess shares (yield dust from partial withdrawals) attributable to the user's unallocated balance. Drift beyond tolerance pages the on-call.

### Why this is exact

Shares are the vault's own accounting unit. A goal that owns 40% of the wallet's shares owns exactly 40% of `assets_in_vault`, including all accrued yield. No APY extrapolation is ever displayed as a balance.

### Fee wrapper decision

Privy's fee wrapper can route a % of *yield* to an admin wallet. Launch config: **0–10% yield share [DECIDE]** — independent of the 2% withdrawal fee. If enabled, secure the admin wallet with an authorization key (Privy requirement) and confirm `OWNER_ADDRESS`-style explicit config before deploy (per `replit.md` rule: never default to deployer).

Interaction with goal math: the fee split happens **at deposit time as shares to the admin wallet** (per Privy's deposit docs), so the user's `assets_in_vault` and `shares_in_vault` already reflect only the user's own share — the goal-value formula above is unaffected. **[VERIFY]** with a test deposit in M0 that position fields behave this way at a nonzero fee.

---

## 7. Group savings — `MoolaHubCircleVault`

One contract clone per circle (EIP-1167 via factory). Two modes, one Morpho leg. **Deposits collect into the contract and are atomically deposited into Morpho; withdrawals redeem from Morpho inside the contract and distribute to members.**

### Shared mechanics

- Members and their payout order are fixed at activation (2–50 members). Member addresses are their Privy wallets, passed by the backend at creation.
- `contribute(round)` — member wallet calls (gas-sponsored); pulls `contributionAmount` USDC and deposits into Morpho in the same transaction; records `contributed[round][member]`, `principalOf`, and minted shares.
- **USDC approval:** `contribute` uses `transferFrom`, so the member's wallet must approve the circle contract first. Because sponsored wallets are EIP-7702 smart accounts, approve + contribute are **batched into one sponsored operation** — the user sees a single "Contribute" tap. **[VERIFY in the M2 spike]** exact batching mechanism via Privy (this is the same open item as the contribute invocation pattern, §18 #3).
- **Grace, on-chain:** rotating rounds accept late contributions to any *unsettled* past round — the 48h grace is real on-chain, not just UI. Accumulation mode is strict: only the currently open round counts (a miss is permanent, per product rules). Accumulation claiming has its own fixed `CLAIM_GRACE = 7 days` after which anyone can begin settlement.
- All settlement functions are **permissionless after their time gate** (keeper calls them first for UX; any member can force if Moolahub's backend disappears — trustlessness preserved).
- Payouts push USDC; if a push fails (e.g. USDC blacklist), the amount becomes `claimable[member]` (pull) so one bad address can never brick settlement.
- Loss handling: payouts are always `min(entitlement, redeemable)`. If Morpho takes a loss, it socializes pro-rata; the contract never promises money that isn't there. UI discloses: "Earnings are variable and not guaranteed."

### Accumulation mode

- Contributions accrue shares all term; every member's money earns from day one.
- At maturity, admin taps **Claim** (→ `beginSettlement()`), or anyone after a 7-day grace. This snapshots compliance in one bounded loop (≤ 50 members): delinquent members' yield-shares move to a `forfeitPool`; compliant shares are summed.
- `settle(member)` — per member, keeper-driven:
  - **Compliant** (contributed every round): redeem own shares + pro-rata slice of `forfeitPool` → `gross`; pay `gross − 2%·gross`; fee → Treasury.
  - **Delinquent:** redeem principal-worth of shares → pay `min(principal, redeemed) − 2%·principal-basis`.
- Users experience: "Circle matured → money + earnings appeared in my account." Backend posts the full split (principal / yield / forfeited / redistributed / fee) to the ledger from the `MemberSettled` event.

### Rotating mode

- Round `r` contributions earn during the round's float.
- `settleRound(r)` — callable when all members have contributed, or after round end + grace (48h): redeems **that round's shares** → pot + float yield → pays the positional recipient − 2% fee.
- Missed contribution: grace → reputation strike (`MoolaHubReputation`) → if still short, recipient receives the partial pot and the circle can stall/cancel (fee-free refunds of unsettled rounds). Economic honesty: early recipients who stop paying are a ROSCA-inherent risk — mitigated by reputation-ordered payout positions and strikes surfaced in the join UI, never claimed to be impossible.

### Cancellation & emergencies

- `cancel()` (circle admin before start; guardian anytime): fee-free `claimRefund()` per member of all unsettled value.
- `emergencyExit()` (guardian): redeems everything from Morpho into the contract and freezes accounting for pro-rata fee-free refunds — the circuit breaker if Morpho is ever impaired. **This is the guardian's only power. There is no admin path to principal.**
- Morpho vault address is fixed per circle at creation and must be on the `VaultRegistry` allowlist — a compromised backend cannot point a circle at a malicious vault.

### Trust & audit

The contract holds pooled funds → **mainnet audit is a launch gate** (M6 in rollout). Scope: CircleVault + Factory + Registry (~500 LoC). The Morpho vault itself is Privy-listed, Gauntlet/Steakhouse-curated, and outside our audit scope.

---

## 8. Withdrawals & fees

### Withdraw from a goal → Moolahub balance
Earn withdraw (Morpho → wallet) → 2% fee posting + sponsored fee transfer to Treasury → net credits `wallet_available`. Instant-feeling; usually confirms in seconds on Base.

### Withdraw from a circle
Only via settlement rules (§7) — that's the product's discipline promise. Cancelled circles refund fee-free.

### Withdraw from platform (cash out)
`POST /wallet/withdrawals {amountCents, destination}`. Launch destination: external address (behind "Send to crypto wallet"; 2FA required, address allowlist with 24h add-delay). Pipeline: ensure `wallet_available` covers it (else prompt to withdraw from a goal first — explicit, never automatic) → Privy `transfer` action (sponsored) → webhook confirms → ledger posts `wallet_available → external_out`. Phase 2 plugs bank off-ramp into the same pipeline.

### Fee summary

| Event | Fee | Collection |
|---|---|---|
| Goal withdrawal | 2% of amount withdrawn | Sponsored USDC transfer → Treasury, ledger `platform_fees` |
| Rotating round payout | 2% of the round's gross pot (+ float yield), borne by the recipient | In-contract at `settleRound()` → Treasury |
| Accumulation settlement (compliant) | 2% of principal + yield | In-contract at `settle()` → Treasury |
| Accumulation settlement (delinquent) | 2% of principal (of redeemed amount under loss) | In-contract |
| Circle cancellation | 0 | — |
| Add money / cash out | 0 from Moolahub (providers charge their own card fees) | — |
| Yield share (optional fee wrapper) | 0–10% of yield **[DECIDE]** | Privy fee wrapper shares → admin wallet |

---

## 9. Streaks, notifications, learn

- **Streaks** — unchanged engine (`streaks`, `streak_periods`, `streak_freezes`, `streak_badges`). Qualifying events now: confirmed goal deposit, confirmed circle contribution, onramp completion (first per day). Hook point: the webhook/indexer confirmation handlers (not request handlers — a pending action that fails must not count).
- **Notifications** — existing table + service. New event types: `money_arrived`, `deposit_confirmed`, `goal_milestone` (25/50/75/100%), `yield_weekly_summary` ("Your savings earned $2.14 this week" — computed from position deltas, real data), `circle_round_open`, `circle_grace_warning`, `circle_payout`, `circle_settled`, `withdrawal_sent`. Channels: in-app + email (existing `email.ts`); push is phase 2.
- **Learn** — unchanged. Add one new lesson: "How your money earns" (explains lending yield honestly, incl. variability and that earnings aren't guaranteed — required disclosure per Privy's guidance).

---

## 10. Database schema (Drizzle deltas)

Unchanged tables: `users`, `sessions`, `passkeys`, `two_factor_challenges`, `email_verification_codes`, `password_reset_codes`, `webauthn_challenges`, `notifications`, `lessons/lesson_progress`, `streak*`, `ledger_accounts`, `postings`, `transactions` (gains new `kind` values), `circle_invites`.

### `wallets` — rewritten (breaking)

```ts
export const walletsTable = pgTable("wallets", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id, { onDelete: "cascade" }).unique(),
  privyWalletId: text("privy_wallet_id").notNull().unique(), // Privy wallet resource id
  address: text("address").notNull().unique(),               // checksummed
  chainId: integer("chain_id").notNull().default(8453),
  smartAccount: boolean("smart_account").notNull().default(true), // EIP-7702 upgraded
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});
// DELETED: privateKeyEnc, network ("base-sepolia"), fundedAt
```

### `goal_funds` — new (share-accurate goal accounting)

```ts
export const goalFundsTable = pgTable("goal_funds", {
  goalId: uuid("goal_id").primaryKey().references(() => goalsTable.id, { onDelete: "cascade" }),
  sharesRaw: numeric("shares_raw", { precision: 40, scale: 0 }).notNull().default("0"), // vault shares owned by this goal
  totalDepositedCents: integer("total_deposited_cents").notNull().default(0),
  totalWithdrawnCents: integer("total_withdrawn_cents").notNull().default(0),
  // net cost basis = totalDeposited − totalWithdrawn (derived; no separate column to drift)
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});
```

### `earn_positions` — new (cached Privy position snapshots)

```ts
export const earnPositionsTable = pgTable("earn_positions", {
  walletId: uuid("wallet_id").primaryKey().references(() => walletsTable.id, { onDelete: "cascade" }),
  vaultId: text("vault_id").notNull(),                 // PRIVY_VAULT_ID
  totalDepositedRaw: numeric("total_deposited_raw", { precision: 40, scale: 0 }).notNull(),
  totalWithdrawnRaw: numeric("total_withdrawn_raw", { precision: 40, scale: 0 }).notNull(),
  assetsInVaultRaw: numeric("assets_in_vault_raw", { precision: 40, scale: 0 }).notNull(),
  sharesInVaultRaw: numeric("shares_in_vault_raw", { precision: 40, scale: 0 }).notNull(),
  fetchedAt: timestamp("fetched_at", { withTimezone: true }).notNull().defaultNow(),
});
```

### `wallet_actions` — new (Privy action ⇄ ledger reconciliation)

```ts
export const walletActionsTable = pgTable("wallet_actions", {
  id: uuid("id").primaryKey().defaultRandom(),
  privyActionId: text("privy_action_id").notNull().unique(),
  walletId: uuid("wallet_id").notNull().references(() => walletsTable.id),
  type: text("type").notNull(),      // earn_deposit | earn_withdraw | transfer | incentive_claim
  status: text("status").notNull().default("pending"), // pending | succeeded | rejected | failed
  goalId: uuid("goal_id").references(() => goalsTable.id),
  circleId: uuid("circle_id").references(() => circlesTable.id),
  transactionId: uuid("transaction_id").references(() => transactionsTable.id),
  amountRaw: numeric("amount_raw", { precision: 40, scale: 0 }),
  shareAmountRaw: numeric("share_amount_raw", { precision: 40, scale: 0 }), // filled on success
  raw: jsonb("raw"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow().$onUpdate(() => new Date()),
});
```

### `onramp_events` — new

```ts
export const onrampEventsTable = pgTable("onramp_events", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: uuid("user_id").notNull().references(() => usersTable.id),
  provider: text("provider"),                    // stripe | moonpay (if known client-side)
  clientStatus: text("client_status").notNull(), // submitted | confirmed
  expectedCents: integer("expected_cents"),
  creditedTxHash: text("credited_tx_hash"),      // set by indexer when USDC lands
  status: text("status").notNull().default("awaiting_funds"), // awaiting_funds | credited | expired
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});
```

### `circles` / `circle_members` — extended

```ts
// circlesTable additions:
vaultAddress: text("vault_address"),          // CircleVault clone (was contractAddress — rename)
morphoVault: text("morpho_vault"),            // ERC-4626 vault the clone uses
mode: text("mode").notNull().default("rotating"), // rotating | accumulation (replaces `type`)
graceHours: integer("grace_hours").notNull().default(48), // rotating settle-grace; accumulation claim grace is the contract's CLAIM_GRACE (7 days)
settlementStatus: text("settlement_status").notNull().default("none"), // none | settling | settled

// circleMembersTable additions:
principalRaw: numeric("principal_raw", { precision: 40, scale: 0 }).notNull().default("0"),
sharesRaw: numeric("shares_raw", { precision: 40, scale: 0 }).notNull().default("0"),
compliant: boolean("compliant"),              // null until settlement snapshot
settledAt: timestamp("settled_at", { withTimezone: true }),
payoutCents: integer("payout_cents"),         // final settled amount
yieldCents: integer("yield_cents"),           // yield portion (may be negative on loss)
```

### Ledger account types (additions)

`wallet_available`, `goal_saved`, `circle_committed`, `platform_fees`, `external_in`, `external_out`, `yield_earned` (income recognition at withdrawal/settlement — unrealized yield is displayed from positions, never posted to the ledger until realized).

---

## 11. API surface

Auth: Privy access token → existing middleware. All bodies zod-validated via `lib/api-zod`; OpenAPI in `lib/api-spec` → regenerate clients.

### Unchanged
`/auth/*`, `/account/*`, `/security/*`, `/passkeys/*`, `/profile/*`, `/notifications/*`, `/learn/*`, `/streaks/*` (in `dashboard`/`activity`), `/storage/*`, `/health`.

### Wallet & funding

| Method & path | Purpose |
|---|---|
| `GET /wallet` | Balance summary: available, saved (Σ goal values), yield-to-date, pending. All from ledger + cached position. |
| `POST /wallet/setup` | Idempotent Privy wallet creation at onboarding. |
| `GET /wallet/deposit-address` | Address + QR (crypto deposit, hidden feature). |
| `POST /wallet/withdrawals` | Cash out. `{amountCents, destination: {type:'address', address}, twoFactorCode}`. |
| `POST /funding/onramp-events` | Client-reported onramp result (`submitted`/`confirmed`) for reconciliation. |
| `GET /funding/onramp-events/:id` | Poll credit status ("has my card money landed?"). |

### Goals & earn

| Method & path | Purpose |
|---|---|
| `GET /goals` / `POST /goals` / `PATCH /goals/:id` | CRUD (existing, unchanged shape + `valueCents`, `yieldCents` in responses). |
| `POST /goals/:id/deposits` | `{amountCents}` → Earn deposit. Returns `{transactionId, status:'pending'}`. |
| `POST /goals/:id/withdrawals` | `{amountCents}` → Earn withdraw + fee. Returns pending transaction. |
| `GET /goals/:id/earnings` | `{principalCents, valueCents, yieldCents, vaultApyPct, asOf}` — live position math. |
| `GET /earn/summary` | User-level: total value, total yield, current APY (for dashboard hero). |

### Circles

| Method & path | Purpose |
|---|---|
| `GET /circles` / `POST /circles` / invites | Existing + `mode`, yield fields in responses. |
| `POST /circles/:id/activate` | Locks members/order → factory deploys clone → stores `vaultAddress`. |
| `POST /circles/:id/contributions` | Sponsored `contribute()` from the member's wallet. Pending until indexer confirms. |
| `POST /circles/:id/claim` | Accumulation admin claim → `beginSettlement()` + enqueue per-member settles. |
| `GET /circles/:id/position` | Per-member live: `principalCents, valueCents, yieldCents, roundsPaid, compliant`. |
| `GET /circles/:id/rounds/:n` | Round status: contributions in, grace deadline, recipient. |

### Webhooks & internal

| Method & path | Purpose |
|---|---|
| `POST /webhooks/privy` | Signature-verified **[VERIFY scheme]**, inbox-then-ack. Handles `wallet_action.*.succeeded/rejected/failed` → ledger confirmation, share assignment, notifications, streak events. |
| Onchain indexer | USDC transfers in (onramp/deposit credit); CircleVault events: `Contributed`, `RoundSettled`, `SettlementBegan` (→ sets `circles.settlementStatus='settling'`, covering the permissionless-claim path too), `MemberSettled` (→ ledger split + `settledAt`), `Cancelled`, `EmergencyExited`. |
| Keeper jobs (in-process cron) | `settleDueRounds` (5 min), `settleMaturedCircles` (hourly), `reconcilePositions` (hourly: Privy positions vs ledger; alert on drift), `expireOnrampEvents` (24h without on-chain credit → `expired` + support notification), retry queue drain. |

Error contract: every mutation returns `202` with a `transactionId` when the money leg is async; clients subscribe to `GET /activity` polling or notifications. RPC/Privy outage → `202` + retry queue, never `500` on the user path (non-negotiable preserved).

---

## 12. Frontend structure

Stack unchanged: Vite + React, Privy React SDK (`@privy-io/react-auth` ≥ 3.33.1 + `@stripe/crypto`), api-client-react (codegen), existing design system.

### Pages (deltas only)

| Page | Change |
|---|---|
| `dashboard.tsx` | Hero: **Total savings** = available + Σ goal values (live). "Earned so far" ticker from `/earn/summary`. Add-money CTA. |
| `wallet.tsx` | Rebuilt: balance, Add money (onramp sheet), Cash out, activity. Loses all key-management UI. |
| `goals.tsx` / `goal-detail.tsx` | Each goal shows `value` + green "`+$X earned`" chip. Deposit/withdraw sheets with pending states. Disclosure footnote on earnings. |
| `circles.tsx` / `circle-detail.tsx` | Mode badge, live pot value + yield, round timeline with grace countdown, contribute CTA, admin **Claim** button at maturity, member compliance list, reputation strikes surfaced pre-join. |
| `activity.tsx` | Renders `pending/confirmed` money states; groups by day; humanized copy ("Moved $50 to Vacation"). |
| `login/register/complete-profile` | Unchanged; register gains silent wallet-setup step. |
| **Deleted** | `WalletSetupCard`, any faucet/testnet banners, network switcher. |

### New components & hooks

```
components/app/AddMoneySheet.tsx      — amount → useFiatOnramp → pending state
components/app/CashOutSheet.tsx       — 2FA + address book → POST /wallet/withdrawals
components/app/DepositSheet.tsx       — goal/circle deposit amount + confirm
components/app/EarningsChip.tsx       — "+$2.14 earned" · live, animates on refresh
components/app/PendingPill.tsx        — "Processing…" until webhook confirmation
components/app/RoundTimeline.tsx      — rotating circle round/grace visualization
hooks/useEarnSummary.ts               — polls /earn/summary (30s, only while visible)
hooks/useOnramp.ts                    — wraps useFiatOnramp + onramp-event reporting
hooks/usePendingTransactions.ts       — polls activity for pending → confirmed flips
```

`useOnchain.ts` and `lib/onchain/*` shrink to almost nothing client-side. The single possible exception is circle `contribute()`: **[VERIFY in M2 spike]** whether it runs as a client-side sponsored `sendTransaction` (batched approve+call) or a server-initiated Privy action. Everything else — balances, yield, settlement — is server-mediated; the browser holds no RPC URL and no chain logic.

---

## 13. Repo file structure (change map)

```
app/
├── contracts/
│   ├── src/
│   │   ├── MoolaHubCircleVault.sol          NEW  (replaces SusuEscrow + SusuAccumulation + GoalVault)
│   │   ├── MoolaHubCircleVaultFactory.sol   NEW  (EIP-1167 clones)
│   │   ├── MoolaHubVaultRegistry.sol        NEW  (allowlisted Morpho vaults, treasury, guardian)
│   │   ├── MoolaHubTreasury.sol             KEEP
│   │   ├── MoolaHubReputation.sol           KEEP
│   │   └── (GoalVault, SusuEscrow, SusuAccumulation, old factories → DELETE)
│   ├── script/DeployBase.s.sol              NEW  (mainnet deploy, explicit OWNER/GUARDIAN/TREASURY)
│   └── test/CircleVault.t.sol               NEW  (incl. fork tests vs real Morpho vault)
├── artifacts/api-server/src/
│   ├── lib/
│   │   ├── privy.ts                         KEEP (auth) + wallet creation
│   │   ├── privyEarn.ts                     NEW  (Earn REST client)
│   │   ├── goalFunds.ts                     NEW  (share-split accounting)
│   │   ├── circleChain.ts                   REWRITE (viem → CircleVault, Base mainnet)
│   │   ├── keeper.ts                        NEW  (cron jobs)
│   │   ├── onchainIndexer.ts                REWRITE (USDC transfers in, CircleVault events)
│   │   ├── chain.ts                         REWRITE → base.ts (chain config, no testnet)
│   │   ├── ledger.ts / money.ts / ...       KEEP (+ new posting types)
│   │   └── wallet.ts                        REWRITE (drop key handling)
│   └── routes/
│       ├── funding.ts                       NEW
│       ├── webhooks.ts                      NEW
│       ├── earn.ts                          NEW
│       ├── goals.ts / circles.ts / wallet.ts  EXTEND
│       └── onchain.ts                       DELETE (was testnet tooling)
├── artifacts/moolahub-app/src/              (see §12)
├── lib/db/src/schema/                       (see §10; + drizzle migration)
├── lib/api-spec/                            regenerate after route changes
└── docs/
    ├── base-mainnet-architecture.md         THIS DOC (source of truth)
    └── monad-*.md                           ARCHIVE → docs/archive/
```

---

## 14. Complete code — core modules

> Everything below is written to compile against solc 0.8.28 / Express 5 / viem / Drizzle as configured in this repo. Contracts must pass `forge test` + fork tests + **external audit** before mainnet. `[VERIFY]` markers are the only intentionally unresolved points.

### 14.1 `contracts/src/MoolaHubCircleVault.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amt) external returns (bool);
    function transferFrom(address from, address to, uint256 amt) external returns (bool);
    function approve(address spender, uint256 amt) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IVaultRegistry {
    function isAllowedVault(address vault) external view returns (bool);
    function treasury() external view returns (address);
    function guardian() external view returns (address);
}

/// @title MoolaHubCircleVault — group savings circle with Morpho (ERC-4626) yield
/// @notice One clone per circle. Contributions are atomically deposited into the
///         Morpho vault; settlements redeem from it and distribute to members.
/// @dev NON-CUSTODIAL INVARIANT: no owner/admin/guardian path to member principal.
///      Guardian powers: cancel (fee-free refunds) and emergencyExit (Morpho→USDC
///      circuit breaker). Nothing else.
contract MoolaHubCircleVault {
    enum Mode { ROTATING, ACCUMULATION }
    enum Status { ACTIVE, SETTLING, SETTLED, CANCELLED }

    uint256 public constant MAX_MEMBERS = 50;
    uint256 public constant BPS = 10_000;

    // ── immutable-per-clone config (set once in initialize) ──
    IERC20 public usdc;
    IERC4626 public morpho;
    IVaultRegistry public registry;
    address public admin;                 // circle creator (a member)
    Mode public mode;
    uint16 public feeBps;                 // 200 = 2%
    uint64 public startTime;
    uint64 public roundDuration;          // seconds
    uint64 public graceDuration;          // rotating: settle grace; accumulation: claim grace
    uint32 public totalRounds;
    uint256 public contributionAmount;    // USDC 6-dp per member per round
    address[] public members;             // payout order = index (round r pays members[r-1])
    mapping(address => bool) public isMember;

    // ── state ──
    Status public status;
    bool public settlementSnapshotted;    // beginSettlement ran (accumulation)
    bool public exited;                   // emergencyExit happened
    uint256 public exitAssets;            // USDC pulled out at exit
    uint256 public exitShares;            // share supply snapshot at exit
    uint256 public feeAccrued;

    mapping(address => uint256) public principalOf;          // lifetime contributed (6-dp)
    mapping(address => uint32) public contributedRounds;
    mapping(uint32 => mapping(address => bool)) public contributed;
    mapping(uint32 => uint32) public roundContribCount;
    mapping(uint32 => bool) public roundSettled;              // rotating
    mapping(uint32 => uint256) public roundShares;            // rotating: shares per open round
    mapping(uint32 => mapping(address => uint256)) public memberRoundShares; // rotating refunds
    mapping(address => uint256) public sharesOf;              // accumulation
    mapping(address => bool) public compliantMember;          // set at beginSettlement
    mapping(address => bool) public memberSettled;
    mapping(address => uint256) public claimable;             // pull-fallback payouts
    uint256 public forfeitPoolShares;                         // accumulation
    uint256 public compliantSharesTotal;                      // accumulation snapshot

    uint256 private _lock = 1;
    bool private _initialized;

    event Contributed(address indexed member, uint32 indexed round, uint256 amount, uint256 shares);
    event RoundSettled(uint32 indexed round, address indexed recipient, uint256 gross, uint256 fee);
    event SettlementBegan(uint256 compliantShares, uint256 forfeitShares);
    event MemberSettled(address indexed member, bool compliant, uint256 principal, uint256 gross, uint256 yieldPaid, uint256 yieldForfeited, uint256 fee);
    event Cancelled(address indexed by);
    event EmergencyExited(uint256 assets, uint256 shares);
    event Refunded(address indexed member, uint256 amount);
    event PayoutQueued(address indexed to, uint256 amount);
    event FeesFlushed(uint256 amount);

    error NotMember(); error NotAdmin(); error NotGuardian(); error BadState();
    error AlreadyContributed(); error RoundNotOpen(); error RoundNotDue();
    error NotMature(); error AlreadySettled(); error Reentrancy();

    modifier nonReentrant() { if (_lock != 1) revert Reentrancy(); _lock = 2; _; _lock = 1; }
    modifier onlyGuardian() { if (msg.sender != registry.guardian()) revert NotGuardian(); _; }

    /// @dev Lock the implementation contract; only clones can be initialized.
    constructor() { _initialized = true; }

    function initialize(
        address usdc_, address morpho_, address registry_, address admin_,
        Mode mode_, uint16 feeBps_, uint64 startTime_, uint64 roundDuration_,
        uint64 graceDuration_, uint32 totalRounds_, uint256 contributionAmount_,
        address[] calldata members_
    ) external {
        require(!_initialized, "init"); _initialized = true;
        require(IVaultRegistry(registry_).isAllowedVault(morpho_), "vault not allowed");
        require(IERC4626(morpho_).asset() == usdc_, "asset mismatch");
        require(startTime_ >= block.timestamp, "start in past");
        require(members_.length >= 2 && members_.length <= MAX_MEMBERS, "members");
        require(feeBps_ <= 200, "fee cap");           // hard cap = the promised 2%
        require(roundDuration_ > 0 && totalRounds_ > 0 && contributionAmount_ > 0, "params");
        if (mode_ == Mode.ROTATING) require(members_.length == totalRounds_, "rounds!=members");

        usdc = IERC20(usdc_); morpho = IERC4626(morpho_); registry = IVaultRegistry(registry_);
        admin = admin_; mode = mode_; feeBps = feeBps_; startTime = startTime_;
        roundDuration = roundDuration_; graceDuration = graceDuration_;
        totalRounds = totalRounds_; contributionAmount = contributionAmount_;

        for (uint256 i; i < members_.length; ++i) {
            require(members_[i] != address(0) && !isMember[members_[i]], "dup member");
            isMember[members_[i]] = true; members.push(members_[i]);
        }
        require(isMember[admin_], "admin not member");
        usdc.approve(morpho_, type(uint256).max);      // vault is registry-allowlisted
        status = Status.ACTIVE;
    }

    // ───────────────────────── views ─────────────────────────

    function memberCount() public view returns (uint256) { return members.length; }

    /// @return 0 before start; 1..totalRounds during; totalRounds+1 after maturity
    function currentRound() public view returns (uint32) {
        if (block.timestamp < startTime) return 0;
        uint256 r = (block.timestamp - startTime) / roundDuration + 1;
        return r > totalRounds ? totalRounds + 1 : uint32(r);
    }

    function roundEnd(uint32 r) public view returns (uint256) { return startTime + uint256(r) * roundDuration; }
    function maturity() public view returns (uint256) { return roundEnd(totalRounds); }

    /// @notice Live member value (principal + accrued yield), for UI/indexer. No mock data upstream.
    function memberValue(address m) external view returns (uint256 principal, uint256 value) {
        principal = principalOf[m];
        if (mode == Mode.ACCUMULATION) {
            value = exited
                ? (exitShares == 0 ? 0 : sharesOf[m] * exitAssets / exitShares)
                : morpho.convertToAssets(sharesOf[m]);
        } else {
            uint256 s;
            for (uint32 r = 1; r <= totalRounds; ++r) if (!roundSettled[r]) s += memberRoundShares[r][m];
            value = exited ? (exitShares == 0 ? 0 : s * exitAssets / exitShares) : morpho.convertToAssets(s);
        }
    }

    // ─────────────────────── contribute ───────────────────────

    /// @param r Round being paid. ACCUMULATION: must be the currently open round
    ///          (strict — a miss is permanent, per product rules). ROTATING: any
    ///          past-or-current unsettled round — this is the on-chain form of the
    ///          "grace period": a late member can still pay round r until it settles.
    function contribute(uint32 r) external nonReentrant {
        if (status != Status.ACTIVE) revert BadState();
        if (!isMember[msg.sender]) revert NotMember();
        uint32 cur = currentRound();
        if (r == 0 || r > totalRounds) revert RoundNotOpen();
        if (mode == Mode.ACCUMULATION) {
            if (r != cur) revert RoundNotOpen();
        } else {
            if (r > cur || roundSettled[r]) revert RoundNotOpen();
        }
        if (contributed[r][msg.sender]) revert AlreadyContributed();

        contributed[r][msg.sender] = true;
        contributedRounds[msg.sender] += 1;
        roundContribCount[r] += 1;
        principalOf[msg.sender] += contributionAmount;

        require(usdc.transferFrom(msg.sender, address(this), contributionAmount), "pull");
        uint256 shares = morpho.deposit(contributionAmount, address(this));

        if (mode == Mode.ACCUMULATION) {
            sharesOf[msg.sender] += shares;
        } else {
            roundShares[r] += shares;
            memberRoundShares[r][msg.sender] = shares;
        }
        emit Contributed(msg.sender, r, contributionAmount, shares);
    }

    // ─────────────────── rotating settlement ───────────────────

    /// @notice Pays round r's pot (+ float yield) to the positional recipient.
    ///         Callable by anyone once full, or once round end + grace has passed.
    function settleRound(uint32 r) external nonReentrant {
        if (mode != Mode.ROTATING || status != Status.ACTIVE) revert BadState();
        if (r == 0 || r > totalRounds || roundSettled[r]) revert AlreadySettled();
        if (r > 1 && !roundSettled[r - 1]) revert RoundNotDue();   // strictly sequential:
        // prevents settling the final round while earlier rounds still hold funds
        // (out-of-order settlement would flip status to SETTLED and strand them).
        bool full = roundContribCount[r] == members.length;
        if (!full && block.timestamp < roundEnd(r) + graceDuration) revert RoundNotDue();

        roundSettled[r] = true;
        uint256 shares = roundShares[r];
        roundShares[r] = 0;
        uint256 gross = shares == 0 ? 0 : _redeem(shares);
        uint256 fee = gross * feeBps / BPS;
        feeAccrued += fee;
        address recipient = members[r - 1];
        _pay(recipient, gross - fee);
        emit RoundSettled(r, recipient, gross, fee);
        if (r == totalRounds) status = Status.SETTLED;
    }

    // ────────────────── accumulation settlement ──────────────────

    uint256 public constant CLAIM_GRACE = 7 days;   // anyone may begin settlement after this

    /// @notice Admin's "Claim" (or anyone after maturity + CLAIM_GRACE). One bounded loop:
    ///         snapshots compliance, moves delinquent yield-shares to the forfeit pool.
    function beginSettlement() external nonReentrant {
        if (mode != Mode.ACCUMULATION || status != Status.ACTIVE) revert BadState();
        if (block.timestamp < maturity()) revert NotMature();
        if (msg.sender != admin && block.timestamp < maturity() + CLAIM_GRACE) revert NotAdmin();

        status = Status.SETTLING;
        settlementSnapshotted = true;
        uint256 forfeited; uint256 compliantShares;
        for (uint256 i; i < members.length; ++i) {
            address m = members[i];
            if (contributedRounds[m] == totalRounds) {
                compliantMember[m] = true;
                compliantShares += sharesOf[m];
            } else {
                // keep only principal-worth of shares; yield-worth goes to the pool
                uint256 pShares = morpho.convertToShares(principalOf[m]);
                if (pShares < sharesOf[m]) {
                    forfeited += sharesOf[m] - pShares;
                    sharesOf[m] = pShares;
                }
            }
        }
        forfeitPoolShares = forfeited;
        compliantSharesTotal = compliantShares;
        emit SettlementBegan(compliantShares, forfeited);
    }

    /// @notice Per-member settlement. Keeper calls for UX; permissionless by design.
    function settle(address m) external nonReentrant {
        if (status != Status.SETTLING) revert BadState();
        if (!isMember[m] || memberSettled[m]) revert AlreadySettled();
        memberSettled[m] = true;

        uint256 own = sharesOf[m];
        sharesOf[m] = 0;
        uint256 principal = principalOf[m];

        if (compliantMember[m]) {
            uint256 bonus = compliantSharesTotal == 0 ? 0 : forfeitPoolShares * own / compliantSharesTotal;
            uint256 gross = _redeem(own + bonus);
            uint256 fee = gross * feeBps / BPS;
            feeAccrued += fee;
            _pay(m, gross - fee);
            uint256 yieldPaid = gross > principal ? gross - principal : 0;
            emit MemberSettled(m, true, principal, gross, yieldPaid, 0, fee);
        } else {
            uint256 gross = _redeem(own);                    // ≈ principal (snapshotted)
            uint256 basis = gross < principal ? gross : principal;
            uint256 fee = basis * feeBps / BPS;
            feeAccrued += fee;
            uint256 payout = basis - fee;
            _pay(m, payout);
            // any excess over principal (yield since snapshot) stays for dust sweep
            emit MemberSettled(m, false, principal, gross, 0, gross > basis ? gross - basis : 0, fee);
        }
        _maybeFinish();
    }

    function _maybeFinish() internal {
        for (uint256 i; i < members.length; ++i) if (!memberSettled[members[i]]) return;
        status = Status.SETTLED;
    }

    // ──────────────── cancel / refunds / emergency ────────────────

    /// @notice Admin may cancel before start; guardian may cancel anytime pre-settlement.
    function cancel() external {
        if (status != Status.ACTIVE) revert BadState();
        bool adminPreStart = msg.sender == admin && block.timestamp < startTime;
        if (!adminPreStart && msg.sender != registry.guardian()) revert NotGuardian();
        status = Status.CANCELLED;
        emit Cancelled(msg.sender);
    }

    /// @notice Fee-free refund of all unsettled value after cancellation. If
    ///         cancellation (incl. emergencyExit) happened after the settlement
    ///         snapshot, compliant members' refunds include their pro-rata slice of
    ///         the forfeit pool — the pool can never be stranded.
    function claimRefund() external nonReentrant {
        if (status != Status.CANCELLED) revert BadState();
        if (!isMember[msg.sender]) revert NotMember();
        uint256 shares;
        if (mode == Mode.ACCUMULATION) {
            uint256 own = sharesOf[msg.sender]; sharesOf[msg.sender] = 0;
            shares = own;
            if (settlementSnapshotted && compliantMember[msg.sender] && compliantSharesTotal != 0) {
                shares += forfeitPoolShares * own / compliantSharesTotal;
            }
        } else {
            for (uint32 r = 1; r <= totalRounds; ++r) {
                if (!roundSettled[r]) { shares += memberRoundShares[r][msg.sender]; memberRoundShares[r][msg.sender] = 0; }
            }
        }
        if (shares == 0) return;
        uint256 amt = exited ? shares * exitAssets / exitShares : _redeem(shares);
        _pay(msg.sender, amt);
        emit Refunded(msg.sender, amt);
    }

    /// @notice Circuit breaker: pull everything out of Morpho into USDC held here,
    ///         cancel the circle, refunds become pro-rata on the exited pot.
    function emergencyExit() external onlyGuardian nonReentrant {
        if (exited || status == Status.SETTLED) revert BadState();
        uint256 total = _totalShares();
        uint256 assets = total == 0 ? 0 : morpho.redeem(total, address(this), address(this));
        exited = true; exitAssets = assets; exitShares = total;
        status = Status.CANCELLED;
        emit EmergencyExited(assets, total);
    }

    // NOTE: deliberately NO pause() — a guardian pause on contribute() could
    // manufacture missed rounds (griefing). Guardian powers remain exactly
    // cancel() and emergencyExit(), both of which only return money to members.

    // ───────────────────────── plumbing ─────────────────────────

    function _totalShares() internal view returns (uint256 s) {
        if (mode == Mode.ACCUMULATION) {
            for (uint256 i; i < members.length; ++i) s += sharesOf[members[i]];
            s += forfeitPoolShares;
        } else {
            for (uint32 r = 1; r <= totalRounds; ++r) if (!roundSettled[r]) s += roundShares[r];
        }
    }

    function _redeem(uint256 shares) internal returns (uint256 assets) {
        if (shares == 0) return 0;
        if (exited) return shares * exitAssets / exitShares;   // post-exit accounting
        assets = morpho.redeem(shares, address(this), address(this));
    }

    /// @dev Push payout; on any failure (e.g. USDC blacklist) fall back to pull.
    function _pay(address to, uint256 amt) internal {
        if (amt == 0) return;
        (bool ok, bytes memory data) = address(usdc).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amt)
        );
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) {
            claimable[to] += amt;
            emit PayoutQueued(to, amt);
        }
    }

    /// @notice Pull-fallback for queued payouts.
    function claim() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        claimable[msg.sender] = 0;
        require(usdc.transfer(msg.sender, amt), "claim");
    }

    /// @notice Anyone may flush accrued fees to the treasury.
    function flushFees() external nonReentrant {
        uint256 amt = feeAccrued; feeAccrued = 0;
        require(usdc.transfer(registry.treasury(), amt), "flush");
        emit FeesFlushed(amt);
    }

    /// @notice After full settlement, sweep residual dust (rounding + post-snapshot
    ///         delinquent yield) to the treasury. Never callable mid-life.
    function sweepDust() external nonReentrant {
        if (status != Status.SETTLED) revert BadState();
        uint256 bal = usdc.balanceOf(address(this));
        uint256 owed;                                  // queued payouts still owed
        for (uint256 i; i < members.length; ++i) owed += claimable[members[i]];
        owed += feeAccrued;
        if (bal > owed) require(usdc.transfer(registry.treasury(), bal - owed), "sweep");
    }
}
```

**Audit focus notes:** bounded loops (≤ 50 members / ≤ rounds); CEI + reentrancy guard on every external-transfer path; `min(principal, redeemed)` on delinquent payouts (loss case §7); post-`exited` math never touches Morpho; `sweepDust` subtracts queued claims; the vault address cannot change after init; `approve(max)` is to a registry-allowlisted vault only; rotating settlement is **strictly sequential** so the final-round `SETTLED` flip can never strand earlier rounds; the forfeit pool is claimable through `claimRefund` after a post-snapshot cancel/emergency-exit, so it cannot be stranded either; the implementation contract self-locks in its constructor.

**Accepted limitations (disclose to auditor & in docs):** (1) rounding dust in a *cancelled* circle is unrecoverable by design (`sweepDust` requires `SETTLED`) — bounded to wei-scale amounts; (2) delinquent members' yield accrued *between* snapshot and their `settle()` call goes to treasury via dust sweep, not to compliant members — bounded by the settlement window; (3) in rotating mode, an already-paid early recipient who later defaults keeps their pot and gets unsettled contributions refunded on cancellation — the inherent ROSCA asymmetry (§7), mitigated by reputation, never claimed to be impossible.

### 14.2 `contracts/src/MoolaHubVaultRegistry.sol` + `MoolaHubCircleVaultFactory.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract MoolaHubVaultRegistry {
    address public owner;       // ops multisig — CONFIRM EXPLICITLY BEFORE DEPLOY
    address public guardian;    // circuit-breaker key — CONFIRM EXPLICITLY
    address public treasury;    // fee recipient — CONFIRM EXPLICITLY
    mapping(address => bool) public isAllowedVault;

    event VaultAllowed(address vault, bool allowed);

    constructor(address owner_, address guardian_, address treasury_) {
        require(owner_ != address(0) && guardian_ != address(0) && treasury_ != address(0), "zero");
        owner = owner_; guardian = guardian_; treasury = treasury_;
    }
    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    function setVault(address v, bool ok) external onlyOwner { isAllowedVault[v] = ok; emit VaultAllowed(v, ok); }
    function setGuardian(address g) external onlyOwner { require(g != address(0)); guardian = g; }
    function setTreasury(address t) external onlyOwner { require(t != address(0)); treasury = t; }
    function setOwner(address o) external onlyOwner { require(o != address(0)); owner = o; }
}
```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MoolaHubCircleVault} from "./MoolaHubCircleVault.sol";

/// @dev EIP-1167 minimal-proxy factory using OZ Clones (no hand-rolled assembly —
///      keep the audit surface boring). `creator` = backend ops key (deploy-only role).
contract MoolaHubCircleVaultFactory {
    address public immutable implementation;
    address public immutable registry;
    address public creator;
    event CircleCreated(address indexed vault, address indexed admin, uint8 mode);

    constructor(address impl, address registry_, address creator_) {
        implementation = impl; registry = registry_; creator = creator_;
    }

    function createCircle(
        address usdc, address morpho, address admin, MoolaHubCircleVault.Mode mode,
        uint16 feeBps, uint64 startTime, uint64 roundDuration, uint64 graceDuration,
        uint32 totalRounds, uint256 contributionAmount, address[] calldata members
    ) external returns (address vault) {
        require(msg.sender == creator, "creator");
        vault = Clones.clone(implementation);
        MoolaHubCircleVault(vault).initialize(
            usdc, morpho, registry, admin, mode, feeBps, startTime,
            roundDuration, graceDuration, totalRounds, contributionAmount, members
        );
        emit CircleCreated(vault, admin, uint8(mode));
    }
}
```

### 14.3 `artifacts/api-server/src/lib/base.ts` — chain config (no testnet anywhere)

```ts
import { base } from "viem/chains";

export const CHAIN = base;                       // id 8453
export const CAIP2 = "eip155:8453" as const;
export const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;
export const USDC_DECIMALS = 6;

export const PRIVY_VAULT_ID = requireEnv("PRIVY_VAULT_ID");          // from Privy Dashboard (Earn setup)
export const MORPHO_VAULT_ADDRESS = requireEnv("MORPHO_VAULT_ADDRESS"); // must match the vault behind PRIVY_VAULT_ID
export const CIRCLE_FACTORY_ADDRESS = requireEnv("CIRCLE_FACTORY_ADDRESS");
export const VAULT_REGISTRY_ADDRESS = requireEnv("VAULT_REGISTRY_ADDRESS");
export const TREASURY_ADDRESS = requireEnv("TREASURY_ADDRESS");
export const BASE_RPC_URL = requireEnv("BASE_RPC_URL");              // paid endpoint, not public RPC

/** cents (ledger) ⇄ raw USDC (6dp): 1 cent = 10^4 raw */
export const centsToRaw = (cents: number): bigint => BigInt(cents) * 10_000n;
export const rawToCentsFloor = (raw: bigint): number => Number(raw / 10_000n);

function requireEnv(k: string): string {
  const v = process.env[k];
  if (!v) throw new Error(`Missing required env: ${k}`); // fail at boot, never mid-request
  return v;
}
```

### 14.4 `artifacts/api-server/src/lib/privyEarn.ts` — Earn REST client

```ts
import { PRIVY_VAULT_ID } from "./base";
import { logger } from "./logger";

const PRIVY_API = "https://api.privy.io/api/v1"; // [VERIFY] docs also show auth.privy.io — prefer the Node SDK over raw REST
const appId = process.env.PRIVY_APP_ID!;
const appSecret = process.env.PRIVY_APP_SECRET!;
const authHeader = "Basic " + Buffer.from(`${appId}:${appSecret}`).toString("base64");

// [VERIFY] wallets with an owner key require an authorization-signature header on
// deposit/withdraw/transfer. Add via Privy's signing utility once owner keys are set.

export type ActionStatus = "pending" | "succeeded" | "rejected" | "failed";

export interface EarnAction {
  id: string;
  wallet_id: string;
  type: "earn_deposit" | "earn_withdraw";
  status: ActionStatus;
  caip2: string;
  vault_id: string;
  vault_address: string;
  asset_address: string;
  raw_amount: string;
  share_amount: string | null;
  created_at: string;
}

export interface EarnPosition {
  asset: { address: string; symbol: string; decimals: number };
  total_deposited: string;
  total_withdrawn: string;
  assets_in_vault: string;   // current redeemable value incl. yield (raw units)
  shares_in_vault: string;
}

async function privyFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${PRIVY_API}${path}`, {
    ...init,
    headers: {
      "privy-app-id": appId,
      Authorization: authHeader,
      "Content-Type": "application/json",
      ...init?.headers,
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    logger.error({ path, status: res.status, body }, "privy api error");
    throw new PrivyApiError(res.status, body);
  }
  return (await res.json()) as T;
}

export class PrivyApiError extends Error {
  constructor(public status: number, body: string) { super(`Privy ${status}: ${body}`); }
}

/** Deposit raw USDC (6dp) from the wallet into the Morpho vault. Gas auto-sponsored. */
export function earnDeposit(privyWalletId: string, rawAmount: bigint): Promise<EarnAction> {
  return privyFetch(`/wallets/${privyWalletId}/earn/ethereum/deposit`, {
    method: "POST",
    body: JSON.stringify({ vault_id: PRIVY_VAULT_ID, raw_amount: rawAmount.toString() }),
  });
}

/** Withdraw raw USDC (up to assets_in_vault) back to the wallet. Gas auto-sponsored. */
export function earnWithdraw(privyWalletId: string, rawAmount: bigint): Promise<EarnAction> {
  return privyFetch(`/wallets/${privyWalletId}/earn/ethereum/withdraw`, {
    method: "POST",
    body: JSON.stringify({ vault_id: PRIVY_VAULT_ID, raw_amount: rawAmount.toString() }),
  });
}

export function getEarnPosition(privyWalletId: string): Promise<EarnPosition> {
  return privyFetch(
    `/wallets/${privyWalletId}/earn/ethereum/vaults?vault_id=${encodeURIComponent(PRIVY_VAULT_ID)}`
  );
}

export function getWalletAction(actionId: string): Promise<EarnAction> {
  return privyFetch(`/wallets/actions/${actionId}`); // [VERIFY] exact GET path in API reference
}
```

### 14.5 `artifacts/api-server/src/lib/goalFunds.ts` — share-accurate goal accounting

```ts
import { db, goalFundsTable, walletActionsTable, earnPositionsTable, walletsTable } from "@workspace/db";
import { and, eq, sql } from "drizzle-orm";
import { earnDeposit, earnWithdraw, getEarnPosition, type EarnAction } from "./privyEarn";
import { centsToRaw, rawToCentsFloor } from "./base";
import { postPending, confirmPosting, failPosting } from "./ledger"; // existing double-entry API
import { logger } from "./logger";

const POSITION_TTL_MS = 60_000;
const FEE_BPS = 200n;

/** Ledger first, chain second. Never throws on Privy/RPC failure after ledger write. */
export async function depositToGoal(userId: string, goalId: string, amountCents: number) {
  const wallet = await getWallet(userId);
  // 1) pending double-entry posting: wallet_available → goal_saved (pending)
  const tx = await postPending(userId, {
    kind: "goal_deposit", goalId, amountCents,
    debit: "wallet_available", credit: "goal_saved",
  });
  // 2) best-effort chain leg
  try {
    const action = await earnDeposit(wallet.privyWalletId, centsToRaw(amountCents));
    await recordAction(action, { walletId: wallet.id, goalId, transactionId: tx.id });
  } catch (err) {
    logger.warn({ err, goalId }, "earn deposit enqueue failed — queued for retry");
    await enqueueRetry("earn_deposit", { userId, goalId, amountCents, transactionId: tx.id });
  }
  return { transactionId: tx.id, status: "pending" as const };
}

export async function withdrawFromGoal(userId: string, goalId: string, amountCents: number) {
  const wallet = await getWallet(userId);
  const { valueCents } = await goalValue(wallet, goalId);
  if (amountCents > valueCents) throw new UserFacingError("Amount exceeds goal balance");

  const feeCents = Number((BigInt(amountCents) * FEE_BPS) / 10_000n);
  const tx = await postPending(userId, {
    kind: "goal_withdrawal", goalId, amountCents,
    debit: "goal_saved", credit: "wallet_available", feeCents,
  });
  try {
    const action = await earnWithdraw(wallet.privyWalletId, centsToRaw(amountCents));
    await recordAction(action, { walletId: wallet.id, goalId, transactionId: tx.id });
  } catch (err) {
    await enqueueRetry("earn_withdraw", { userId, goalId, amountCents, transactionId: tx.id });
  }
  return { transactionId: tx.id, status: "pending" as const, feeCents };
}

/** Called by the Privy webhook on wallet_action.earn_deposit.succeeded */
export async function onEarnDepositSucceeded(action: EarnAction) {
  const rec = await db.query.walletActionsTable.findFirst({
    where: eq(walletActionsTable.privyActionId, action.id),
  });
  if (!rec || rec.status === "succeeded") return;          // idempotent
  if (action.share_amount == null) {
    // Never credit zero shares silently — re-fetch until populated (bounded retries).
    action = await refetchUntilShares(action.id);
  }
  const shares = BigInt(action.share_amount!);
  await db.transaction(async (trx) => {
    await trx.update(walletActionsTable)
      .set({ status: "succeeded", shareAmountRaw: shares.toString(), raw: action })
      .where(eq(walletActionsTable.id, rec.id));
    if (rec.goalId) {
      await trx.update(goalFundsTable).set({
        sharesRaw: sql`${goalFundsTable.sharesRaw} + ${shares.toString()}`,
        totalDepositedCents: sql`${goalFundsTable.totalDepositedCents} + ${rawToCentsFloor(BigInt(action.raw_amount))}`,
      }).where(eq(goalFundsTable.goalId, rec.goalId));
    }
    if (rec.transactionId) await confirmPosting(trx, rec.transactionId);
  });
}

/** Called on wallet_action.earn_withdraw.succeeded. */
export async function onEarnWithdrawSucceeded(action: EarnAction) {
  const rec = await db.query.walletActionsTable.findFirst({
    where: eq(walletActionsTable.privyActionId, action.id),
  });
  if (!rec || rec.status === "succeeded") return;          // idempotent
  if (action.share_amount == null) action = await refetchUntilShares(action.id);
  const sharesRedeemed = BigInt(action.share_amount!);
  const amountCents = rawToCentsFloor(BigInt(action.raw_amount));
  await db.transaction(async (trx) => {
    await trx.update(walletActionsTable)
      .set({ status: "succeeded", shareAmountRaw: sharesRedeemed.toString(), raw: action })
      .where(eq(walletActionsTable.id, rec.id));
    if (rec.goalId) {
      // Decrement by ACTUAL shares redeemed (clamped ≥ 0 — rounding may leave dust
      // shares, which stay attributed to the goal and show up as yield).
      await trx.update(goalFundsTable).set({
        sharesRaw: sql`GREATEST(${goalFundsTable.sharesRaw} - ${sharesRedeemed.toString()}, 0)`,
        totalWithdrawnCents: sql`${goalFundsTable.totalWithdrawnCents} + ${amountCents}`,
      }).where(eq(goalFundsTable.goalId, rec.goalId));
    }
    if (rec.transactionId) await confirmPosting(trx, rec.transactionId);
  });
  // Fee leg AFTER the ledger is consistent: 2% of the withdrawn amount → Treasury
  // via a sponsored Privy transfer. If this transfer fails it retries from the queue;
  // the ledger fee posting stays pending until its own webhook confirms (never lost).
  await enqueueFeeTransfer(rec.walletId, amountCents);
}

/** Live, exact goal value from the wallet's cached (≤60s) Privy position. */
export async function goalValue(wallet: WalletRow, goalId: string) {
  const pos = await freshPosition(wallet);
  const gf = await db.query.goalFundsTable.findFirst({ where: eq(goalFundsTable.goalId, goalId) });
  if (!gf) return { valueCents: 0, principalCents: 0, yieldCents: 0 };
  const totalShares = BigInt(pos.sharesInVaultRaw);
  const goalShares = BigInt(gf.sharesRaw);
  const valueRaw = totalShares === 0n ? 0n : (BigInt(pos.assetsInVaultRaw) * goalShares) / totalShares;
  const valueCents = rawToCentsFloor(valueRaw);
  const netPrincipal = gf.totalDepositedCents - gf.totalWithdrawnCents;
  return { valueCents, principalCents: netPrincipal, yieldCents: valueCents - netPrincipal };
}

async function freshPosition(wallet: WalletRow) {
  const cached = await db.query.earnPositionsTable.findFirst({
    where: eq(earnPositionsTable.walletId, wallet.id),
  });
  if (cached && Date.now() - cached.fetchedAt.getTime() < POSITION_TTL_MS) return cached;
  const p = await getEarnPosition(wallet.privyWalletId);   // real data, straight from Privy
  const row = {
    walletId: wallet.id, vaultId: process.env.PRIVY_VAULT_ID!,
    totalDepositedRaw: p.total_deposited, totalWithdrawnRaw: p.total_withdrawn,
    assetsInVaultRaw: p.assets_in_vault, sharesInVaultRaw: p.shares_in_vault,
    fetchedAt: new Date(),
  };
  await db.insert(earnPositionsTable).values(row)
    .onConflictDoUpdate({ target: earnPositionsTable.walletId, set: row });
  return row;
}
```

### 14.6 `artifacts/api-server/src/routes/webhooks.ts`

```ts
import { Router } from "express";
import { onEarnDepositSucceeded, onEarnWithdrawSucceeded } from "../lib/goalFunds";
import { notifyUser } from "../lib/notifications";
import { recordStreakEvent } from "../lib/streaks";
import { logger } from "../lib/logger";

export const webhooksRouter = Router();

// [VERIFY] Privy webhook signature scheme (docs: API reference → Webhooks).
// Reject unsigned/invalid payloads with 401. Never trust body contents before verification.
webhooksRouter.post("/privy", verifyPrivySignature, async (req, res) => {
  // INBOX PATTERN: persist the raw event BEFORE acking, so a crash between ack and
  // processing can never lose an event (Privy won't retry after a 2xx).
  const inboxRow = await saveToInbox(req.body);          // idempotent on event id
  res.status(200).end();
  await processInboxEvent(inboxRow).catch(async (err) => {
    logger.error({ err, type: req.body?.type }, "webhook processing failed — dead-letter");
    await deadLetter(inboxRow);                          // replayable, alerts on growth
  });
});

async function processInboxEvent({ event }: InboxRow) {
  // event.data.wallet_id is a PRIVY wallet id — resolve to our user via wallets table.
  const user = await userByPrivyWalletId(event.data?.wallet_id);
  switch (event.type) {
    case "wallet_action.earn_deposit.succeeded":
      await onEarnDepositSucceeded(event.data);
      await recordStreakEvent(user.id, "deposit_confirmed");
      await notifyUser(user.id, "deposit_confirmed", event.data);
      break;
    case "wallet_action.earn_withdraw.succeeded":
      await onEarnWithdrawSucceeded(event.data);
      break;
    case "wallet_action.earn_deposit.rejected":
    case "wallet_action.earn_withdraw.rejected":
      // Nothing was broadcast — safe to retry automatically (bounded), then surface.
      await retryOrSurface(event.data, user.id);
      break;
    case "wallet_action.earn_deposit.failed":
    case "wallet_action.earn_withdraw.failed":
      await failAction(event.data, user.id);             // ledger posting → failed + notify
      break;
    case "wallet_action.transfer.succeeded":
      await onTransferSucceeded(event.data);             // cash-out + fee transfers
      break;
    default:
      logger.info({ type: event.type }, "unhandled privy webhook");
  }
}
```

### 14.7 `artifacts/api-server/src/lib/keeper.ts` — settlement jobs

```ts
import { createWalletClient, createPublicClient, http, getContract } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { CHAIN, BASE_RPC_URL } from "./base";
import { circleVaultAbi } from "./abi/circleVault";
import { db, circlesTable, circleMembersTable } from "@workspace/db";
import { and, eq, lte } from "drizzle-orm";
import { logger } from "./logger";

// Keeper key: gas-only operational key. Holds ETH for keeper txs, NEVER user funds.
const account = privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY as `0x${string}`);
const wallet = createWalletClient({ account, chain: CHAIN, transport: http(BASE_RPC_URL) });
const publicClient = createPublicClient({ chain: CHAIN, transport: http(BASE_RPC_URL) });

/** Every 5 min: settle rotating rounds that are full or past grace. */
export async function settleDueRounds() {
  const due = await db.query.circlesTable.findMany({
    where: and(eq(circlesTable.mode, "rotating"), eq(circlesTable.status, "active")),
  });
  for (const c of due) {
    if (!c.vaultAddress) continue;
    const vault = getContract({ address: c.vaultAddress as `0x${string}`, abi: circleVaultAbi, client: { public: publicClient, wallet } });
    const round = Number(await vault.read.currentRound());
    const total = Number(await vault.read.totalRounds());
    const memberCount = Number(await vault.read.memberCount());
    // Completed rounds (retrying any missed by prior runs) + the CURRENT round when
    // it's already full — settlement is strictly sequential, so stop at first failure.
    for (let r = 1; r <= Math.min(round, total); r++) {
      if (await vault.read.roundSettled([r])) continue;
      const full = Number(await vault.read.roundContribCount([r])) === memberCount;
      if (r === round && !full) break;              // current round, not full yet
      try {
        const hash = await vault.write.settleRound([r]);
        logger.info({ circle: c.id, round: r, hash }, "settleRound sent");
      } catch (err) {
        logger.warn({ err, circle: c.id, round: r }, "settleRound not due yet");
        break;                                       // sequential: don't skip ahead
      }
    }
  }
}

/** Hourly: begin + drive accumulation settlements at maturity (the Claim UX). */
export async function settleMaturedCircles() {
  const matured = await db.query.circlesTable.findMany({
    where: and(eq(circlesTable.mode, "accumulation"), eq(circlesTable.settlementStatus, "settling")),
  });
  for (const c of matured) {
    const membersRows = await db.query.circleMembersTable.findMany({ where: eq(circleMembersTable.circleId, c.id) });
    const vault = getContract({ address: c.vaultAddress as `0x${string}`, abi: circleVaultAbi, client: { public: publicClient, wallet } });
    for (const m of membersRows) {
      if (m.settledAt) continue;
      const addr = await memberWalletAddress(m.userId);   // join circle_members → wallets
      try { await vault.write.settle([addr]); }
      catch (err) { logger.warn({ err, circle: c.id, member: m.id }, "settle retry next run"); }
    }
    // Indexer picks up MemberSettled events → ledger postings + notifications + settledAt.
  }
}

/** Hourly: reconcile — Σ goal shares ≤ wallet shares; ledger vs positions drift alarms. */
export async function reconcilePositions() { /* compares earn_positions vs goal_funds sums; pages on drift */ }
```

### 14.8 `artifacts/moolahub-app/src/hooks/useOnramp.ts` + `components/app/AddMoneySheet.tsx`

```tsx
// hooks/useOnramp.ts
import { useFiatOnramp } from "@privy-io/react-auth";
import { useState } from "react";
import { api } from "../lib/api";

const USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

export function useOnramp(walletAddress: string) {
  const { fund } = useFiatOnramp();
  const [state, setState] = useState<"idle" | "open" | "pending" | "done" | "error">("idle");

  async function addMoney(amountUsd: string) {
    setState("open");
    try {
      const result = await fund({
        source: { assets: ["usd"], defaultAsset: "usd" },
        destination: { asset: USDC_BASE, chain: "eip155:8453", address: walletAddress },
        environment: "production",
        defaultAmount: amountUsd,
      });
      // Report to backend for reconciliation — actual credit happens when the
      // indexer sees USDC arrive on-chain (source of truth, not this callback).
      const evt = await api.funding.reportOnrampEvent({
        clientStatus: result.status,
        expectedCents: Math.round(parseFloat(amountUsd) * 100),
      });
      pollOnrampCredit(evt.id);   // GET /funding/onramp-events/:id until credited
      setState(result.status === "confirmed" ? "done" : "pending");
    } catch (e) {
      setState("error"); // user closed the sheet or provider declined — safe to retry
    }
  }
  return { addMoney, state };
}
```

```tsx
// components/app/AddMoneySheet.tsx
import { useState } from "react";
import { useOnramp } from "../../hooks/useOnramp";
import { Sheet, AmountInput, PrimaryButton, InfoNote } from "../ui";

export function AddMoneySheet({ walletAddress, onClose }: { walletAddress: string; onClose: () => void }) {
  const [amount, setAmount] = useState("50");
  const { addMoney, state } = useOnramp(walletAddress);

  return (
    <Sheet title="Add money" onClose={onClose}>
      <AmountInput value={amount} onChange={setAmount} min={10} presets={[10, 25, 50, 100]} />
      <InfoNote>Pay with debit card, Apple Pay, or Google Pay. Money usually arrives in a few minutes.</InfoNote>
      {state === "pending" && <InfoNote tone="progress">Payment received — your money is on its way. We'll notify you when it lands.</InfoNote>}
      {state === "done" && <InfoNote tone="success">Money added 🎉</InfoNote>}
      {state === "error" && <InfoNote tone="error">That didn't go through. No money was taken — try again.</InfoNote>}
      <PrimaryButton loading={state === "open"} onClick={() => addMoney(amount)}>
        Add ${amount}
      </PrimaryButton>
    </Sheet>
  );
}
```

### 14.9 `artifacts/moolahub-app/src/main.tsx` — Builder Code attribution (client) + `lib/attribution.ts` (keeper)

```tsx
// main.tsx — PrivyProvider at the app root (replaces the per-card provider in WalletSetupCard)
import { PrivyProvider, dataSuffix } from "@privy-io/react-auth";
import { Attribution } from "ox/erc8021";

// From base.dev → Settings → Builder Codes. Build-time constant, safe to expose.
const ERC_8021_SUFFIX = Attribution.toDataSuffix({
  codes: [import.meta.env.VITE_BASE_BUILDER_CODE],
});

export function AppRoot() {
  return (
    <PrivyProvider
      appId={import.meta.env.VITE_PRIVY_APP_ID}
      config={{
        // ...auth, embedded wallet, onramp config
        plugins: [dataSuffix(ERC_8021_SUFFIX)], // auto-appends to every client-side tx
      }}
    >
      <App />
    </PrivyProvider>
  );
}
```

```ts
// artifacts/api-server/src/lib/attribution.ts — keeper-side ERC-8021 suffix
import { Attribution } from "ox/erc8021";
import { concatHex, encodeFunctionData, type Hex } from "viem";

const SUFFIX = Attribution.toDataSuffix({ codes: [process.env.BASE_BUILDER_CODE!] }) as Hex;

/** Append the Base Builder Code suffix to hand-built calldata. Contracts ignore
 *  trailing bytes (ABI decoding is offset-based), so this is behavior-neutral. */
export const withAttribution = (data: Hex): Hex => concatHex([data, SUFFIX]);

// Keeper usage — replaces vault.write.settleRound([r]):
//   await wallet.sendTransaction({
//     to: vaultAddress,
//     data: withAttribution(encodeFunctionData({ abi: circleVaultAbi, functionName: "settleRound", args: [r] })),
//   });
```

Add a fork test (M5) asserting `contribute`/`settleRound` succeed with suffixed calldata — belt-and-braces on the "trailing bytes are inert" assumption.

### 14.10 `artifacts/moolahub-app/src/hooks/useEarnSummary.ts`

```tsx
import { useQuery } from "@tanstack/react-query";
import { api } from "../lib/api";

/** All values computed server-side from the live Privy position — never client-estimated. */
export function useEarnSummary() {
  return useQuery({
    queryKey: ["earn-summary"],
    queryFn: () => api.earn.summary(),   // { totalValueCents, totalYieldCents, vaultApyPct, asOf }
    refetchInterval: 30_000,
    refetchIntervalInBackground: false,
  });
}
```

---

## 15. Security model & invariants

1. **Non-custodial, everywhere.** User keys: Privy TEE. Goal funds: user's own wallet's Morpho position. Circle funds: CircleVault with no admin path to principal (guardian = cancel/exit only, both of which *return* money to members). Moolahub servers can never move user principal anywhere except the destinations users authorized.
2. **Ledger is the source of truth**; chain is best-effort. Every request path that touches money: ledger posting first, chain second, confirmation via webhook/indexer, retry queue on failure. No user-facing 500s from RPC.
3. **Privy policies as blast-radius control.** Wallet policies allowlist exactly: `earn` on `PRIVY_VAULT_ID`, `transfer` of USDC, and calls to registry-listed CircleVaults. A compromised API server cannot drain wallets to arbitrary addresses. **[VERIFY]** policy JSON.
4. **Explicit address ceremony before deploy** (carried from `replit.md`): `OWNER/ops multisig`, `GUARDIAN`, `TREASURY`, keeper key — confirmed by a human, never defaulted to deployer. Deploy script hard-fails on missing values.
5. **Key inventory:** Privy app secret (server env), Privy authorization key (wallet owner — HSM/secret manager), keeper EOA (gas only), ops multisig (registry owner), guardian key (cold). No user key material, ever.
6. **Financial edge cases:** Morpho loss → `min(principal, redeemable)` + pro-rata socialization + UI disclosure; Morpho illiquidity → check `available_liquidity_usd` before large withdrawals, queue if short; USDC blacklist → pull-fallback `claimable`; webhook replay → idempotent handlers keyed on `privy_action_id`; onramp mismatch → indexer credits only what actually arrives on-chain.
7. **Reconciliation:** hourly job asserts `Σ goal shares ≤ wallet shares` per user and ledger totals vs on-chain/position totals; drift beyond dust pages on-call. Monthly proof-of-funds snapshot: Σ ledger balances vs Σ (positions + CircleVault `memberValue`).
8. **Rate/abuse controls:** existing login throttles; withdrawal 2FA + address allowlist with 24h delay; onramp per-user daily cap (provider caps apply too); circle creation capped per user/day.
9. **Compliance flags (not legal advice):** yield copy must say "variable, not guaranteed, generated by a third-party lending protocol" (Privy requires the disclosure); avoid "interest/savings account" framing; ROSCA rules vary by jurisdiction — counsel review before launch marketing.

---

## 16. Environment matrix

| Variable | Value / source | Notes |
|---|---|---|
| `BASE_RPC_URL` | Paid RPC (Alchemy/QuickNode) | Never public endpoint in prod |
| `USDC_ADDRESS` | `0x8335…2913` | Constant, in code |
| `PRIVY_APP_ID` / `PRIVY_APP_SECRET` | Privy Dashboard | Server only |
| `PRIVY_AUTHORIZATION_KEY` | Privy authorization key | If wallet owners configured **[VERIFY]** |
| `PRIVY_VAULT_ID` | Dashboard → Earn setup | The Morpho vault (fee-wrapper) id |
| `MORPHO_VAULT_ADDRESS` | Must match `PRIVY_VAULT_ID`'s vault | Used by CircleVaults + registry |
| `CIRCLE_FACTORY_ADDRESS` / `VAULT_REGISTRY_ADDRESS` | Deploy output | |
| `TREASURY_ADDRESS` / `GUARDIAN_ADDRESS` / `OWNER_ADDRESS` | **Explicit human confirmation** | Never deployer default |
| `KEEPER_PRIVATE_KEY` | Secret manager | Gas-only key |
| `BASE_BUILDER_CODE` / `VITE_BASE_BUILDER_CODE` | base.dev → Settings → Builder Codes | ERC-8021 attribution (server + client); non-secret |
| `PRIVY_WEBHOOK_SECRET` | Dashboard webhook config | Signature verification |
| *(deleted)* | `*_SEPOLIA_*`, faucet keys, `private_key_enc` KMS config | Remove from all environments |

---

## 17. Rollout plan (PR-sized milestones)

| M | Scope | Gate |
|---|---|---|
| M0 | Privy Dashboard: Base mainnet app config, gas sponsorship on, Earn vault setup (pick **Gauntlet USDC Prime vs Steakhouse Prime Instant [DECIDE]**), Stripe+MoonPay onramp enabled, webhook registered; register **Base Builder Code** at base.dev | `vault_id` live; test deposit from an internal wallet round-trips; builder code issued |
| M1 | Schema migration (§10) + `base.ts` + delete testnet config/code | `pnpm run typecheck` green; no `sepolia` grep hits outside docs/archive |
| M2 | Wallet onboarding rewrite (Privy embedded, drop key custody) + spike: circle `contribute()` invocation pattern **[VERIFY §12]** | New user gets wallet silently; sponsored no-op tx confirmed |
| M3 | Goals on Privy Earn: deposit/withdraw/earnings endpoints + webhook pipeline + `goal_funds` accounting | Deposit→yield→withdraw round-trip on mainnet with real $10; yield figure matches Morpho UI |
| M4 | Onramp UI + indexer credit path + notifications | Card → balance credit end-to-end |
| M5 | CircleVault contracts + fork tests + factory/registry deploy — **behind feature flag** | `forge test` incl. fork tests; invariant suite green |
| M6 | **External audit** of contracts (§14.1–14.2) + fixes | Audit report clean; addresses ceremony done |
| M7 | Circles GA: activate/contribute/claim/settle + keeper + reputation surfacing | Full circle lifecycle on mainnet with team dogfood money |
| M8 | Hardening: reconciliation alarms, dead-letter replay UI, load test, runbooks; archive Monad docs; update `CLAUDE.md` | Go-live checklist below |

**Go-live checklist:** real-money round-trips for all five flows (§3) · reconciliation clean for 7 consecutive days · webhook dead-letter empty · on-call runbook (Privy outage, RPC outage, Morpho illiquidity, depeg) · yield disclosure copy reviewed · addresses ceremony signed off.

---

## 18. Open items

| # | Item | Owner | Blocks |
|---|---|---|---|
| 1 | Privy webhook signature scheme + Node SDK version | Eng | M3 |
| 2 | Wallet-owner authorization keys: on or off at launch? (Security ↑, ops complexity ↑) | Jerry | M2 |
| 3 | Circle `contribute()` pattern: client-side sponsored tx vs server-initiated action | Eng spike | M2 |
| 4 | Vault choice: Gauntlet USDC Prime vs Steakhouse Prime Instant (compare APY history, liquidity, TVL in Dashboard) | Jerry | M0 |
| 5 | Fee-wrapper yield share: 0% or up to 10% on top of 2% withdrawal fee | Jerry | M0 |
| 6 | MoonPay coverage vs launch markets; UX when a user's region has no provider | Product | M4 |
| 7 | Audit firm selection + booking (lead time!) | Jerry | M6 |
| 8 | Counsel review: yield disclosures + ROSCA compliance per launch market | Jerry | GA |
| 9 | Ask Privy: can server-initiated wallet actions (Earn deposit/withdraw, transfer) carry the ERC-8021 builder-code suffix? (Recipe covers the React plugin only.) Rewards-only — not launch-blocking | Eng | — |

---

*Written July 16, 2026, co-authored with Claude. Verified against Privy docs as of this date; re-verify §2 facts if implementation starts later than August 2026.*





