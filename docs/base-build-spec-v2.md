# Moolahub on Base mainnet: build spec v3 (final)

2026-10-22 · repo `e043ef1` (`feat/base-mainnet-foundation`). This revises v2 after a security red-team and a completeness review; Appendix B records what was accepted and what was rejected. Where they conflict, this spec overrides `docs/base-mainnet-architecture.md` (the "Base plan") and decisions D4, D5 and D10 in `docs/ios-app-plan.md`. Nothing has been deployed, created or signed up for.

**Non-negotiables**
1. **Ledger.** The integer-cent ledger is the source of truth for **what Moolahub owes and how money is attributed**. For balances in wallets the user controls, the chain is the truth and the ledger follows it (§3.3). A failed chain or Privy call never makes a request fail.
2. **No path to principal.** No admin, owner, guardian, signer or **server** can reach user principal. Moolahub never holds a credential that can sign for a user, and that includes Privy access tokens.
3. **Roles.** Every role is set explicitly and asserted. None defaults to the deployer.
4. **Addresses.** External addresses are full, checksummed, sourced and code-checked before wiring (Appendix A).
5. **Ghana.** No money features or yield until there is a licensed MoMo partner and BoG registration.
6. **App Store.** No currency referral rewards (3.1.5(v)). No hidden features (2.5.19). A licensed institution wherever money is managed or invested (3.2.1(viii)), which covers **Earn** as well as RWA.

## 0. Decisions

| # | Decision | Choice | Status |
|---|---|---|---|
| 1 | v1.0 scope | Cash goals and Add money. Earn only if the Earn gate (§9) passes. Cash out only if an off-ramp is contracted (B7), otherwise it's cut. No Moolahub contract in v1.0. Circles in v1.1, after the audit gate | recommended |
| 2 | Wallet | Privy embedded **EOA**, user is sole owner, passkey MFA, Privy 7702 upgrade for gas sponsorship. Remove the ERC-4337 `SmartWalletsProvider` (`Web3Provider.tsx:3,44`). No Moolahub signer | recommended |
| 3 | Money moves | The server **prepares** the request. The device **verifies** it against an allowlist built into the app and signs with Face ID. The server relays it (§2.1) | recommended |
| 4 | Identity | Keep Moolahub auth. Privy login happens once per device, inside our UI. **Privy access tokens never leave the device**; the wallet is linked by a signed nonce. Reject Moolahub-issued JWT auth, because it would let Moolahub mint wallet access | founder call |
| 5 | Vault | Privy fee wrapper over **Gauntlet USDC Prime**. Steakhouse only through a new wrapper and user re-confirmation | recommended |
| 6 | Goal fee | Drop the 2% withdrawal fee (Base plan `:22`). Performance fee **0% at launch**. Up to 10% only after counsel (Advisers Act §205, local rules) and App Review clear it, with ≥7 days' notice on-chain. Management fee 0, abdicated | founder call |
| 7 | Earn consent | One versioned consent per account, then `cash` or `earn` per goal, in cleared markets only | recommended |
| 8 | Auto-save | Cash goals: a ledger schedule. Earn goals: a scheduled one-tap confirm, and in Phase 2 a deposit-only KMS signer. Privy's deposit automation is rejected because it sweeps the whole balance | recommended |
| 9 | Locks | Soft lock with a 24h cooling-off, re-confirmed after the hold | decided |
| 10 | Earn confirmation | Polling by `reference_id`. Webhooks (Enterprise plan) only make it faster | recommended |
| 11 | Circle contracts | `MHRotatingCircle`, `MHAccumulationCircle` (EIP-1167 clones), `MHCircleFactory`, `MHCircleRegistry`, `MHReputation` and `MHGuardianCanceller`, in `contracts/src/circles/`. Retire all of `contracts/src/` (including `adapters/*` and `interfaces/*`) and both deploy scripts | recommended |
| 12 | Rotating payout | Security of σ·(n−k)·c per slot, from collateral first, then holdback. **σ = 100% by default.** **Idle USDC only, no yield** | founder call (D10) |
| 13 | Circle fees | Rotating: at most 200 bps of the gross pot, only on a successful settlement. Accumulation: at most 1,500 bps of **positive earnings**. Both 0 at launch until counsel clears them | founder call |
| 14 | Circle yield | Accumulation circles only, deposited straight into the curator vault | recommended |
| 15 | Governance | Gov Safe → OZ Timelock (48h, admin renounced) → Registry and Reputation. The Guardian restricts or cancels through `MHGuardianCanceller` and can never block its own rotation. Fees go to the Treasury Safe | recommended |
| 16 | Safe thresholds | Gov 3-of-5 (at minimum 2-of-3 with one independent signer). Guardian 2-of-4 on separate keys. Treasury 2-of-3 | founder call |
| 17 | Deployment | Gov Safe → MultiSendCallOnly → CreateX `deployCreate3`. Inert implementations first, then one atomic batch | recommended |
| 18 | Database | Supabase staging and prod in **separate orgs**. Migrations in `lib/db/migrations`. Start fresh | recommended |
| 19 | Monitoring | Sentry with allowlist scrubbing, plus cron and on-chain monitors | recommended |
| 20 | RWA | None in v1.0. A US pilot through a licensed partner after counsel and App Review sign off | recommended |
| 21 | Invisible crypto | Hide the plumbing, disclose what the product is. Technical details is a **user toggle** | decided |
| 22 | Refer & Earn | Currency commissions off, and not in the iOS binary | recommended |
| 23 | Market eligibility | Self-attested country, on-ramp KYC country and phone country. The most restrictive wins | founder call |

### 0.1 Hidden issues this spec closes

| Issue | Evidence | Fix |
|---|---|---|
| A compromised server can get Face ID to sign a swapped call, spender or destination. It can also get it to sign `permit`, EIP-3009 or Permit2 typed data (valid through ERC-1271 on 7702 wallets), or a 7702 authorization | Privy [gas setup](https://docs.privy.io/wallets/gas-and-asset-management/gas/setup) | Device verifier and user policy (§2.1) |
| A Privy access token can be exchanged for a user signing key, and the API receives these tokens today | "with a valid access token for a user, Privy returns a user key" ([user keys](https://docs.privy.io/controls/authorization-keys/keys/create/user/overview)); `routes/auth.ts:549-563,626-640` | §2.2 |
| Someone with only the user's email inbox can log in on a new device and take the wallet | Privy email-code login | Passkey MFA (§2.2) |
| The Earn admin wallet holds every wrapper role. It is authorized by "your app secret alone", and Privy "cannot reassign" it | [Earn setup](https://docs.privy.io/wallets/actions/earn/setup) | Give it a key-quorum owner first (§3.4) |
| Wrapper owner actions take effect immediately. An allocator can clear the liquidity adapter, forcing exits through `forceDeallocate` (penalty up to 2%) | Morpho `VaultV2.sol:273-297,589,770-771,789-797` | Small fixed penalty; allocator = Timelock (§3.4) |
| A Guardian with `CANCELLER_ROLE` can cancel its own removal forever | OZ `TimelockController` administers itself | `MHGuardianCanceller` (§4.1) |
| try/catch and the low-level `_pay` can be gas-griefed (the 63/64 rule) | security review #6 | No try/catch (§4.1) |
| Rotating payouts would depend on Morpho's liquidity | Gauntlet exits through a single MarketV1 adapter (Morpho API) | Rotating circles hold no yield |
| `GOAL_FEE_BPS=0` still charges 2% (`Number(x) \|\| 200`); the requeue sends twice; postings cascade-delete; internal errors return 400; the API serves `yieldApy: 4.5` | `api-server/src/lib/goals.ts:38`, `lib/settlement.ts:958-966`, `lib/db/src/schema/transactions.ts:26-28,103-104`, `lib/errors.ts:27-35`, `routes/dashboard.ts:90` | A1, A2, A4 |

## 1. Invisible crypto

**Principle:** users see dollars, goals, circles and "Processing… → Done". Wallets, addresses, gas, chains, tokens, signatures and hashes appear only when Technical details is on.

**Glossary:**

| Internal | User sees |
|---|---|
| USDC balance | **Balance ($)** |
| On-ramp | **Add money** |
| Earn deposit / withdraw | **Move to goal / Move to balance** |
| Contribute / payout | **Pay in / Your payout** |
| Off-ramp | **Cash out** |
| Pending | **Processing…** |
| Reverted | **Didn't go through, nothing was taken** |
| Yield | **Earnings (variable)** |
| Sign | **Confirm** (Face ID) |
| Gas | nothing |

**Mechanics**
- **Amounts and errors:** USD `Intl.NumberFormat` replaces the "USDC" suffix (`moolahub-app/src/lib/utils.ts:26`, `api-server/src/lib/money.ts:9`). `toUserError()` replaces raw `e.message` (`utils.ts:85-89`).
- **Delete:** the Privy and Connect-wallet gates, `switchChain`, `ensureGas` and the MON routes (`routes/wallet.ts:144-179`). `/wallet/sync` at `:171` is replaced by the indexer (A13).
- **Confirm sheet:** set `showWalletUIs:false` (`Web3Provider.tsx:29-41`) and use our own sheet.
- **Gas:** Privy's app-pays sponsorship (7702 plus a paymaster, TEE execution, prepaid credits).
  - Client-side `sponsor` is off.
  - The server sponsors only requests it prepared, with spend meters ([limits](https://docs.privy.io/recipes/gas-sponsorship-rate-limits)).
  - Pin and monitor Privy's 7702 delegate contract [VERIFY address].
- **One tap per action:** an Earn deposit approves and deposits in one call ([deposit](https://docs.privy.io/wallets/actions/earn/deposit)). Circles use one atomic `wallet_sendCalls [approve(exact), contribute]`.
- **No @username person-to-person send in v1.0:** the device can't verify an address the server supplies.
- **Copy guard:** extend `scripts/check-copy.mjs` to ban crypto and banking terms outside `technical.*` and `legal.*`, in all 7 locales. Required risk warnings live in `legal.*`.
- **Remove false claims:** `lessons-data.ts:67`, `dashboard.tsx:22,105,127`, `profile.tsx:281`, `routes/dashboard.ts:90`.

**Technical details** (Settings → Advanced): a client-side toggle any user can turn on, described in the App Review notes. It shows:
- Basescan links and "Held as USDC on Base";
- the address and its QR code;
- receive and send, with warnings (the user types the full address);
- vault shares;
- circle contracts and audits;
- key export.

**Exit without Moolahub:** an exit page and key-export guide hosted outside Moolahub's infrastructure. It covers exporting the key, adding a few cents of ETH, withdrawing from the wrapper (including `forceDeallocate`) and claiming from circles. It is tested before launch (A21).

**Disclosures** (in `legal.*`, approved by counsel):
1. **First Add money:** "Your balance is held as USDC, a US-dollar digital currency issued by Circle, in a wallet in your name. Moolahub can't move it without your confirmation. Moolahub is not a bank; your balance is not a bank deposit and is not FDIC-insured or government-backed."
2. **Balance footer:** "Held as USDC · Not a bank deposit · Not insured".
3. **Earnings:** "Variable, not guaranteed. Generated by lending through Morpho, an independent protocol. You can lose money." Show the trailing 30-day rate, calculated from the share price. Never show projections.
4. **Add money and Cash out:** the provider, fees and timing; that USDC is being bought or sold; that it can't be reversed.
5. **Circles:** the rules, the fee, and the worst case when σ < 100%. Say "Moolahub can't touch circle money" only once the audited contracts are live.
6. **Store listing and legal pages:** the entity, licences and providers. Describe it as a "digital-dollar app". Never say "savings account", "interest" or "deposit".

## 2. Wallets and authority

| Actor | Holds | Can | Cannot |
|---|---|---|---|
| User | Sole ownership of the Privy wallet (TEE), passkey MFA | Everything, including key export | — |
| Moolahub API | App secret; no signer; never a Privy access token | Prepare, relay and sponsor its own requests | Sign for a user; change a user's policy |
| Earn admin wallet | Privy wallet owned by a 2-of-3 key quorum (hardware or KMS, separate holders) | Curator actions (≥7-day timelock); claim fees | Change adapters, gates, the penalty or the management fee (all abdicated) |
| Operator / keeper | Gas-only hot keys | Create circles; call permissionless functions | Move funds |

### 2.1 Device verifier
The app binary pins:
- chain 8453 and USDC;
- `PRIVY_VAULT_ID` and the wrapper;
- in v1.1, the circle factory and implementations;
- the ramp providers' public keys.

Before Face ID, the device decodes the request and refuses it unless all of these hold:
- **Earn requests:** the `wallet_id` is the user's own, the `vault_id` is pinned, the amount equals what's on screen, a `reference_id` is present, and `privy-request-expiry` is at most now + 1h.
- **Transactions and `wallet_sendCalls`:**
  - every `to` is pinned, or is a clone address the device recomputes from the factory and `circleId`;
  - every selector is on a fixed list;
  - `approve` is for the exact amount and only to that clone;
  - a `transfer` destination comes from the provider SDK, from a provider-signed quote verified on the device, or was typed by the user;
  - value is 0.
- **Signatures:** no `personal_sign`, typed data or 7702 authorization, with two exceptions: the wallet-link template (§2.2) and Privy's 7702 upgrade to the pinned delegate [VERIFY flow].
- The confirm sheet shows the decoded values, never strings from the server.

**Defence in depth:** a Privy policy owned by the user. Privy policies deny anything not allowed and are enforced inside the TEE ([policies](https://docs.privy.io/controls/policies/overview)).
- **Allow:**
  - `earn_deposit` and `earn_withdraw` for the pinned vault;
  - USDC `transfer` and `approve`;
  - calls to pinned contracts;
  - `exportPrivateKey`, explicitly (otherwise key export is denied too).
- **Deny:** `eth_signTypedData_v4`.
- **Constrain:** `personal_sign` and `eth_sign7702Authorization` [VERIFY that Privy policies can express this].

### 2.2 Identity, tokens and prompts
- **Once per device:** a Privy email code (headless or Swift, inside our UI), then **passkey MFA**. Privy puts signing, export and recovery on a new device behind MFA, with a 15-minute window (Privy MFA docs, search result only). [VERIFY headless Swift MFA, and whether the Face ID confirm can count as the passkey assertion.]
- **Tokens:**
  - Delete `/auth/privy`, `/auth/privy/link` (`routes/auth.ts:549-563,626-640`) and `verifyPrivyToken` (`lib/privy.ts:26-29`).
  - **Linking:** the device signs `Moolahub wallet link · user:<uuid> · nonce:<128-bit, single-use, 5 min> · chain:8453 · origin:<RP host>`. The server recovers the address and reads the Privy user who owns it, using the app secret [VERIFY endpoint]. It checks the DID and email, and binds each DID to one user. Rebinding needs step-up and a 24h hold.
  - **CI check:** fails if api-server contains `user_jwts`, `authorization_context`, `authorizationContext` or `verifyAuthToken`.
  - Privy identity tokens may be sent to the server only if S0 proves they can't be used to get user keys.
- **Every money move:** Face ID, with one idempotency key.
- **Step-up:** cash out, a new destination (24h hold, enforced on the device and on the server), and breaking a lock.
- **Withdraw then act:** one Face ID prompt signs two requests that share an expiry of at most 1h. The second is relayed only after the first succeeds [VERIFY].
- **Web:** money moves on web only if S0 shows the React SDK can sign behind the same verifier. Otherwise web is read-only at launch.
- **Phase 2 signer:** a KMS key the user adds. It is limited to:
  - `earn_deposit` with `vault_id eq PRIVY_VAULT_ID`;
  - a per-request cap and an expiry;
  - a cumulative cap through [stateful policies](https://docs.privy.io/controls/policies/stateful-policies), plus server meters.

  It can never call `transfer`. The server reads the policy back before first use.

## 3. Personal savings on Privy Earn

### 3.1 Model and schema
- **Position:** one Earn position per user. Each goal owns an exact number of shares. A hidden **reserve** goal absorbs dust; it belongs to the user and counts in their Balance.
- **Modes:** `cash` (the default; an earmark on wallet USDC) or `earn` (needs consent and the market flag). In Ghana, goals are a tracker only.
- **Chart of accounts** (extends `lib/ledger.ts:24-31`):
  - `wallet:<u>`
  - `goal:<g>`: principal at cost
  - `transit:<u>`: money in flight
  - `external`
  - `yield`
  - `fees`: Moolahub revenue
  - `circle_pool:<c>`, `circle_sec:<c>:<u>`, `circle_fee:<c>`, `circle_claim:<c>:<u>`
  - `owed:<u>`
  - `referral:<u>`: frozen
- **Schema:**
  - `goals` gains `kind (goal|reserve)`, `earn_mode`, `earn_consent_at/_version`, `lock_until`, `auto_save_*` and `closed_at`. Status becomes `active|reached|closing|closed`.
  - Money columns and `postings.amount_cents` (`transactions.ts:105`) become `bigint({mode:"number"})`, with a safe-integer guard.
  - `goal_funds(shares_raw numeric(78,0), principal_cents, realized_earnings_cents, dust_micro)`.
  - `goal_movements`: status `awaiting_signature|expired|queued|submitted|succeeded|failed|cancelled|needs_review`, plus `execute_after`, a unique `reference_id`, `raw_amount`, `share_amount`, and an `idempotency_key` (unique per user) with `request_hash`.
  - New tables: `idempotency_keys`, `earn_positions`, and `webhook_inbox` (unique on `svix-id`).

### 3.2 Flows
**Deposit into an earn goal (two phases)**
1. `POST /v1/goals/:id/deposits/prepare` arrives with an Idempotency-Key. Lock the goal and create a movement in `awaiting_signature`, with `reference_id = movementId`. Return the exact Privy request body and its expiry (at most 1h).
2. The device verifies and signs. `POST …/deposits/:mid/confirm` stores the signature, posts `wallet→transit`, sets the movement to `queued` and returns 202. Privy is never called inside a request.
3. A worker relays the request once, with `privy-idempotency-key` = the movement id.
   - On a timeout or 5xx, retry the identical request.
   - If the response was lost, look the action up by `reference_id` [VERIFY the lookup, and that Privy rejects a duplicate `reference_id`].
   - Past expiry, mark it `expired` and post `transit→wallet`.
4. Settle only on a re-fetched action whose `share_amount` is non-null, confirmed at Base's `safe` head. Credit shares and principal, then post `transit→goal`.
5. If the action is `rejected` or `failed`, inspect its steps ([lifecycle](https://docs.privy.io/wallets/actions/lifecycle)), post `transit→wallet`, and show "Couldn't add $X to Car. It's back in your balance." Never re-sign silently.

**Deposit into a cash goal:** post `wallet→goal` immediately.

**Withdraw** (Privy withdraws by asset amount only, [withdraw](https://docs.privy.io/wallets/actions/earn/withdraw))
1. Withdrawable = floor(value) − amounts in flight, from a fresh read.
2. Require `ceil(x·S/A) + 1 ≤ goal shares`.
3. Each request is at most 25% of the liquidity-adapter market's liquidity; split or queue the rest.
4. Settle by the actual `share_amount`. Any rounding excess comes from the reserve.
   - Principal released: `p = floor(principal × burned / goalShares)` (all of it on a full close).
   - Earnings: `e = amount − p`.
   - Post `yield↔goal` for `e`, then `goal→wallet`.

**Close**
- Compare-and-set the goal from `active` to `closing`. Withdraw floor(value); leftover shares go to the reserve.
- If the price drops mid-close, the reserve covers the gap; otherwise the movement becomes `needs_review`.
- Never clamp (Base plan §14.5), never hard-delete, and never reverse a close (fixes `lib/goals.ts:602-685`).

**Moves between goals:** earn→earn moves shares and pro-rata principal in one database transaction. A cash↔earn move is a deposit or a withdrawal.

**Lock:** an early withdrawal waits 24h and can be cancelled; then a push asks the user to re-confirm. Copy: "Locked until 12 Dec. You can still take it out — we'll hold this for 24 hours in case you change your mind."

**Auto-save:** idempotency key `autosave:{goalId}:{periodStart}`. If the balance is short, skip and send "Top up to keep your streak". No recurring card charges.

**Delete:**
- the `/allocate`, `/release` and `*/submitted` routes;
- `requireServerCustody` (`lib/goals.ts:201`, `lib/deposits.ts:195`);
- the V1 approve-and-gas flow (`PrivyGoalForms.tsx:121-145`).

### 3.3 Display, loss, caps, outside movements
- **Value:** `floor(floor(s·A/S)/10⁴)` cents, cached for 60s, for display only.
  - Earnings = value − principal, shown even when negative.
  - If the read fails, show the last snapshot ("Updated 3 min ago"), never $0.
- **Illiquidity:** retry automatically. Copy: "Your money is safe. It's taking longer than usual — we'll finish this automatically." Moolahub never pauses withdrawals.
- **Loss:**
  - Losses are shared pro rata through shares. Copy: "Worth $X ($Y less than you added)".
  - Any make-whole is an explicit, reserve-funded entry, made only after legal review.
  - A share-price drop of more than 0.1% pauses new earn deposits.
- **Caps:**
  - Global: the lowest of $1M, 2% of the vault's TVL, and 5% of the liquidity adapter's liquidity.
  - Per user: $10k.
  - Config drift, or any pending `Submit` on the wrapper or Gauntlet, pauses deposits.
- **Outside movements:** users can move money outside the app, by key export, by a Technical-details send, or through Morpho's UI.
  - The indexer (A13) posts `external↔wallet`.
  - If wallet USDC falls below the cash-goal earmarks, cash goals shrink pro rata and the user gets a notice.
  - Share movements outside the app shrink earn goals pro rata.
  - These are reconciled; they don't page anyone.

### 3.4 Earn launch gate
**Order of setup**
1. Set up the key quorum (B4).
2. Create the admin wallet and immediately assign the quorum as its owner.
3. Create a **throwaway wrapper** at a non-zero fee for the $1 test.
4. Create the production wrapper.
5. Send the hardening transactions in this order: liquidity adapter and `maxRate`, then role changes, then the penalty, then abdications, and timelock increases last. Each step is gated by the timelocks set before it.
6. `scripts/checkEarnWrapper.ts` passes.

A later fee change is timelocked for at least 7 days. A different vault means a new wrapper.

**The wrapper must have** (checked on-chain, using `VaultV2.sol` semantics):
- **Asset and adapter:** `asset()==USDC`; a single adapter (Vault V2 adapter → Gauntlet), which is also the `liquidityAdapter`; `addAdapter`, `removeAdapter` and `setAdapterRegistry` abdicated.
- **Gates:** all four gates set to 0 and abdicated.
- **Fees:**
  - `managementFee == 0`, with its setter abdicated;
  - `performanceFee` per decision 6;
  - the fee and fee-recipient setters timelocked for at least 7 days.
- **Penalty:** `forceDeallocatePenalty(adapter) == 1e14` (0.01%), with its setter abdicated.
- **Timelocks:** every other timelocked selector that isn't abdicated (`setIsAllocator`, cap increases, `increaseTimelock`, `abdicate`) is at least 7 days. `decreaseTimelock` automatically inherits the target selector's timelock (`VaultV2.sol:306-317`).
- **Roles:**
  - owner = Gov Timelock if Privy's flows still work with it [VERIFY], otherwise the quorum-owned admin wallet;
  - curator = admin wallet;
  - allocators = {Gov Timelock} (the admin wallet only if Privy requires it [VERIFY]);
  - sentinels include the Guardian Safe;
  - no other address holds a role.
- **Other:**
  - fee recipient = Treasury Safe if Privy supports it, otherwise the admin wallet plus a weekly sweep [VERIFY];
  - `maxRate > 0`;
  - a dead deposit as the first transaction;
  - no pending `Submit`.
- **$1 test at a non-zero fee:** `share_amount == convertToShares`, and the admin's shares come only from yield.

**Worst case if keys are compromised**
- **Owner:** can swap the curator and sentinels and lower caps (blocking deposits) immediately. Everything else takes at least 7 days and is visible to monitors.
- **Allocator:** can clear the liquidity adapter, so withdrawals through Privy fail. Users can still exit through `forceDeallocate` plus redeem, paying 0.01%.
- Principal stays withdrawable; only the Privy path can degrade.

**Gauntlet USDC Prime today** (Morpho API):
- TVL $170.4M, liquidity $159.2M.
- Its three critical gates are abdicated. Its `sendAssetsGate` is not (7-day timelock); it can block deposits but not exits.
- Timelocks:
  - fees: 3 days
  - fee recipients: 0
  - penalty: 1 day (currently 0.001%)
  - `setIsAllocator`: 7 days
  - `addAdapter`: 7 days
- Two configuration changes are pending.

Any pending Gauntlet change pauses new earn deposits until it has been reviewed. For comparison, Steakhouse's allocator, fee and penalty timelocks are all 0.

### 3.5 Invariants and tests
**Invariants**, checked hourly and after every settlement. A breach caused by Moolahub pages on-call; a breach caused by the user is reconciled.
1. Σ goal shares, including the reserve, equals `shares_in_vault` after outside movements are applied.
2. Each goal's ledger balance equals its principal.
3. Transit equals the deposits in flight.
4. Wallet USDC ≥ available + cash-goal principal + transit. A shortfall triggers the pro-rata shrink.
5. Closed goals hold nothing, and no field is ever negative.
6. Nothing stays `submitted` for more than 15 minutes, and nothing is relayed after its expiry.

**Tests:**
- property tests against a simulated ERC-4626 with real rounding;
- a double tap moves money once;
- recovery by `reference_id`;
- duplicate, out-of-order and null-share webhooks;
- races;
- expiry;
- outside movements;
- a Base fork test against the real wrapper.

## 4. Circle savings (v1.1, audit-gated)

### 4.1 Contracts and constants
- **All circles:**
  - Each circle is a clone of an immutable implementation, which calls `_disableInitializers()` and holds `USDC`, `REGISTRY` and `REPUTATION` as immutables.
  - The factory clones and initializes in one transaction, and the backend trusts only `factory.isCircle`. So no `FACTORY` immutable is needed, which breaks the deploy cycle.
  - `ReentrancyGuardTransient` (OZ 5.1.0, already pinned).
  - No `receive`/`fallback`, `tx.origin`, `isContract` or signature-based membership, so 7702 wallets work.
  - **No try/catch anywhere.**
- **`_pay(to, x)`:** if `USDC.isBlacklisted(to) || USDC.paused()`, add `x` to `owed[to]` and emit `PayoutQueued`. Otherwise call `SafeERC20.safeTransfer` and revert on failure. Both views respond on Base USDC.
- **`MHReputation`:**
  - `Ownable2Step`, owned by the Timelock; constructor `(owner, factory)`.
  - `record(user, circle, round, reason)` takes LATE, MISSED, COVERED or DEFAULT. It is idempotent, never reverts for a registered reporter, and is called directly.
  - No strikes until every member has joined.
- **`MHCircleFactory`** (no owner):
  - `createRotating(p)` and `createAccumulation(p)` can be called only by `registry.operator()`, and not while `creationPaused`.
  - Each call runs `cloneDeterministic(impl, keccak256(abi.encode(circleId)))` → `reputation.setReporter(clone)` → `initialize` → `isCircle[clone]=true` → emits `CircleCreated`.
  - Exposes `predictAddress(circleId, mode)`.
- **`MHCircleRegistry`:**
  - `Ownable2Step`, owned by the Timelock (fixes the one-step `setOwner` at Base plan `:943`).
  - Fields: `operator`, `guardian`, `treasury`, `creationPaused`, `isAllowedVault`.
  - The owner calls the setters, `allowVault` and `unpauseCreation`. The Guardian calls `pauseCreation` and `disallowVault`.
- **`MHGuardianCanceller`:**
  - Holds `CANCELLER_ROLE` on the Timelock.
  - The Guardian passes the full operation (`targets, values, payloads, predecessor, salt`). The canceller recomputes the operation id and cancels it, unless **every** call in it is a rotation call (`registry.setGuardian`, `canceller.setGuardian`, or the wrapper's `setIsSentinel`).
  - Only the Timelock can call `setGuardian`.
- **Size:** each contract at most 24,576 bytes of runtime code and 49,152 bytes of initcode. CI runs `forge build --sizes`.

| Constant | Value |
|---|---|
| Members / rounds | ≤50 (the product caps at 20, `lib/circles.ts:39`) / ≤520 |
| Fees | Rotating: ≤200 bps of the gross pot. Accumulation: ≤1,500 bps of positive earnings |
| σ | 5,000–10,000 bps |
| Round / grace / cure | 7–92 days / ≥48h and shorter than a round / ≥72h |
| Join window | ≤30 days |
| Guardian extension | Extend only; ≤7 days per call, ≤30 days per circle |
| Minimum contribution, `CENT`, `VIRTUAL_SHARES`, `MIN_DEPLOY` | 1e6, 1e4, 1e6, 1e6 |

### 4.2 State
- **Config:** `circleId`, `contribution`, `feeBps`, `roundDuration`, `grace`, `cure`, `joinDeadline`, `plannedStart`, `totalRounds`, `members[]` (array order is the payout order), `slotOf`. Rotating circles add `securityBps[]`; accumulation circles add `vault` (0 means no yield) and `lockUntilMaturity`.
  - `termsHash = keccak256(abi.encode(block.chainid, address(this), params, members, securityBps))`.
- **Lifecycle:** `Pending|Active|Completed|Matured|Closed|Cancelled`, `startTime`, `joinedCount`, `extension`. Accumulation circles add a one-way `yieldOff`.
- **Per member:** `cashIn`, `cashOut`, `paidRounds`, `received`, `settled`, `owed`.
- **Rotating** (in USDC units): `sec`, `nextSettle`, `pot[r]`, `paid[r][m]`, `feeEscrow`, `claim`.
  - Invariant: `balanceOf ≥ Σsec + Σpot(unsettled) + feeEscrow + Σclaim + owedTotal`.
- **Accumulation:** tracked counters `idleAssets`, `vaultShares` and `totalShares`, never read from `balanceOf`; plus `accShares`, `principal`, `claimShares`, `forfeitShares`, `forfeitSnap`, `compliantSnap`, `compliant`, `roundFlagged`, `residualShares`.
  - Invariant: Σacc + Σclaim + forfeit + residual = `totalShares`.

### 4.3 Accumulation accounting
- **NAV:** `idleAssets + vault.previewRedeem(vaultShares)`, computed once per transaction.
- **Conversion:** `toShares(a) = a·(T+1e6)/(NAV+1)` and `toAssets(s) = s·(NAV+1)/(T+1e6)`.
- **Rounding** always goes against the member leaving or the treasury:
  - mint: floor
  - burn: ceil
  - payout and fee: floor
  - bonus and unwind: floor
  - dust: goes to residual
- **Moving funds:**
  - `deployIdle()` is a separate, permissionless function. It approves the exact amount, calls `vault.deposit`, and reverts on failure. It is never called inside `contribute`.
  - `_ensureIdle(x)` calls `vault.withdraw(x − idle)` and lets reverts bubble up. It never calls `max*`.
- **Fee:** `feeBps × max(0, gross − principal)`, charged only at settlement.
  - Never charged on contributions, `exitEarly`, refunds, cancellations or losses.
  - An in-kind settlement takes the fee pro rata from idle USDC and shares.
- **`allowVault`** (Timelock):
  - checks `asset()==USDC`;
  - checks that the receiveAssets, receiveShares and sendShares gates are abdicated;
  - checks that the `setIsAllocator` and `addAdapter` timelocks are at least 7 days;
  - needs human review too, because view functions can be spoofed.

  Monitors also track the vault's penalty and fee timelocks. `disallowVault` (Guardian) applies to new circles only. Launch cap: $25k per circle.

### 4.4 Rotating payout model
Paying slot k early effectively lends it (n−k)·c, so slot k needs security `S_k = ceil(σ_k·(n−k)·c)`. σ_k is fixed in `termsHash`.
- **Collateral first:** posted at `join` or through `depositCollateral` (it can come from a savings goal).
- **Holdback next:** `max(0, S_k − sec)` is kept back at payout.
- **Draws:** `draw = min(c, max(0, sec − reqAfter))`, where `reqAfter = ceil(σ·(remaining−1)·c)` once the member has been paid, or `S_k` before.
  - The wallet owes `c − draw`.
  - `settleRound` takes the draws itself, so a member whose wallet owes 0 is never asked to pay and never struck.
- **Cover:** after grace, an unpaid wallet portion is covered in full from security above the requirement, with a COVERED strike. There is no partial cover.
- **Stall:** after grace plus cure, anyone can call `cancelStalled`.
  - Each defaulter gets a DEFAULT strike.
  - Each defaulter's net position `E_m = max(0, cashIn − cashOut)` loses `min(E_m, c)`, which goes to the other members pro rata to their E.
  - Each member's claim is `claim_m = floor(A·E'_m/ΣE')`; the remainder goes to residual.
  - The app offers "Restart without X".
- **Policy:**
  - σ = 100% by default.
  - A "Trusted" tier at σ = 50% is opt-in only, and only if every member is KYC-verified (through the ramp or a vendor), has completed circle volume at least equal to their exposure, and has no strikes.
  - Members with the most collateral take the early slots. The organiser is not slot 1 by default.

**Worked example:** n = 6, c = $100, fee 2%, so the pot is $600 and each fee is $12.

| Cash received at payout, by slot | 1 | 2 | 3 | 4 | 5 | 6 | Wallet pays per round after payout |
|---|---|---|---|---|---|---|---|
| σ=100%, no collateral | 88 | 188 | 288 | 388 | 488 | 588 | $0 |
| σ=100%, slot 1 posts $500 | **588** | 188 | 288 | 388 | 488 | 588 | $0 |
| σ=50% | 338 | 388 | 438 | 488 | 538 | 588 | $50 |

Every honest member ends at −$12.

**Default scenarios**

| Case | Setup | Result |
|---|---|---|
| D1 | σ=100%; slot 1 "stops" after its payout | Nothing to stop: security pays rounds 2–6. No strikes; everyone ends at −$12 |
| D2 | σ=50%; slot 1 stops | Cancels at round 4. $786 of $1,200 recovered (65.5%). Slots 4–6 lose $138 each; slots 1/2/3 end +$238/+$88/+$88. Slot 1's E is 0, so no penalty applies |
| D3 | σ=100%; slot 5 stops at round 3 | Cancels. Assets = ΣE = $1,124; fees waived. Slot 5 ends at −$100; the other five share +$100 |
| D4 | σ=50%; slot 5 stops at round 3 | Creditors would lose about $75 each without the penalty; slot 5's $100 penalty is shared among them |

The join screen shows the worst case whenever σ < 100%.

**Trade-off for the founder:** at σ = 100% with no collateral, early slots get little cash at payout. A real lump sum needs either collateral or credit risk among members.

### 4.5 Functions

| Function | Caller | Rule → effect |
|---|---|---|
| `initialize(p)` | Factory, in the same transaction as the clone | Bounds checked; members unique and non-zero; rotating: `totalRounds==n` and one σ per member; vault allowlisted → `termsHash` |
| `join(terms, collateral)` | Member | Pending, `terms==termsHash`, before the deadline. The last join sets `startTime = max(now, plannedStart)` and makes the circle Active; it sets `yieldOff` if the vault was delisted |
| `cancelUnjoined()` | Anyone | Pending and past the deadline → refunds, no strikes |
| `contribute(r, maxPull)` | Member | Window open, round unpaid, pull ≤ `maxPull`; LATE strike if past grace |
| `amountDue(m, r)` | View | The exact amount to pull |
| `extendDeadline(by)` | Guardian | Extend only, within the limits |
| `claim()` / `claimOwed()` | Holder / caller | End-state claim; `claimOwed` pays the caller only |
| `sweepDonations()` / `sweepResidual()` | Anyone | Surplus → treasury; residual → treasury once every member bucket is 0 |

Functions that record strikes or stall a circle on a timer revert with `UsdcPaused` while USDC is paused.

**Rotating**
- **Window:** `nextSettle ≤ r ≤ currentRound()`.
- **`settleRound()`:** settles when the round is funded after draws, or after grace if every gap can be covered; otherwise reverts with `RoundShort`. Emits `RoundSettled(r, recipient, gross, fee, holdback, cash)`.
- **`depositCollateral`.**
- **`withdrawSecurity(a)`:** anything above the requirement while Active; everything once Completed.
- **`cancelStalled()`.**
- **`guardianCancel()`:** only while `nextSettle == 1`.
- **`flushFees()`:** once Completed. On a cancellation, fees go back into recovery.

**Accumulation**
- **Window:** the current round, or the previous round while its grace lasts.
- **`exitEarly()`:** only if `!lockUntilMaturity`. Pays min(principal, value) with no fee; the rest goes to forfeit.
- **`flagRound(r)`:** records MISSED strikes.
- **`finalize()`:** a delinquent member whose value exceeds principal keeps `floor(P·T/NAV)` shares, and the rest goes to forfeit. Takes the snapshots.
- **`settleMember(m)`:**
  - a compliant member gets `toAssets(acc + floor(forfeitSnap·acc/compliantSnap))`, minus the fee on earnings;
  - a delinquent member gets min(P, value), with no fee.
- **`settleMemberInKind(m)` / `claimInKind()`:** idle USDC plus vault shares, pro rata, when liquidity is short.
- **`emergencyExit(maxShares)`** (Guardian): sets `yieldOff` and redeems one chunk.
- **`pullFromVault(shares)`:** anyone, once `yieldOff` is set.
- **`guardianCancel()`:** while Active. No fee and no forfeits; unwinds by shares.
- **If everyone is delinquent** (`compliantSnap == 0`): pay each member `toAssets(acc)`, uncapped [founder call].

**Accumulation example:** 4 members, $100 a month, 12 rounds. At about 4.7% a year, earnings come to about 2.5% of principal. The fee here is an illustrative 10%.
- A, B and C are compliant: principal (P) $1,200, value (V) $1,230.
- D missed 2 rounds: P $1,000, V $1,025. D forfeits $25, and A, B and C get $8.33 each.
- A: gross $1,238.33, earnings $38.33, fee $3.83, net $1,234.50.
- D: $1,000, with no fee.
- After a 1% loss: no forfeit and no fee. A gets $1,188 and D gets $990.

**Errors:** NotMember, NotGuardian, NotOperator, BadConfig, BadTerms, AlreadyJoined, JoinClosed, NotPending, NotActive, BadRound, AlreadyPaid, ExceedsMaxPull, RoundShort, NotStalled, Locked, NotMatured, AlreadySettled, InsufficientSecurity, NothingToClaim, NothingOwed, NotEnded, YieldOn, UsdcPaused, ExtensionLimit.

**Liveness**
- Anyone can call any time-gated transition; the keeper just calls first.
- Without Moolahub, members need a few cents of ETH on Base (see the exit page).
- Grace (48h) is longer than the 12h OP sequencing window. Longer outages are handled with `extendDeadline`.
- Loops cover at most 50 members and stay at or under 5M gas (Base caps a transaction at 16,777,216; [Base limits](https://docs.base.org/specifications/transactions/throughput-and-limits)).

### 4.6 Backend and ledger mapping
The ledger mirrors only confirmed events (at Base's `safe` head) and never posts a payout in advance. A `circle_chain_members` table holds micro-USDC amounts as `numeric(78,0)` and reconciles `cashIn` and `cashOut` exactly every hour. The cent ledger carries floor-cents, with the dust kept in the mirror.

| Event | Ledger postings |
|---|---|
| Contribution submitted | `wallet→transit` |
| `Contributed(m, r, fromWallet, fromSecurity, late)` | `transit→circle_pool`; `circle_sec→circle_pool` |
| Collateral | `transit→circle_sec` |
| `RoundSettled` | pool → `wallet` (cash), `circle_sec` (holdback), `circle_fee` (fee) |
| `flushFees` | `circle_fee→fees` |
| `MemberSettled` / `Claimed` / `PayoutQueued` | `yield↔circle_pool` for the yield part; pool → `wallet` or `owed` |
| `CircleCancelled` | → `circle_claim`, then → `wallet` on claim |

### 4.7 Invariants, regressions and tests
**Invariants**
1. Balances ≥ tracked buckets + `owedTotal`.
2. The buckets sum correctly.
3. Σ toAssets(bucket) ≤ NAV.
4. **No admin path:** fuzzing with owner, guardian, operator, treasury and attacker actors, USDC leaves only to members. The treasury receives only settlement fees, residual and donations.
5. **Rotating:** with no defaults, each member nets −fee. At σ = 100%, no pattern of defaults costs an honest member anything.
6. **Accumulation:** Σ bonus ≤ `forfeitSnap`; a delinquent member gets at most their principal; a compliant member gets at least as much per dollar as a delinquent one; the fee is charged only on earnings.
7. From every state, a permissionless, time-gated path leads to a claim.
8. Every function uses at most 5M gas at n = 50.

**Regression register** (replaces the F1–F6 references, which aren't defined in the repo)

| ID | Legacy defect | Location | Fix |
|---|---|---|---|
| R1 | Cancellation refunds members who owe money (n=3: slot 2 gains $144, slot 3 loses $150) | `MoolaHubSusuEscrow.sol:293-325` | Unwind by net position |
| R2 | `setAdapter` is an admin path to principal | `MoolaHubSusuAccumulationV2.sol:340-371` | Function removed |
| R3 | Emergency exit uses `max*` and redeems everything at once | `ERC4626Adapter.sol:78-80`; Base plan `:847-855` | Chunked exit, in-kind claims |
| R4 | A Guardian cancel after payouts strands contributors | Base plan `:813-845` | Only while `nextSettle==1` |
| R5 | One-step registry `setOwner` | Base plan `:943` | `Ownable2Step` |
| R6 | A round can be shorter than grace | — | `MIN_ROUND` = 7 days; grace shorter than a round |
| R7 | Deploy scripts: raw key, `uint16` truncation, defaulted recipient, manual wiring | `Deploy.s.sol:30,35,45,64-68` | Scripts deleted |
| R8 | Gas-griefed try/catch and `_pay` | security review #6 | Boundary-gas test on every public function |

**Tests**
- **Unit:** every function, revert and event, plus R1–R8.
- **Fuzz:** vary n, c, σ, timing, yield or loss, and lateness. Assert the D1–D4 and accumulation numbers, and diff against a TypeScript port.
- **Invariant:** a handler with ghost accounting, at least 10k runs at depth 200, against a mock Vault V2 that can toggle illiquidity, gates, losses and rounding.
- **Base fork** (pinned block, Gauntlet, real USDC):
  - `previewRedeem` drift and `maxRedeem==0`;
  - illiquidity → chunked exit → in-kind claim;
  - the `allowVault` checks;
  - a curator fee change;
  - USDC blacklist and pause;
  - a 7702 member [VERIFY forge-std `signDelegation`];
  - gas snapshots.
- **Thresholds:**
  - Slither and Aderyn: no unresolved High or Medium; every Low triaged in writing.
  - Mutation score of at least 80% on `src/circles/`.
  - Halmos proofs of the rounding helpers.

## 5. Multisig deployment and governance

| Role | Holder | Delay | Powers |
|---|---|---|---|
| Gov Safe | 3-of-5 (at minimum 2-of-3). SafeL2 v1.4.1. Hardware keys from at least 2 vendors | Proposes to the Timelock | All changes; deployment |
| Timelock | OZ `TimelockController`. Proposer and executor: Gov. Cancellers: Gov and `MHGuardianCanceller`. Admin renounced | 48h, moving to 7 days after ~90 stable days | Owns Registry and Reputation; wrapper owner and allocator if Privy allows |
| Guardian Safe | 2-of-4, on separate keys | None | `pauseCreation`, `disallowVault`, `emergencyExit`, bounded `guardianCancel`, `extendDeadline`, cancel queued operations except its own rotation, wrapper sentinel. **Never** pauses contributions or withdrawals |
| Treasury Safe | 2-of-3 | None | Receives fees |
| Deployer | None; the Gov Safe deploys | — | Asserted to hold nothing |

**Deployment**
- **Addresses:** use CreateX `deployCreate3` with guarded salts `GovSafe ‖ 0x01 ‖ 11 random bytes`. The salts are tied to the sender and the chain, so every address is known before any initcode exists and constructors can take final addresses.
  - Sepolia addresses will differ, so there is one manifest per chain.
  - Signers hash each initcode in the batch calldata and compare it with the audited manifest. Runtime codehashes are checked after deployment.
- **Batch 1 (inert):** both circle implementations.
- **Batch 2 (atomic):**
  1. Timelock, with the Gov Safe as temporary admin;
  2. the canceller;
  3. `grantRole(CANCELLER_ROLE, canceller)`;
  4. Registry;
  5. Reputation, with the predicted Factory address as authorizer;
  6. Factory;
  7. `renounceRole(DEFAULT_ADMIN_ROLE, GovSafe)`.
- **Gas:** each batch stays at or under 10M gas, measured on a fork (Base's cap is 2^24). If batch 2 is over, move the Timelock and canceller (which own nothing yet) into batch 1.

**Scripts**
- **`script/BuildBaseBatch.s.sol`** (never broadcasts):
  - requires every role, the vault, the delay, the fee, and the expected Safe owners and thresholds, with no defaults;
  - fails on:
    - a chain other than 8453 (84532 is allowed for rehearsal);
    - the wrong USDC;
    - a zero or duplicate role, or a role equal to the sender;
    - a Safe owner, threshold, module or guard mismatch;
    - a non-USDC vault;
    - a fee above the cap;
  - writes the batch JSON and a manifest of salts, initcode hashes and addresses.
- **`test/fork/SafeDeployRehearsal.t.sol`:** runs the real Safe with pranked `approveHash` calls, then a smoke test. A Sepolia rehearsal follows.
- **`script/VerifyBase.s.sol`** (read-only) asserts:
  - codehashes;
  - `owner()==Timelock` and `pendingOwner()==0`;
  - the exact Timelock roles (the Timelock is its own only admin) and delay;
  - the registry, reputation-authorizer and factory links;
  - `initialize` reverts on the implementations;
  - no role belongs to an EOA used during deployment;
  - canonical Safes with no modules or guards;
  - an exact Sourcify match.
- **Delete** `Deploy.s.sol` and `DeployAccumulation.s.sol` (R7, plus Monad-only code).
- **CI:** pin the Foundry version and dependency SHAs (`contracts-ci.yml:42-47,71`). Verify on Sourcify, then on Basescan.

**Signing**
- Buy devices directly from the vendor, generate seeds offline, and keep metal backups in separate places.
- Each signer signs an attestation and sends a no-op test transaction.
- Before signing, check that `to` is MultiSendCallOnly, check `operation` and the nonce, and compare the `safe-tx-hashes-util` hash with the device screen.
- Never copy calldata from a UI. Keep `safe-cli` as a second interface.

**Runbook**
1. Tag the audited commit.
2. Every signer rebuilds and matches the manifest.
3. The audit report cites the hashes.
4. Rehearse on a fork, then on Sepolia.
5. Execute.
6. Run `VerifyBase`.
7. Hard-code the addresses.
8. Alert on `CallScheduled`, `Cancelled`, `RoleGranted`, `OwnershipTransferStarted`, `GuardianSet`, `TreasurySet`, `VaultAllowed`, and wrapper and Gauntlet `Submit` events.

**Playbooks**

| Incident | Response |
|---|---|
| Pause circles | Feature flag → `pauseCreation` → timelocked `setOperator` |
| Morpho impaired, or a harmful change pending | Chunked `emergencyExit` within the timelock window → `disallowVault`; pause earn deposits; prompt goal users |
| Gov signer compromised | `swapOwner`; the Guardian cancels queued changes |
| Guardian compromised | Gov schedules a rotation (48h, which the Guardian can't cancel). Meanwhile the harm is bounded: paused creation, refunded cancellations, deadline extensions |
| Privy secret leaked | Rotate it. No user signing authority exists, and the admin wallet needs the quorum |

## 6. RWA

**Phase 0 (until v1.0): nothing in the app.** Server-side only:
- `invest.*` market flags (decision 23);
- a positions-mirror schema;
- a counsel memo covering the US, UK, EU and Ghana;
- a partner sandbox spike.

Nothing dormant ships in the app binary.

**Phase 1: a US pilot through a licensed broker-dealer partner.**
- **Partner:** Dinari dShares is the leading candidate. Its docs index page doesn't state pricing, chain, transferability or SIPC status ([Dinari](https://docs.dinari.com/)), so get each of these in writing [VERIFY].
- **Products:** about 10 broad holdings plus recurring buys. Gold or T-bills only through ETFs.
- **Buy/sell flow** (built only after counsel signs off):
  - the partner runs KYC;
  - quote → order `submitted → filled | partially_filled | cancelled | rejected` → settlement;
  - market hours, with orders queued while markets are closed;
  - dividends, corporate actions and tax forms come from the partner;
  - a separate Privy wallet that only the user can sign for.
- **Records:** the partner is the record of truth. The ledger holds only the USD cash leg. Show USD values "as of" a time, with counsel-approved risk wording.

**Later phases:** EU through a MiFID partner [VERIFY Spiko on Base]; UK through an FCA-authorised partner; Ghana only after SEC licensing.

**Never:**
- DEX swaps;
- unsupported bridged gold;
- omnibus custody;
- RWAs inside Morpho or circles;
- per-trade fees before counsel signs off;
- unlicensed markets;
- calling returns "interest";
- USDY, OUSG, BUIDL or USTB.

**Blocker:** App Store 3.1.5(iv) and 3.2.1(viii). Either the partner submits the app, or App Review pre-clears it, before anything is built.

## 7. Supabase

**Projects:** staging and prod, on the Pro plan with Small compute, in **separate orgs**.
- The prod org is never connected to an MCP server or an agent. Staging MCP access is read-only.
- Turn on PITR before real money flows. Run a nightly off-site dump and a quarterly restore drill. Require org MFA ([backups](https://supabase.com/docs/guides/platform/backups)).

**Region:** Supabase has no Africa region. Put the database next to the API, after measuring latency from Replit to the US and EU poolers ([regions](https://supabase.com/docs/guides/platform/regions)).

**Connections**
- **API:** transaction pooler on :6543, as `moolahub_app.<ref>`. The code uses only transaction-scoped locks and no LISTEN or SET. [VERIFY] with the 14 e2e suites; if they fail, use session mode.
- **Worker, migrations and CI:** session pooler on :5432. Direct connections are IPv6-only ([IPv4](https://supabase.com/docs/guides/platform/ipv4-address)).
- **TLS:** `verify-full`, with the CA from `PG_CA_CERT` [VERIFY through the pooler]. Reject `sslmode` in connection URLs.

**Migrations**
- **One directory:** `lib/db/migrations`. The working tree already has `0000_baseline.sql`, `0001_lockdown_data_api.sql` and `out:"./migrations"`.
- **`0002_app_role`:**
  - the `moolahub_app` role, created NOLOGIN; LOGIN and its password are set out of band;
  - grants, and `ALTER DEFAULT PRIVILEGES FOR ROLE postgres`;
  - RLS with an `app_rw` policy for `moolahub_app`;
  - timeouts: statement 15s, lock 5s, idle in transaction 30s;
  - revoke `anon`, `authenticated` and `service_role`, including default privileges;
  - Data API off.
- **`0003_ledger_integrity`:**
  - `ON DELETE RESTRICT`;
  - an append-only trigger on postings and a `BEFORE TRUNCATE` trigger;
  - revoke UPDATE, DELETE and TRUNCATE on postings;
  - indexes.
- **Applying:** run `drizzle-kit migrate` from a protected GitHub environment. Remove `drizzle-kit push` from `scripts/post-merge.sh:4`.
- **CI (`db-ci.yml`):** `supabase start`, so the Supabase roles exist; migrate; assert grants, RLS and timeouts; run the e2e suites.

**Code:** `lib/db/src/index.ts` gets `ssl`, `max` 5, timeouts, `pool.on("error")`, and `pool.end()` on SIGTERM. The worker runs on its own Reserved VM, with row leases.

**Runbook**
1. Diff the baseline against the Replit database (`pg_dump --schema-only`).
2. Migrate staging.
3. Verify:
   - the assertions pass against the remote database;
   - `rest/v1/users` fails with the publishable key;
   - Security Advisor is clean;
   - the e2e suites pass on :6543.
4. Start fresh. If you keep anything, keep only `users`, `passkeys`, `lesson_progress` and `streak_*`; that needs the same `APP_ENCRYPTION_KEY` and passkey RP host.
5. Store an encrypted dump off Replit.
6. Run one instance, watch for 24h, then allow autoscale.

**Rollback:** before the first real-money write, revert `DATABASE_URL`. After that, roll forward only.

**After a PITR restore:**
1. Turn writes off.
2. Replay chain events from the restore block, and Privy actions by `reference_id`.
3. Reconcile.
4. Reopen.

## 8. Sentry

**API**
- `@sentry/node`, with `instrument.ts` imported first. Initialize only when `SENTRY_DSN` is set.
- Turn off every `dataCollection` option. v11 collects user info, cookies and bodies by default ([v11](https://docs.sentry.io/platforms/javascript/guides/express/migration/v10-to-v11/)).
- `expressIntegration({shouldHandleError:false})`, with explicit capture in the global handler and in `sendError`.
- Identify users by UUID only. Tag money routes `area:money`.
- One `captureDeadLetter` per reversal.
- Heartbeats for every background loop.
- `sentryEsbuildPlugin` goes last in `build.mjs`.

**Web:** `@sentry/react` with an `ErrorBoundary`; Replay off. Build hidden source maps only when a token is set, and delete them after upload. The build fails if any `.map` file is left in `dist/public`.

**Scrubbing by allowlist**, in `beforeSend`, `beforeSendSpan` and `beforeBreadcrumb` (shared `sentryScrub.ts`):
- Keep only allowlisted keys.
- Drop:
  - request and response headers and bodies;
  - outgoing Privy `Authorization` and `privy-authorization-signature` headers;
  - request configs attached to errors;
  - URL query strings;
  - `db.statement`.
- Mask `0x…` strings, emails, tokens and RPC keys.
- A CI test with a capture transport asserts that no secret or amount gets through.
- Org settings: IP storage off, 2FA, spike protection, a spend cap.

**Versions:** use the newest 11.x release that is at least 14 days old (11.8.0 qualifies from 2026-10-29). Raise `minimumReleaseAge` (`pnpm-workspace.yaml:28`, currently 1 day) to 14 days for Sentry, Privy and viem. iOS later: sentry-cocoa, with no PII and no screenshots.

**Alerts**
- New or regressed issues → Slack.
- Page the on-call rota (B10) on:
  - more than 3 `area:money` errors in 5 minutes;
  - any `settlement.dead_letter`;
  - unexplained `ledger.drift`.
- Cron monitors on every loop.
- Uptime checks on `/api/healthz`, which must check the database and the oldest pending movement (`routes/health.ts:6-9`).
- Web crash-free sessions below 99.5%.
- On-chain monitor alerts on:
  - a share-price drop;
  - a pending `Submit`;
  - Morpho warnings;
  - liquidity-adapter utilization of 99% or more for 30 minutes;
  - Chainlink USDC below 0.995;
  - Timelock and registry events.

**Environment variables:** `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_TRACES_SAMPLE_RATE`, `VITE_SENTRY_*`, `SENTRY_AUTH_TOKEN` (secret), `SENTRY_ORG`, `SENTRY_PROJECT_API/WEB`.

## 9. Implementation plan

| ID | Item | Depends on | Acceptance |
|---|---|---|---|
| S0 | Privy feasibility spike (`docs/ios-app-plan.md:70`), with a go/no-go | Privy staging app | A written answer to every Privy [VERIFY]. A no-go means re-planning before A9 and A19 |
| A1 | Money-safety fixes: `lib/goals.ts:38`, `pages/goals.tsx:40,53`, `lib/errors.ts:27-35`, `lib/streaks.ts:631-633`, fake yields including `routes/dashboard.ts:90` | — | A fee of 0 charges 0; "0.29" becomes 29¢; internal errors return 5xx; no hardcoded rates |
| A2 | Database platform (§7) | B1, for remote checks | `db-ci.yml` passes |
| A3 | Idempotency keys and hashed sessions (N1, N2) | A2 | A double tap moves money once; the same key with a different body returns 409 |
| A4 | Worker split, and **retire server custody**: the platform key, `custody='server'` and `private_key_enc` (`schema/wallets.ts:29-39`), `getSigningSecret`, the `sendUsdc`/`mintUsdc`/`goalDeposit`/`escrowContribute` sender (`lib/settlement.ts:12-13`), the hot-wallet pool, the Monad indexer | A2 | No code can sign for a user; nothing is sent twice |
| A5 | Sentry (§8) | B2 | No DSN means no traffic; the scrub test passes |
| A6 | Invisible-crypto UX and copy guard | — | The copy guard passes; no Privy modal anywhere |
| A7 | Base config, Privy SDK, EOA + 7702, remove `SmartWalletsProvider` | S0 | Root `pnpm run typecheck` reports 0 errors; no Monad code left |
| A8 | Goals v2 on a mock Earn | A3 | Property tests prove the §3.5 invariants |
| A9 | Earn client, poller, webhook inbox, chain monitor, `checkEarnWrapper.ts` | S0, B3, A8 | Recovers via `reference_id`; duplicate webhooks are no-ops; the gate script fails on any §3.4 drift |
| A10 | Market eligibility and `/v1/config` | Decision 23 | Ghana is tracker-only |
| A11 | Circle backend and keeper | C3, C4 | A lifecycle on a Base fork reconciles exactly |
| A12 | Auth hardening: delete the Privy-token routes, nonce linking, CI check; pin the passkey RP ID (`passkeys.ts:50-55`), block TOTP replay, cap attempts, N7 velocity limits, N8 payee hold | — | Each item has a passing test |
| A13 | Base USDC and share indexer; outside movements | A2 | Simulated sends and receives reconcile |
| A14 | Add money (N13) | B7 | A $10 on-ramp posts once |
| A15 | Cash out, with a device-verified destination | B7, A19 | A $10 off-ramp works; a tampered address is refused |
| A16 | Push (N5), `/v1`, `transactions/:id` (N3, N4) | A3 | iOS contract tests pass |
| A17 | Account deletion with an on-chain balance (N14; `routes/account.ts:66-70` checks only the ledger) | A13 | Nothing is confiscated |
| A18 | Turn off currency referral rewards (decision 22) | — | Not in the iOS build |
| A19 | Device verifier and user policy (iOS M3) | S0 | A corpus of tampered requests is all refused |
| A20 | CI gate: typecheck, build, e2e, database assertions, scrub test, copy guard, `forge build --sizes` | — | Required on `main` |
| A21 | Exit page and key-export guide | A9 | Dogfood an exit without Moolahub's servers |
| C1 | Retire legacy contracts, interfaces and scripts | — | Out of the build |
| C2 | Registry, Reputation, GuardianCanceller, Timelock config | C1 | R5 regression passes; a rotation-only operation can't be cancelled |
| C3 | Rotating and Accumulation circles | C2 | §4.7 invariants pass; within size limits |
| C4 | Factory | C3 | Deterministic, operator-only, pausable |
| C5 | Test and analysis suite | C3, C4 | Meets the §4.7 thresholds |
| C6 | Batch and verify scripts; CI pinning | C4 | Every signer reproduces the manifest |

**External items.** Each is done when its credentials sit in the right GitHub environment or vault and a smoke check passes.

| ID | Item | Owner | Lead time | Cost |
|---|---|---|---|---|
| B1 | Supabase, two orgs | Founder | 1 day | Pro $25 per org per month, plus compute and PITR [VERIFY] |
| B2 | Sentry | Founder | 1 day | [VERIFY] |
| B3 | Privy: plan, TEE, gas credits, admin quorum, policy-engine tier | Founder + Privy | 2–4 weeks | Quote |
| B4 | Safes and key ceremony | 5 signers | 2 weeks | Hardware about $150–250 each (estimate) |
| B5 | Two contract audits; a pentest firm (API and relay, iOS, web, Privy config, Supabase, Replit, CI supply chain); a bug bounty | Founder | 6–10 weeks | Quotes |
| B6 | Counsel: disclosures, Earn and the Advisers Act, circles, identity, RWA, App Review, data processing agreements (Supabase, Sentry, Privy), Ghana DPC registration, GDPR/UK transfers | Founder | — | — |
| B7 | On-ramp and off-ramp contracts | Founder | — | — |
| B8 | RWA partner sandbox | Founder | — | — |
| B9 | $10 mainnet round trip | Team | — | — |
| B10 | Base RPC provider, Etherscan v2 key, paging tool and on-call rota, Replit Reserved VM, Apple organization account / D-U-N-S | Founder | — | — |

**Environments**

| Env | Chain | Privy app | Earn vault | Circles | Supabase | Sentry |
|---|---|---|---|---|---|---|
| dev | Base Sepolia | dev | mock (Earn has no testnet) | local or Sepolia | `supabase start` | none |
| staging | Base 8453 | staging | throwaway wrapper, $100 cap | Sepolia rehearsal | staging org | staging |
| prod | Base 8453 | prod | production wrapper | mainnet after the audit | prod org | production |

Secrets per environment: `MIGRATIONS_DATABASE_URL`, `SUPABASE_ACCESS_TOKEN`, the database password, the project ref, `SENTRY_AUTH_TOKEN`, the Etherscan key. `reference_id` is unique per Privy app, so environments never share an app.

**v1.0 gate.** No launch until all of these hold:
1. Counsel has signed off.
2. Disclosures are live.
3. Terms and 18+ acceptance are in place.
4. The Earn gate passes (§3.4), App Review has cleared Earn, and the fee follows decision 6.
5. The pentest has no open High.
6. PITR is on and a restore has been drilled.
7. Alerts and on-call are live.
8. There have been 7 days of clean dogfood reconciliation.
9. The $10 round trip has been done.
10. The exit page has been tested.

**Audit gate (v1.1 circles).** No mainnet deploy until all of these hold:
1. The commit is frozen and the audit report lists its initcode hashes.
2. Two audits are done. Every Critical, High and Medium is fixed and re-reviewed; each Low is fixed or accepted in writing.
3. The §4.7 suites pass on the frozen commit.
4. The pentest has no open High.
5. Both rehearsals and `VerifyBase` pass.
6. The bounty is live and the playbooks have been drilled.
7. Launch is guarded: a feature flag, $25k per circle, 20 members, and no-yield circles first.

## 10. Open founder calls and [VERIFY]

**Founder calls**
1. Identity model (decision 4).
2. Earn fee after counsel (decision 6).
3. Circle fees (decision 13).
4. Default σ, the Trusted tier, and the organiser's slot.
5. The all-delinquent rule.
6. Safe signers and thresholds.
7. When to move to Privy Enterprise.
8. Supabase and Sentry regions.
9. Audit, pentest and bounty firms, and the budget.
10. Launch markets, the eligibility source (decision 23) and the Ghana timeline.
11. Whether RWA Phase 1 goes ahead.
12. The cash-out provider, or cutting Cash out from v1.0.
13. Whether to make users whole after a Morpho loss.

**[VERIFY]**
- **Privy (S0):**
  - a quorum-owned admin wallet, and handing the wrapper's owner and allocator roles to the Timelock;
  - the fee recipient, and whether Privy takes a cut;
  - which plan tier has the policy engine, and what policies can express;
  - the gas convenience fee, and the 7702 delegate address;
  - Swift signing, and two signatures per Face ID prompt;
  - headless passkey MFA, and React signing;
  - `reference_id` lookup and uniqueness;
  - whether the idempotency key is in the signed payload, and the maximum request expiry;
  - that identity tokens can't be used to get user keys;
  - looking up a wallet's owner;
  - relaying a device-signed `wallet_sendCalls`;
  - email branding.
- **Morpho:**
  - why Steakhouse's TVL fell;
  - Gauntlet's two pending configuration changes;
  - Gauntlet's automation after the Resolv exploit;
  - what the liquidity API figures mean.
- **Chain:**
  - EIP-7702 aliasing for forced inclusion;
  - forge-std `signDelegation`;
  - gas per deploy batch;
  - the cost of Basescan verification;
  - how far the `safe` head lags.
- **Supabase:**
  - node-postgres in transaction mode;
  - `verify-full` through the pooler;
  - whether the region is permanent;
  - Replit's IPv6 support and region, and whether it injects `DATABASE_URL`.
- **Sentry:**
  - plugin option typings;
  - whether git and secrets are available in Replit builds;
  - unhandled-rejection mode.
- **Legal and RWA:**
  - the Dinari facts;
  - Spiko on Base;
  - how App Review treats Earn and RWA;
  - whether the GENIUS Act and FDIC rules apply to apps;
  - recurring card buys.

**Sources opened for v3**
- **Morpho:**
  - [fee wrapper](https://docs.morpho.org/developers/earn/concepts/fee-wrapper/)
  - `api.morpho.org/graphql` (both vaults, queried today)
  - `VaultV2.sol` (cached source)
- **Privy:**
  - [Earn setup](https://docs.privy.io/wallets/actions/earn/setup)
  - [deposit](https://docs.privy.io/wallets/actions/earn/deposit)
  - [server signing](https://docs.privy.io/controls/authorization-keys/using-owners/sign/signing-on-the-server)
  - [user keys](https://docs.privy.io/controls/authorization-keys/keys/create/user/overview)
  - [authenticated signers](https://docs.privy.io/security/authentication/authenticated-signers)
  - [idempotency](https://docs.privy.io/api-reference/idempotency-keys)
  - cached pages: authorization signatures, withdraw, policies, stateful policies, gas setup
- **Other:**
  - [OZ CHANGELOG](https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/master/CHANGELOG.md)
  - [Base limits](https://docs.base.org/specifications/transactions/throughput-and-limits)
  - Base RPC `mainnet.base.org` (read-only calls)
- **Search results only, not opened:** Privy MFA.

## Appendix A. Address registry (Base 8453)

| Name | Address | Source / check |
|---|---|---|
| USDC (Circle) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Circle docs [VERIFY page]; `isBlacklisted` and `paused` respond |
| Gauntlet USDC Prime (Vault V2) | `0x050cE30b927Da55177A4914EC73480238BAD56f0` | Morpho API |
| Gauntlet liquidity adapter (MarketV1) | `0x2fEcd40f436CA170D2478a58Da898FcE93988eef` | Morpho API |
| Steakhouse Prime USDC (Vault V2) | `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` | Morpho API |
| SafeL2 v1.4.1 | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | safe-deployments [VERIFY codehash] |
| SafeProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | same |
| MultiSendCallOnly v1.4.1 | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` | same |
| CompatibilityFallbackHandler v1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | same |
| CreateX | `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` | CreateX repo [VERIFY codehash] |

All of these have non-empty bytecode at block 52,933,005. `VerifyBase` and `checkEarnWrapper.ts` must also match their codehashes against the sources.

## Appendix B. Review log

**Accepted**
- **Security critique:** #1, #2 (confirmed: Privy issues a user key for a valid access token), #5, #7, #9–#12, #15–#18, #20, and #22 with all its corrections (including 42.5% rather than 45%, the path `lib/goals.ts:38`, `Deploy.s.sol:64-68` being conditional, `abi.encode`, and the Dinari facts).
- **Completeness critique:** #1–#6, #8–#13 and #15–#24. For #17, F1–F6 aren't defined in the repo, so R1–R8 (§4.7) replace them.

**Rejected in part, with reasons**
- **Security #3:** an attacker can't "appoint an allocator at once", because `setIsAllocator` is submitted by the curator and timelocked (`VaultV2.sol:340-341`). A penalty of **0** is rejected: `forceDeallocate` is permissionless, and at zero penalty it needs no shares or allowance (`VaultV2.sol:765-797`), so anyone could move the wrapper's funds to idle for free. Instead, a 0.01% penalty is fixed by abdication.
- **Security #4:** a rule that the Guardian "cannot cancel role revocation" would let Gov bundle anything with a revocation to make it uncancellable. Only operations made entirely of rotation calls are protected.
- **Security #6:** `trySafeTransfer` is in OZ 5.3.0 (confirmed) but isn't needed, so OZ stays at 5.1.0.
- **Security #8:** `settleInKind` is unnecessary once rotating circles hold no yield.
- **Security #13:** the clock can't be frozen on-chain without knowing when a pause ended. Instead, time-gated functions revert while USDC is paused, and bounded Guardian extensions cover the rest.
- **Security #14:** "drop the slot and continue" is deferred to v1.2. It changes every other member's payout and security mid-circle and enlarges the audit, while at σ = 100% no honest member loses money anyway. Instead: a penalty of min(E, c), DEFAULT strikes, and a one-tap restart.
- **Security #19:** a micro-unit ledger is rejected, because the cent ledger is a non-negotiable. Exact amounts live in the micro-USDC mirror tables. Posting at the `safe` head is adopted.
- **Security #21:** no 1-day Guardian response requirement. Gauntlet's penalty applies only to whoever calls `forceDeallocate` on it directly, and any pending Gauntlet change pauses new deposits.
- **Completeness #7:** Cash out stays in v1.0 only if the off-ramp contract (B7) lands.
- **Completeness #14:** costs are given only where known; the rest are marked as quotes or estimates.