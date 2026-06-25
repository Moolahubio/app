# Moolahub → Monad Testnet Migration & Yield Integration Plan

**Status:** Draft for review · **Owner:** CTO/PM (Jerry) · **Date:** 2026-06-24
**Source of truth (repo):** https://github.com/Moolahubio/app
**Scope:** Move Moolahub's on-chain layer from **Base Sepolia (chainId 84532)** to **Monad Testnet (chainId 10143)** — contracts, backend, frontend, Privy — and make the savings vault and accumulation circles **yield-bearing** by routing idle USDC into a lending / ERC-4626 yield source.

> How this was produced: a CTO/PM (synthesis + Monad DeFi research) plus three senior full-stack engineers working in parallel — one mapping the smart-contract layer and designing the yield architecture, one mapping the backend (`api-server`), one mapping the frontend (`moolahub-app`) and Privy. Every repo reference below cites a real file and line; every Monad fact is from `docs.monad.xyz` or a cited source. Items we could **not** verify are flagged **[VERIFY]** rather than guessed.

---

## 1. Executive summary

The migration is **mostly configuration and redeployment, not a rewrite**. Monad is EVM-equivalent at the Fusaka fork, so the existing Solidity compiles and behaves the same; the chain-specific code is concentrated in a handful of well-isolated files.

- **Contracts:** No Solidity logic change needed just to run on Monad. Change `foundry.toml` RPC/verifier entries, replace the hardcoded Base-Sepolia USDC default in the two deploy scripts, redeploy, and record a new `deployments/monad-testnet.json`. `evm_version = "cancun"` is safe on Monad.
- **Backend:** The Base/baseSepolia viem chain selection is duplicated in **4 files + 1 script**. Swap to viem's `monadTestnet`, repoint RPC/explorer defaults, rename `BASE_*` env vars, refund the platform key in **MON**, and re-tune the log-indexer for Monad's ~400 ms blocks and public-RPC rate limits.
- **Frontend:** Surprisingly thin — **no viem client, no chainId literal, no `ETH`/`MON` symbol** in the app. The real work is one Privy config addition (`defaultChain`/`supportedChains` → `monadTestnet`), four hardcoded `basescan.org` fallbacks, the network-label logic, and ~19 "Base" copy strings.
- **Privy:** Server-side Privy is chain-agnostic (auth only) — **no server code change**. The dependency is a **dashboard step**: enable Monad Testnet (10143) and register the Monad paymaster for the gasless ERC-4337 flow.
- **Yield:** Add a swappable `IYieldAdapter` and deploy **V2 savings/accumulation vaults that use share-based (ERC-4626-style) accounting**, launching on a no-yield `PassthroughAdapter` and switching to a real adapter (recommended target: **Curvance `cUSDC`, which is itself ERC-4626**) once verified and de-risked. The rotating Susu **escrow** is intentionally left out of yield (near-zero idle balance).

**Recommended sequencing:** because this is a fresh Monad launch with only testnet/mock funds on Base, deploy the **yield-ready V2 contracts from day one on Monad** with `PassthroughAdapter` (identical to today's behavior), then enable real yield as a later, low-risk config switch. No on-chain fund migration is required.

---

## 2. Verified Monad Testnet facts (use these; do not improvise)

From `docs.monad.xyz` (developer-essentials, testnets, summary, embedded-wallets):

| Item | Value |
|---|---|
| Chain ID | **10143** (hex `0x279f`) |
| Network name | **Monad Testnet** |
| Native gas token | **MON** (18 decimals — same wei math as ETH) |
| Public RPC | `https://testnet-rpc.monad.xyz` (QuickNode; 50 rps, **25 rps for `eth_call`/`eth_estimateGas`**, batch ≤100, archive ✅) · `https://rpc.ankr.com/monad_testnet` (no `debug_*`) · `https://rpc-testnet.monadinfra.com` (no batching) |
| WebSocket | `wss://testnet-rpc.monad.xyz` |
| Explorers | `https://testnet.monadscan.com` (by Etherscan) · `https://testnet.monadvision.com` (Blockvision) · `https://monad-testnet.socialscan.io` |
| Faucet | `https://faucet.monad.xyz` (MON) |
| EVM target | **Fusaka** fork (superset of Cancun). Bytecode/opcodes identical to Ethereum Fusaka. Max contract size **128 kb**. |
| Block time / finality | ~**400 ms** proposed, **800 ms** finalized; receipts available at "Proposed" |
| Gas model | **Charged on gas LIMIT, not gas used** (`value + gas_price * gas_limit`). Min base fee 100 MON-gwei. Per-tx limit 30M, block 200M. |
| Tx types | 0,1,2,4 supported; **type 3 (EIP-4844 blobs) NOT supported** |
| Tooling | Use the **Monad Foundry fork** for deploys (correct gas pricing/precompiles); **viem ≥ 2.40.0** for the `monadTestnet` chain export. **Confirmed:** `viem/chains` exports `monadTestnet` (id 10143, MON, RPC `https://testnet-rpc.monad.xyz`, Multicall3) — present since viem 2.45; repo has `^2.52` ✅ |
| Canonical contracts | Multicall3 `0xcA11bde05977b3631167028862bE2a173976CA11` · Permit2 `0x000000000022d473030f116ddee9f6b43ac78ba3` · CreateX `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` · Wrapped MON `0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541` |
| Privy on Monad | Supported on testnet; **subsidized** — contact `monad@privy.io` to enable for the app |

**USDC on Monad:** Circle has brought **native testnet USDC** to Monad; testnet USDC is obtainable from `https://faucet.circle.com` (≈20 USDC / 2h per address). Standard USDC is **6 decimals**, which matches all Moolahub accounting. **[VERIFY]** the exact Monad-testnet USDC token address from Circle's developer docs before wiring it in, and confirm 6-dp.

**[VERIFY] list (facts not pinned in docs):** exact MonadVision (`forge`) verifier URL; concrete Monad gas costs for sizing gas top-ups; Curvance's live Monad-testnet market addresses; the precise per-chain behavior of the Privy ERC-4337 paymaster.

---

## 3. Current on-chain architecture (Base Sepolia today)

**Contracts (`contracts/src`)** — Foundry, solc 0.8.28, `evm_version = "cancun"`:

- `MoolaHubGoalVault.sol` — **singleton savings vault.** Holds all users' USDC in one contract, keyed `mapping(owner => goalId => uint256) _bal`. Free deposits; withdrawals charge a fee (default 200 bps = 2%, capped 5%) to the treasury, with a per-slot "locked fee" snapshot. Strictly non-custodial (no admin path to funds).
- `MoolaHubSusuAccumulation.sol` — **one clone per accumulation circle** (EIP-1167 via `MoolaHubAccumulationFactory`). Pools members' USDC; each member only ever withdraws their own `savingsOf`. Optional `lockUntilMaturity`. Withdrawal fee to treasury (fee-free if cancelled).
- `MoolaHubSusuEscrow.sol` — **rotating Susu**, one clone per circle via `MoolaHubCircleFactory`. Pass-through: each round's pot is paid to the positional recipient immediately, so it holds ~zero idle balance.
- `MoolaHubTreasury.sol`, `MoolaHubReputation.sol`, interfaces in `contracts/src/interfaces/`.
- Test mock: `contracts/test/mocks/MockUSDC.sol` (6-dp, EIP-2612 permit, open `mint`).
- Deployed Base-Sepolia addresses recorded in `contracts/deployments/base-sepolia.json` (and `latest.json`); `usdcKind: "mock-mintable"`.

**Backend (`artifacts/api-server`)** — Node 24 / Express 5 / Drizzle / viem `^2.52`. On-chain helpers in `src/lib/chain.ts` (USDC transfers, GoalVault, escrow, faucet, gas top-up), `src/lib/circleChain.ts` (accumulation factory), `src/lib/onchainIndexer.ts` (log polling). The double-entry **ledger is the source of truth**; on-chain calls are best-effort. The spendable wallet is a **server-custodied viem account** (key encrypted at rest) — Privy is used for **auth/identity only**.

**Frontend (`artifacts/moolahub-app`)** — Vite/React, viem `^2.52`, `@privy-io/react-auth ^3.28`. Uses Privy smart accounts (ERC-4337) with a dashboard-registered paymaster for gasless txs (`src/hooks/useOnchain.ts`). Chain config is **not** in the frontend — it relies on the Privy dashboard chain plus backend-served `/api/onchain/config`.

---

## 4. Migration plan — step by step

### Phase 0 — Prerequisites (no code) 🔑
1. **Privy dashboard:** enable **Monad Testnet (10143)** as a supported/default chain for the app; email `monad@privy.io` for subsidized access; **register the ERC-4337 paymaster/bundler for Monad** (the gasless flow in `useOnchain.ts` depends on it). Decide whether to reuse the existing Privy app id or create a Monad-specific one.
2. **RPC:** choose a Monad RPC (default `https://testnet-rpc.monad.xyz`; consider a dedicated QuickNode/Alchemy key for higher limits in production).
3. **USDC:** decide **Circle native testnet USDC** (recommended — real CCTP-grade asset, 6-dp) **[VERIFY address]** vs. deploying your own `MockUSDC` for an open faucet. If you keep a faucet UX, MockUSDC is simpler; if you want realistic flows, use Circle USDC and drop the mint faucet.
4. **Platform wallet:** fund `PLATFORM_PRIVATE_KEY` (same EVM key works) with **MON** from `faucet.monad.xyz` for gas top-ups and factory/owner txs.
5. **Tooling:** install the **Monad Foundry fork** for deploys; confirm a Monadscan/Etherscan-v2 API key for verification.

### Phase 1 — Smart contracts
1. `contracts/foundry.toml`
   - `[rpc_endpoints]` (lines 20–21): add `monad_testnet = "${MONAD_TESTNET_RPC_URL}"`.
   - `[etherscan]` (lines 23–24): add `monad_testnet = { key = "${MONADSCAN_API_KEY}", chain = 10143, url = "https://api.etherscan.io/v2/api" }` (Etherscan v2 multichain endpoint stays the same; only `chain` changes).
   - `evm_version` (line 10): **keep `"cancun"`** (safe subset of Fusaka). `solc 0.8.28` unchanged.
2. `contracts/script/Deploy.s.sol` & `contracts/script/DeployAccumulation.s.sol`
   - Remove/replace the hardcoded **Base-Sepolia USDC constant** (`Deploy.s.sol` line 25; `DeployAccumulation.s.sol` line 26). Prefer making `USDC_ADDRESS` a **required** env (`vm.envAddress`) so a deploy fails closed instead of pointing at a non-existent token.
   - Update the `--rpc-url base_sepolia` examples/comments → `monad_testnet`.
   - Deploy order: Treasury + Reputation + USDC first, then factories/vault (the accumulation script reads `TREASURY_ADDRESS`/`REPUTATION_ADDRESS`).
3. **MockUSDC (if used):** it lives in `test/`; to deploy it, add a deploy step/script that imports it (or move to `src/`). Keep **6 decimals**. Skip entirely if using Circle USDC.
4. **Deploy** all contracts to Monad with the Monad Foundry fork. Because the contracts are non-upgradeable singletons/clone-implementations, **deploy fresh** (no in-place upgrade).
5. **Record** `contracts/deployments/monad-testnet.json` with `network: "monad-testnet"`, `chainId: 10143`, `explorer`, deployer/owner/guardian, `feeBps`, `usdcKind`, and all addresses. (The script auto-writes `latest.json`, which lacks `chainId` — extend it to also stamp `chainId`/`network`/`explorer`, or maintain the per-network file by hand as today.)
6. **Verify** each contract on Monadscan:
   ```
   forge verify-contract <ADDR> src/MoolaHubGoalVault.sol:MoolaHubGoalVault \
     --chain 10143 --verifier etherscan \
     --verifier-url https://api.etherscan.io/v2/api \
     --etherscan-api-key $MONADSCAN_API_KEY \
     --constructor-args $(cast abi-encode "constructor(address,address,uint16,address)" $USDC $FEESINK 200 $OWNER) --watch
   ```
   Clones are EIP-1167 minimal proxies — verify the **implementation** once.
7. **Hardening (recommended, optional):** add a `MAX_MEMBERS` cap to `MoolaHubSusuAccumulation` (the escrow already caps at 20) and a minimum `roundDuration` (e.g. ≥ 60 s) so sub-second rounds can't interact badly with Monad's shared-timestamp blocks. Set tight gas limits on member-loop txs since Monad bills on the limit.

> **Why no Solidity logic change for the move itself:** no hardcoded chain id, no `block.number` timing, no opcodes outside Cancun, no `selfdestruct`/`tx.origin`. `block.timestamp` is only compared against multi-second/day windows, which is safe under Monad's 400 ms shared-timestamp blocks.

### Phase 2 — Backend (`artifacts/api-server`)
The identical Base-selection block appears in **4 files + 1 script** — change each:

1. **Chain selection** in `src/lib/chain.ts` (line 16, 27–30), `src/lib/circleChain.ts` (line 14, 33–36), `src/lib/onchainIndexer.ts` (line 12, 34–37), `scripts/set-fee-sink.mjs` (lines 12–17):
   - `import { base, baseSepolia } from "viem/chains"` → `import { monadTestnet } from "viem/chains"`.
   - Drop the `IS_MAINNET ? base : baseSepolia` ternary → `const CHAIN = monadTestnet` (no Monad mainnet chain export exists yet — don't invent one).
   - RPC default `sepolia.base.org`/`mainnet.base.org` → `https://testnet-rpc.monad.xyz`.
2. **Network/explorer strings** in `chain.ts`:
   - `networkName()` (lines 171–173) → return `"monad-testnet"`.
   - `explorerUrl()` (lines 175–177) default → `https://testnet.monadscan.com`.
   - `scripts/set-fee-sink.mjs` line 64 hardcoded `sepolia.basescan.org/tx/...` → Monad explorer.
3. **Gas top-up** (`chain.ts` 42–43, `ensureGas` 215–228, `PlatformBalances`/`ethBalanceWei` 247–306): mechanically still works (MON is 18-dp native, same wei math). But **rename** the `eth*` labels to `native`/`mon` (`ethWei`→`nativeWei`, `ethBalanceWei`→`nativeBalanceWei`) so operators aren't shown "ETH" on a chain with no ETH, and **re-tune** `GAS_TOPUP_WEI`/`GAS_MIN_WEI` against Monad's gas-limit pricing **[VERIFY costs]**.
4. **Indexer for Monad** (`onchainIndexer.ts` `BLOCK_LOOKBACK = 9_000n` line 40; loop 277–302; per-circle `getLogs` fan-out 121–130, 285–291; plus `chain.ts` `getIncomingUsdc` `latest - 9_000n` line 732):
   - At ~400 ms blocks, **9,000 blocks ≈ 1 hour** of wall-clock (vs ~5 h on Base) — **widen the lookback and/or adopt a persisted block cursor (high-water mark)** so events aren't missed after downtime.
   - Respect public-RPC limits (50 rps; 25 rps for `eth_call`). Batch reads via **Multicall3** (`0xcA11…CA11`) and/or move heavy log loads to an **indexer** (Envio/Goldsky/QuickNode Streams/thirdweb Insight, chainId 10143) instead of raw `eth_getLogs` polling.
5. **Env vars** — rename/add (full matrix in §7). Set the Monad contract addresses, RPC, explorer; keep `PLATFORM_PRIVATE_KEY` (fund with MON). Provide back-compat reads (`CHAIN_RPC_URL ?? BASE_RPC_URL`) during transition.
6. **Privy server (`src/lib/privy.ts`, `src/lib/wallet.ts`): no change.** Privy here is auth only (`verifyAuthToken`, `getUser`) — no chain/RPC/chainId. The spendable wallet is a local viem account; it signs against whatever `CHAIN` is set.

### Phase 3 — Frontend (`artifacts/moolahub-app`) + Privy client
1. **Privy chain config** — `src/components/app/WalletSetupCard.tsx`:
   - Add `import { monadTestnet } from "viem/chains";` (top).
   - In the `<PrivyProvider config={{…}}>` (lines ~129–138, currently only `appearance`), add `defaultChain: monadTestnet` and `supportedChains: [monadTestnet]`. **[VERIFY]** these key names against the installed `@privy-io/react-auth ^3.28`.
2. **Explorer fallbacks** — replace hardcoded `https://sepolia.basescan.org` in `src/components/app/bits.tsx` (line 52), `src/pages/goal-detail.tsx` (line 24), `src/pages/circle-detail.tsx` (lines 332 & 358) → `https://testnet.monadscan.com`. Best: extract one shared `EXPLORER_FALLBACK`.
3. **Network label** — `WalletSetupCard.tsx` line 16 and `src/pages/wallet.tsx` line 11 derive `"Base"/"Base Sepolia"` from `VITE_BASE_NETWORK`. Replace with `"Monad Testnet"` (or a new `VITE_CHAIN_NAME`).
4. **Smart-wallet path** — `src/hooks/useOnchain.ts`: **no code change**; `client.sendTransaction` binds the chain from Privy. (Verify a `SmartWalletsProvider` actually wraps the screens that call `useSmartWallets` — flagged independent of Monad work.)
5. **Copy** — update ~19 user-facing "Base"/"Basescan" strings (wallet, profile, activity, circles, auth shell, forms placeholder, goal/circle detail) → "Monad" / generic "on-chain". No `ETH`/`MON` symbol or `chainId` literal exists to change.

### Phase 4 — Yield integration (see §5 for the deep design)
1. Author `IYieldAdapter` + `PassthroughAdapter` + a real adapter (`ERC4626Adapter` targeting Curvance `cUSDC`).
2. Build **V2** `MoolaHubGoalVault` and `MoolaHubSusuAccumulation` using **share-based accounting**; deploy with `PassthroughAdapter` first (behaves exactly like today).
3. Once Curvance's Monad market is verified and de-risked, `setAdapter(ERC4626Adapter)` to turn yield on. Keep an `emergencyExitToPassthrough()` escape hatch.

**Cross-layer coupling the V2 vaults force (do not skip):**
- **Indexer ↔ event shapes.** The backend reconciler parses specific events — `GoalDeposited`/`GoalWithdrawn` (`chain.ts` ABI), `Contributed`/`RoundSettled` (`onchainIndexer.ts`), and ERC-20 `Transfer`. A share-based V2 will likely change deposit/withdraw event payloads (e.g. emit shares alongside assets). **Phase 2 and Phase 4 are not independent:** any V2 event change requires updating the ABIs/parsers in `chain.ts` and `onchainIndexer.ts` in lockstep, or the ledger stops reconciling. Treat "re-sync indexer ABIs to V2 events" as an explicit task.
- **Ledger ↔ yield reconciliation.** The double-entry ledger is the source of truth and stores **cents**; today on-chain balance ≈ ledger. With yield, the on-chain redeemable value **grows** above principal. Decide explicitly how yield surfaces: (a) credit accrued yield into the ledger on a schedule / at withdrawal via a new posting type, and (b) how the UI shows "saved + earned". Until that's designed, yield exists on-chain but is invisible to users. This is a product decision, not just code.
- **Adapter approvals.** Each V2 vault must `approve` the adapter (and the adapter must `approve` the underlying lender/4626 vault) to pull USDC. Add these allowance steps to deploy/config, or deposits revert.
- **Tx types.** Monad does not support type-3 (EIP-4844 blob) txs; type 2 (EIP-1559) is the default for viem and the ERC-4337 path, so this is expected-fine, but confirm neither the platform signer nor the Privy bundler is configured to send blobs.

### Phase 5 — Testing & verification (gate before "live")
1. **Contracts:** run the existing Foundry tests against the Monad Foundry fork; expect the existing tests (`contracts/test/*.t.sol`) to carry Base/MockUSDC assumptions — audit and adjust fixtures for the Monad USDC choice. Add **invariant/fuzz tests** for the new share math (`Σ convertToAssets(shares) ≤ totalManagedAssets()`), first-depositor inflation protection, and fee-on-yield behavior. The repo already has `Deploy`/`Accumulation` e2e tests and `slither.config.json` — run Slither on the new adapters/V2 vaults.
2. **Backend:** point a staging env at Monad; exercise deposit → goal vault → withdraw, circle create → contribute → settle, faucet/sync (testnet flags), and the indexer catch-up after a simulated outage. Confirm gas top-ups land in MON.
3. **Frontend:** full Privy login → embedded/smart wallet → sponsored tx on Monad; confirm explorer links resolve on Monadscan; verify copy.
4. **DB migration:** `wallets.network` default → `"monad-testnet"`; decide policy for existing `network` strings and Base-era `circles.contract_address` (these don't carry to Monad — null/redeploy or treat pre-migration rows as ledger-only).
5. **Rollback / dual-run:** the back-compat env reads (`CHAIN_RPC_URL ?? BASE_RPC_URL`) allow a clean cut-over, but on-chain state does **not** dual-run — a wallet/circle is on Base **or** Monad, not both. Plan a single forward cut-over for testnet (re-seed on Monad); keep the Base config available only as a fast rollback of the backend, understanding any Monad-era on-chain activity won't exist on Base.
6. **Sign-off checklist** in §8.

---

## 5. Yield integration — design deep dive

**Goal:** while users save toward goals (GoalVault) and contribute to accumulation circles (SusuAccumulation), their idle USDC earns lending yield. The rotating **escrow is excluded** (≈zero idle balance; adding a lender would risk payout timing).

### 5.1 Architecture decision — ERC-4626 behind a swappable adapter
Route idle USDC through an **`IYieldAdapter`** rather than hard-coupling a vault to one lender. Recommended real target: **Curvance**, whose `cTokens` (e.g. `cUSDC`) **are themselves ERC-4626 vault shares** — so an `ERC4626Adapter` maps 1:1 onto deposit/withdraw/`totalAssets`. The adapter pattern lets you (a) **launch on a no-yield `PassthroughAdapter`** identical to today, and (b) swap lenders later without touching vault logic.

```solidity
interface IYieldAdapter {
    function deposit(uint256 assets) external returns (uint256 deployed);
    function withdraw(uint256 assets, address to) external returns (uint256 received);
    function totalAssets() external view returns (uint256); // principal + accrued yield
    function asset() external view returns (address);       // must equal vault USDC
    function maxWithdraw() external view returns (uint256); // for liquidity/paused checks
}
```
Implementations: `ERC4626Adapter` (wraps Curvance `cUSDC` or any 4626 vault), `PassthroughAdapter` (holds USDC, zero yield — launch/emergency), optional `AaveV3Adapter` (supply/withdraw + `aToken.balanceOf`) if a money-market is preferred later.

### 5.2 Accounting change — shares, not raw balances
When yield accrues, `totalAssets()` grows, so a fixed-USDC balance map is wrong. Move both vaults to **share accounting**:

- **GoalVault:** replace `mapping(owner=>goalId=>uint256) _bal` (USDC) with `shares[owner][goalId]` + `totalShares`. On deposit, mint `shares = amount * totalShares / totalManagedAssets()` (first deposit: `shares = amount`), where `totalManagedAssets() = idleUSDC + adapter.totalAssets()`. On withdraw, `assets = shares * totalManagedAssets() / totalShares`. `balanceOf` now returns principal **+ accrued yield** (so users see their yield); add `sharesOf()`.
- **SusuAccumulation:** same transformation per clone — `savingsOf`/`totalSaved` (value) become `sharesOf`/`totalShares`. **Keep `contributed[round][member]` unchanged** (it tracks schedule compliance/delinquency, not value). On `contribute`, mint shares for the fixed `contributionAmount`; on `withdraw`, redeem all the member's shares. Pooled-until-payout funds mean yield distributes **pro-rata and fairly** to each member's contributed value over time — `lockUntilMaturity` circles benefit most.
- **`sweepExcess()`** must be recomputed against `totalManagedAssets()` so it never sweeps yield.

### 5.3 Withdrawals, liquidity, loss, fees
- **Redemption:** burn shares (effects) → `adapter.withdraw` (interaction). If the lender can't return the full amount (high utilization), **revert + expose `maxWithdraw()`** so the UI warns pre-flight (Monad bills failed txs on the gas limit, so avoid blind reverts).
- **Liquidity buffer:** keep ~5–10% of TVL un-deployed so most withdrawals settle without touching the lender.
- **Loss / negative yield:** share accounting handles it automatically — the exchange rate drops and all holders share pro-rata. Guard against fee > redemption / underflow.
- **Paused/halted lender:** `maxWithdraw()` → 0; provide owner/guardian **`emergencyExitToPassthrough()`** to pull everything back to idle USDC and revert to today's behavior. A fully frozen lender blocks withdrawals until it thaws — this is the inherent risk of yield and must be disclosed.
- **Fee × yield:** keep the existing **2% on gross redemption** (principal + yield) for simplicity and a small audit surface; treasury thus also takes 2% of yield. (Alternative: performance fee on yield only — more code, defer.)

### 5.4 Security (new external DeFi dependency)
- **Reentrancy:** keep `nonReentrant` + strict CEI (burn shares before adapter call). Treat the adapter/lender as untrusted.
- **First-depositor share-inflation (donation) attack:** mitigate with OZ ERC-4626 **virtual shares/offset** or seed dead shares at deploy — for the singleton GoalVault *and* every accumulation clone.
- **Rounding:** round in the protocol's favor (mint down, redeem cost up); USDC dust is real at 6-dp. Add invariant tests.
- **Oracle/rate manipulation:** prefer a lender whose `totalAssets` is **internal accounting** (cToken/aToken balance), **not** a DEX spot read.
- **Preserve the non-custodial invariant:** the owner may **swap the adapter** but must still have **no path to move user USDC**; the adapter swap routes through the vault's own redeem logic, never an admin sweep. Assert `adapter.asset() == usdc` in `setAdapter`.

### 5.5 Contracts & migration path
- **New:** `IYieldAdapter`, `PassthroughAdapter`, `ERC4626Adapter` (additive, independently auditable).
- **Modified (new deployments, not upgrades):** V2 GoalVault + V2 SusuAccumulation implementation (+ factory pointing at the new impl). Existing contracts are non-upgradeable.
- **Funds:** fresh Monad launch ⇒ no migration; deploy V2 with `PassthroughAdapter`. Base-Sepolia balances are testnet/mock — re-seed on Monad. If live funds ever need moving, do **user-initiated** `migrate()` (preserve non-custodial guarantee), never an admin bulk-mover.

### 5.6 Monad yield-source options (researched)
| Protocol | Type | Fit for USDC savings yield | Notes |
|---|---|---|---|
| **Curvance** | Lending; `cTokens` are **ERC-4626** | **Best fit** | `cUSDC` = ERC-4626 share, drop-in for `ERC4626Adapter`; deposit USDC, earn as borrowers repay. **[VERIFY]** live Monad-testnet market address + audit status. |
| Timeswap | Oracle-less AMM money market | Possible, more complex | No oracles/liquidators; different risk model. |
| aPriori / Kintsu / Magma | MON **liquid staking** | Not for USDC | Yield is on MON, not the USDC savings asset. |

Recommendation: target **Curvance ERC-4626 `cUSDC`** as the first real adapter; ship on `PassthroughAdapter` until its Monad market is verified and de-risked.

---

### 5.7 Confirmed business rules — withdrawal, fees, who-gets-paid (reconciled with the code)

These are the product rules, mapped to what the contracts do **today** and what changes when the vaults become **yield-bearing (V2)**. Verified against the current Solidity.

| Rule (product intent) | Today's contract | With yield (V2) |
|---|---|---|
| **Goals:** fee = 2% of the **current withdrawal amount** | `GoalVault.withdraw` line 101: `fee = grossAmount × effectiveFee/BPS`. ✅ Already exact. `effectiveFee = min(lockedFee, currentFee)` (lines 92–93) protects depositors from later fee hikes. | Withdrawal amount = the USDC redeemed from shares (principal + its share of yield). Fee = 2% of that redeemed amount. Goals are individual, no rounds → **always keep their yield.** Preserve the locked-fee feature. |
| **Rotating Susu:** funds go to your Moolahub account **automatically when it's your turn**; nobody can withdraw at will | `SusuEscrow._contribute` lines 129–153: when the round fills, it pays the positional recipient `_members[round-1]` (line 134) and the fee to treasury, atomically. Funds can leave ONLY as payout / fee / refund (lines 16–21). ✅ Already exact. | **No yield** (pass-through, ≈zero idle balance). Unchanged. Auto-settlement and the "no discretionary withdrawal" guarantee stay as-is. |
| **Accumulation:** at the end you get **savings + profit − fee**; fee = 2% of **(savings + profit)** | `Accumulation.withdraw` lines 143–160: returns `savingsOf` only, fee = 2% of savings (line 154); **no yield**, and "a member can never receive another member's money" (line 15). | Compliant member redeems shares → `savings + yield`; **fee = 2% × (savings + yield)**. (Your example: savings $1000, profit $100 → fee = 2% × $1100 = **$22**, receive **$1078**.) |
| **Accumulation delinquency:** miss a round → **forfeit all profit**, receive cumulative savings − 2% fee | Not implemented. The contract only flags missed rounds to the reputation registry (`flagRound`, lines 166–199); enforcement is off-chain. | Delinquent member receives `principal − 2% × principal`. (Your example: forfeit $100, fee = 2% × $1000 = **$20**, receive **$980**.) The forfeited $100 of yield is **redistributed to the disciplined savers**; the $20 fee goes to treasury. |
| **Cancelled circle** | Both circle contracts: cancellation makes withdrawals **fee-free** (`Accumulation.withdraw` line 154; escrow refunds via `claimRefund`). | Keep fee-free on cancellation; return each member's principal (and any yield realized) with no forfeiture. |

### 5.8 Dilemmas these rules create — and proposed solutions

The forfeiture rule is the hard part: once yield is live, a member's stake is *principal + yield blended into shares*, so "give back principal but claw back the profit" is not free. Below are the dilemmas we surfaced and the solutions we recommend.

**A. How do you forfeit *only* the yield when shares bundle principal + yield?**
Track principal separately. Add `principalOf[member]` (sum of `contributionAmount` on each `contribute`, alongside the share mint) so the contract always knows the contributed cost basis independent of the exchange rate.
- *Compliant* (`contributedRounds == totalRounds` at maturity): redeem all shares → `gross = principal + yield`; pay `gross − 2%·gross`.
- *Delinquent* (missed ≥1 round): burn **all** their shares but pay only `principal − 2%·principal`. The difference (their accrued yield) **stays in the vault**. Because we burn share-value worth `gross` while removing only `principal` of assets, the leftover yield automatically lifts the exchange rate for everyone still in — i.e. it is redistributed pro-rata to the disciplined savers **with no loop and no extra gas** (important on Monad, which bills on the gas *limit*). This is the cleanest mechanism and avoids an unbounded member loop.
- Principal is therefore always returned (minus fee); only *yield* is ever at risk. This is a deliberate, documented departure from the current "never receive another member's money" invariant — but it touches **yield only, never principal**.

**B. Where should forfeited yield go — savers or treasury?**
Default: **to the compliant members** (the exchange-rate mechanism in A does this for free and rewards saving discipline, which is the product's whole point). Edge case — if *every* member is delinquent there's no one to reward: route the orphaned yield to the **treasury** via the existing `sweepExcess` pattern (recompute "excess" against `totalManagedAssets()`, not `totalSaved`, so it never sweeps live principal). Optionally split (e.g. 80% savers / 20% treasury) — a one-line policy knob.

**C. What exactly counts as "missing a round," and when is it judged?**
Use the existing `contributed[round][member]` map (line 61) as the source of truth, evaluated at withdrawal/maturity: compliant ⇔ contributed in every round `1..totalRounds`. Don't depend on whether `flagRound` was called — compute compliance directly from the map. A member can't pay a *past* round (contribute only accepts the currently-open round via `currentRound()`), so a miss is permanent, matching the rule. **Flag for product:** "one miss → forfeit *all* profit" is intentionally strict; if you ever want it gentler, the alternative is **pro-rated forfeiture** (forfeit `missedRounds/totalRounds` of yield). Strict is the default per your spec; pro-rated is a config option.

**D. The fee base differs (compliant vs delinquent) — get it right.**
Compliant fee is on `principal + yield`; delinquent fee is on `principal` only. Branch explicitly, and clamp so `fee ≤ payout` and the delinquent payout uses `min(principal, grossRedeemable)` (see E). Cancelled circles remain fee-free.

**E. Yield can go *down* — then principal isn't fully there.** ⚠️ security-critical
A lending loss/depeg can make `grossRedeemable < principal`. "Return principal" then can't be honored — the money isn't in the pool. With share accounting, losses socialize pro-rata automatically; the contract must pay `min(principal, grossRedeemable) − fee` and never assume principal is intact. **This means yield-bearing ≠ principal-guaranteed, and that must be disclosed to users.** Offer a **principal-protected mode** = run that circle/goal on the `PassthroughAdapter` (no yield, no market risk) for risk-averse users. Keep `emergencyExitToPassthrough()` as the circuit breaker if the lender is impaired.

**F. Rotating Susu: the member who gets paid early then stops contributing.**
This is the classic ROSCA default risk, independent of Monad/yield. The escrow's protection is structural: payouts are **non-discretionary and positional**, and a stall triggers grace → `cancelStalled` → refunds of the *unsettled* round (lines 177–188, 228–234) plus reputation strikes. But already-settled early recipients keep their pot while later members can be left short — an economic, not contract, gap. Mitigations to consider: reputation-weighted payout ordering (riskier members later), an upfront stake/collateral, and surfacing reputation strikes in the UI before someone joins a circle. Document this risk explicitly; don't imply rotating circles are default-proof.

**G. "Automatically sent to your Moolahub account" — without an unbounded on-chain loop.**
Rotating circles already push to one recipient per round on the final contribution — fine. For **accumulation at maturity**, do **not** add a single contract call that loops over all members and pushes funds (a reverting member wallet would brick it, and Monad bills the whole gas limit). Instead keep the on-chain model as a **per-member settlement**, and have the **backend keeper** trigger each member's settlement at maturity (platform funds gas via `ensureGas`), crediting the ledger on confirmation. The user *experiences* it as automatic — funds appear in their Moolahub account — while on-chain it stays bounded and griefing-resistant.

**H. The off-chain ledger must mirror forfeiture & redistribution.**
The double-entry ledger (cents, source of truth) currently assumes on-chain ≈ ledger. Forfeiture and redistribution split a withdrawal into principal, yield-kept-or-forfeited, redistributed-yield, and fee. Emit explicit events (e.g. `AccumulationSettled(member, principal, yieldPaid, yieldForfeited, fee)`) and add matching ledger posting types so the reconciler stays correct. This is the same V2-events ↔ indexer coupling called out in Phase 4 — the forfeiture logic makes it mandatory, not optional.

**I. Rounding, dust, and the first-depositor share-inflation attack (per clone).**
Every accumulation circle is its own small vault, so each is individually exposed to the ERC-4626 first-depositor inflation/donation attack and to 6-dp USDC dust accumulating on redistribution. Use OZ ERC-4626 **virtual shares/offset** (or seed dead shares at init), round in the protocol's favor (mint down / redeem-cost up), sweep residual dust to treasury, and add an invariant test `Σ convertToAssets(shares) ≤ totalManagedAssets()` plus a fuzz test that the *last* withdrawer can always exit.

**J. Preserve the non-custodial guarantee through all of this.**
None of the above may introduce an admin path to user funds. The owner/guardian may swap the yield adapter and pause/cancel, but redistribution and forfeiture must execute inside the vault's own redeem logic — never an admin sweep of principal. Assert `adapter.asset() == usdc` on `setAdapter`, keep `nonReentrant` + strict CEI on every payout, and keep cancellation fee-free and principal-returning.

### 5.9 Three-tier savings product — Flexible / Fixed / Boosted

The yield engine above generalizes cleanly into **three savings tiers**, all built on the same `IYieldAdapter` pattern — each tier is just a different, **risk-isolated** strategy vault behind the router. A goal (or an accumulation circle) picks a tier at creation.

| | **Flexible** (Normal) | **Fixed** (Locked term) | **Boosted** (Risky) |
|---|---|---|---|
| Target return | ~**4% APR**, variable | **Higher fixed APY**, locked to a maturity | **≥30% APY target**, variable |
| Liquidity | Withdraw anytime | Locked until maturity (early exit forfeits the premium) | Withdraw via redemption **epochs/queue** |
| Yield source (Monad) | Lending supply — **Curvance `cUSDC`**, Euler, or Upshift `earnAUSD` (all ERC-4626) | **Fixed-yield instruments** — Spectra (Pendle-style Principal Tokens bought at a discount) or Timeswap fixed-maturity lending | **Actively-managed strategy** — stablecoin LP + reward emissions, leveraged lending loops, and/or delta-neutral (DN) basis trades |
| Principal risk | Low (lender smart-contract risk only) | Low–moderate (term/lender risk; early-exit cost) | **Material — principal at risk** |
| How the rate is achieved | Market lending rate, passed through | The **lock** lets you term-match into discounted fixed-yield paper, locking the rate in | Mostly **incentives/leverage**, not pure carry (see honesty note) |

> **Honesty note on "30%":** pure delta-neutral stablecoin carry (e.g. Ethena `sUSDe`) is running ~9–12% in 2026, not 30%. A 30%+ figure realistically comes from **reward emissions + leverage + early-chain incentive programs**, which are **variable and not sustainable indefinitely**, and carry depeg, funding-inversion, liquidation, IL, and smart-contract risk. The product must present this as a **target, principal-at-risk** return — never a guarantee — and show **trailing realized APY** (from the on-chain exchange rate), not a headline number.

**Architecture (extends §5.1–5.5):**
- **One ERC-4626 strategy vault per tier** (`FlexibleStrategy`, `FixedStrategy`, `BoostedStrategy`), each wrapping its own adapter(s). Separate vaults = **risk isolation**: a Boosted-tier loss can never touch Flexible/Fixed principal.
- **`SavingsRouter`** (GoalVault V2 extended): per `(owner, goalId)` stores `tier`, `principalOf`, `sharesIn[strategy]`, and `lock`. Deposits route to the chosen strategy vault; withdrawals redeem from it. Accumulation circles get a `tier` field too, reusing the same strategy vaults.
- Share accounting and the principal-tracking from §5.8(A) apply per tier; the forfeiture/early-exit mechanics carry over (early exit from Fixed forfeits the locked premium exactly like a delinquent circle member forfeits yield).

**Innovative mechanisms we recommend:**
1. **Glide-path / target-date goals.** As a goal nears its deadline, auto-suggest (or auto-rotate) funds from Boosted → Flexible to lock in gains and de-risk near payout — like a target-date retirement fund. A standout, savings-native UX no ROSCA app has.
2. **Insurance buffer (first-loss tranche).** Skim a slice of Boosted yield (e.g. 10–20%) into an on-chain insurance fund that backstops principal shortfalls in the Boosted tier. Optionally formalize as **senior/junior tranching** (senior = protected, lower yield; junior = first-loss, higher yield).
3. **Auto-derisk circuit breaker.** A keeper/strategist monitors drawdown, perp funding, and peg; on a breach it rotates Boosted funds back to Flexible lending automatically (extends `emergencyExitToPassthrough`).
4. **Redemption epochs for Boosted.** DN/LP positions can't unwind instantly, so Boosted withdrawals are request → settle next epoch (e.g. daily), with a small Flexible buffer for instant small redemptions. Flexible/Fixed stay instant.
5. **Performance + management fee on Boosted.** Beyond the 2% withdrawal fee, add a performance fee on realized profit (e.g. 15–20%) and an optional management fee — aligns the platform with users and funds the insurance buffer. Flexible/Fixed keep the simple 2% withdrawal fee.
6. **Yield-smoothing reserve for Fixed.** A small reserve absorbs minor rate variance so the displayed fixed APY holds to maturity.
7. **Per-user and per-tier caps.** Bound Boosted exposure (per-user limit + global cap) to contain systemic risk while the strategy matures.

**Strategist trust model & security (Boosted only):** the Boosted strategy needs an active manager (multisig/keeper) because DN and LP rebalancing aren't fully autonomous. Constrain it: **allowlisted venues only**, deposit/leverage caps, drawdown guards, withdrawal queue, and — critically — the strategist can move funds **only among allowlisted protocols, never to itself or any EOA**. Users still hold the shares; the non-custodial guarantee (no admin path to principal) holds at the router level.

**Compliance flag (not legal advice):** marketing a 30% "savings" account invites regulatory scrutiny (it can resemble an unregistered deposit/security). Prefer naming like "Boosted/Pro" with prominent **risk disclosures and no guaranteed-return language**, and get the tiering + disclosures reviewed by counsel before mainnet.

---

## 6. Exact change map (by layer)

### Contracts
| File | Lines | Change |
|---|---|---|
| `contracts/foundry.toml` | 20–21, 23–24 | add `monad_testnet` rpc + etherscan (`chain = 10143`) |
| `contracts/foundry.toml` | 10 | keep `cancun` (safe) |
| `contracts/script/Deploy.s.sol` | 25, 30, comments | replace hardcoded Base USDC; require `USDC_ADDRESS`; rpc example → `monad_testnet` |
| `contracts/script/DeployAccumulation.s.sol` | 26, 31, comments | same |
| `contracts/deployments/monad-testnet.json` | (new) | record Monad addresses, `chainId: 10143` |
| `contracts/src/MoolaHubGoalVault.sol` | accounting | **V2:** share-based, adapter hook |
| `contracts/src/MoolaHubSusuAccumulation.sol` | accounting | **V2:** share-based, adapter hook; keep `contributed[][]`; optional `MAX_MEMBERS` |
| `contracts/src/adapters/*` | (new) | `IYieldAdapter`, `PassthroughAdapter`, `ERC4626Adapter` |

### Backend (`artifacts/api-server`)
| File | Lines | Change |
|---|---|---|
| `src/lib/chain.ts` | 16, 27–30 | `monadTestnet`; RPC default → Monad |
| `src/lib/chain.ts` | 171–177 | `networkName()`→`"monad-testnet"`, `explorerUrl()`→ Monadscan |
| `src/lib/chain.ts` | 42–43, 247–306 | rename `eth*`→native/MON; re-tune gas top-up |
| `src/lib/chain.ts` | 726–749 | widen/replace log lookback |
| `src/lib/circleChain.ts` | 14, 33–36 | `monadTestnet`; RPC default |
| `src/lib/onchainIndexer.ts` | 12, 34–40, 121–130, 277–302 | `monadTestnet`; lookback/cursor; Multicall3/indexer; RPC limits |
| `scripts/set-fee-sink.mjs` | 12–17, 64 | `monadTestnet`; RPC; explorer string |
| `src/lib/privy.ts`, `src/lib/wallet.ts` | — | **no change** (auth-only) |
| `lib/db/src/schema/wallets.ts` | 11 | default `network` → `"monad-testnet"` (+ optional data migration) |
| `lib/db/src/schema/circles.ts` | 20 | policy for Base-era `contract_address` |

### Frontend (`artifacts/moolahub-app`)
| File | Lines | Change |
|---|---|---|
| `src/components/app/WalletSetupCard.tsx` | 1–2, ~131–137 | import `monadTestnet`; add `defaultChain`/`supportedChains` |
| `src/components/app/WalletSetupCard.tsx` | 16 | network label → "Monad Testnet" |
| `src/pages/wallet.tsx` | 11 | network label |
| `src/components/app/bits.tsx` | 52 | explorer fallback → Monadscan |
| `src/pages/goal-detail.tsx` | 24 | explorer fallback |
| `src/pages/circle-detail.tsx` | 332, 358 | explorer fallback ×2 |
| copy (~19 strings) | various | "Base"/"Basescan" → "Monad" |
| `src/hooks/useOnchain.ts` | — | no logic change (chain from Privy) |

---

## 7. Environment variable matrix

| Current | Where | Current default | Monad action |
|---|---|---|---|
| `BASE_NETWORK` | chain/circleChain/indexer/set-fee-sink | unset→testnet | retire or `CHAIN_NETWORK="testnet"`; no longer gates base vs baseSepolia |
| `BASE_RPC_URL` | chain/circleChain/indexer/set-fee-sink | `sepolia.base.org` | → `MONAD_RPC_URL`/`CHAIN_RPC_URL`, default `https://testnet-rpc.monad.xyz` |
| `BASE_EXPLORER_URL` | chain.ts:176 | `sepolia.basescan.org` | → `MONAD_EXPLORER_URL`, default `https://testnet.monadscan.com` |
| `USDC_CONTRACT_ADDRESS` | chain.ts:31 | `""` | Monad USDC (Circle native **[VERIFY]** or MockUSDC), 6-dp |
| `CIRCLE_FACTORY_ADDRESS` | chain/onchain/set-fee-sink | `""` | Monad redeploy |
| `GOAL_VAULT_ADDRESS` | chain/indexer/onchain/set-fee-sink | `""` | Monad redeploy (V2) |
| `ACCUMULATION_FACTORY_ADDRESS` | circleChain/onchain/set-fee-sink | `""` | Monad redeploy (V2) |
| `PLATFORM_PRIVATE_KEY` | chain/circleChain/settlement/set-fee-sink | unset | same key; **fund with MON** |
| `ENABLE_TEST_FAUCET` / `ENABLE_DEPOSIT_SYNC` | chain.ts | false | unchanged logic (relevant if MockUSDC) |
| `INDEXER_INTERVAL_MS` | indexer | 20000 | re-tune vs RPC limits |
| `PRIVY_APP_ID` / `PRIVY_APP_SECRET` | privy.ts | unset | Monad-enabled Privy app (dashboard) |
| `VITE_PRIVY_APP_ID` | frontend | from build | reuse (or Monad app id) |
| `VITE_BASE_NETWORK` | frontend | →"Base Sepolia" | retire → `VITE_CHAIN_NAME="Monad Testnet"` |
| *(new)* `CHAIN_ID` | — | — | optional explicit `10143` |

No chainId env exists today (implied by the viem chain object). No frontend RPC/contract env exists (backend- and dashboard-served).

---

## 8. Go-live checklist
- [ ] Privy dashboard: Monad 10143 enabled + paymaster registered; access confirmed with `monad@privy.io`
- [ ] Monad USDC address confirmed (6-dp) **[VERIFY]**; platform key funded with MON
- [ ] Contracts deployed (V2 + adapters) and **verified** on Monadscan; `monad-testnet.json` recorded
- [ ] Foundry tests + new share-math invariants + Slither pass on Monad Foundry fork
- [ ] Backend env switched; gas top-ups confirmed in MON; indexer catch-up tested after simulated outage
- [ ] Frontend Privy config + explorer fallbacks + copy updated; gasless tx works end-to-end on Monad
- [ ] DB `wallets.network` default updated; policy decided for Base-era rows
- [ ] Yield: launched on `PassthroughAdapter`; Curvance `cUSDC` adapter staged behind a switch with `emergencyExitToPassthrough()`

---

## 9. Open questions to confirm (do not ship without resolving the relevant ones)
1. **Monad-testnet USDC address** (Circle native) and decimals = 6. *(Phase 0/1)*
2. **Curvance `cUSDC` Monad-testnet market** address + audit/maturity before enabling real yield. *(Phase 4)*
3. **Privy** `defaultChain`/`supportedChains` key names in `@privy-io/react-auth ^3.28`, and per-chain paymaster behavior. *(Phase 3)*
4. **Gas top-up sizing** for Monad's gas-limit billing (re-tune `GAS_TOPUP_WEI`/`GAS_MIN_WEI`). *(Phase 2)*
5. **MonadVision verifier URL** if used as a secondary verifier. *(Phase 1)*
6. **`SmartWalletsProvider` scope** in the frontend (independent of Monad, but verify before launch). *(Phase 3)*
7. **Forfeited-yield destination:** compliant savers (default), treasury, or split? And the all-delinquent edge case. *(product, §5.8 B)*
8. **Forfeiture severity:** strict full-forfeit on any missed round (your spec) vs pro-rated by missed rounds. *(product, §5.8 C)*
9. **Principal-protected mode:** offer a no-yield (Passthrough) option for risk-averse users, given yield-bearing ≠ principal-guaranteed. *(product/risk, §5.8 E)*
10. **Auto-distribution trigger** at accumulation maturity: confirm backend-keeper-per-member model (vs on-chain push loop). *(Phase 4, §5.8 G)*
11. **Tier yield venues on Monad — confirm live + audited before wiring:** Flexible (Curvance/Euler/Upshift `earnAUSD`), Fixed (Spectra PT / Timeswap), Boosted (stable LP venues + any DN/leverage primitive). Each is **[VERIFY]** for testnet availability and risk. *(§5.9)*
12. **Boosted strategist model:** in-house managed strategy vault vs integrating an existing yield-bearing token; multisig/keeper setup, caps, and insurance-buffer size. *(§5.9)*
13. **Boosted fee schedule:** performance % + management % + withdrawal fee, and redemption-epoch length. *(§5.9)*
14. **Regulatory review** of the 30% "savings" framing and disclosures before mainnet. *(§5.9, not legal advice)*

---

*Appendix — role/control addresses (per `replit.md` policy): before any deployment, confirm `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, and the treasury/fee recipient explicitly; do not default them to the deployer.*
