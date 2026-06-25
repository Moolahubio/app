# Monad Migration — Build Backlog (for Claude Code)

**Read first:** [`docs/monad-migration-plan.md`](./monad-migration-plan.md) — the full design, exact file/line change map (§6), env matrix (§7), yield design (§5), forfeiture rules (§5.8), and three-tier savings (§5.9). This file turns that plan into ordered, PR-sized tasks.

**Ground rules**
- The double-entry **ledger is the source of truth**; on-chain is best-effort. Don't break that.
- **Non-custodial invariant:** no admin/owner path to user principal — preserve it in every contract change.
- Per `replit.md`: before any deploy, **confirm `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, treasury/fee-recipient explicitly** — never default to the deployer.
- Each milestone = one reviewable PR. Don't start a task whose **Blocked-by** isn't resolved.
- Verified Monad facts and the `[VERIFY]` list are in the plan §2 and §9 — resolve the relevant `[VERIFY]` item before wiring an address.

**Useful commands** (`replit.md`)
- API server dev: `pnpm --filter @workspace/api-server run dev`
- Typecheck / build: `pnpm run typecheck` · `pnpm run build`
- Regenerate API hooks/zod: `pnpm --filter @workspace/api-spec run codegen`
- DB push (dev): `pnpm --filter @workspace/db run push`
- Contracts: `cd contracts && forge test` (use the **Monad Foundry fork** for deploys)

---

## Milestone 0 — Branch & guardrails
- **0.1** Create branch `feat/monad-migration`. Commit the two planning docs.
- **0.2** Add a `.env.example` documenting the new env names (plan §7) with placeholders. No secrets.
- *Acceptance:* branch pushed; CI typecheck green; docs committed.

## Milestone 1 — Contracts: chain migration (no logic change)
*Blocked-by:* `[VERIFY]` Monad USDC address+decimals (plan §9.1); confirmed role addresses.
- **1.1** `contracts/foundry.toml`: add `[rpc_endpoints] monad_testnet` and `[etherscan] monad_testnet { chain = 10143, url = https://api.etherscan.io/v2/api }`. Keep `evm_version = "cancun"`.
- **1.2** `contracts/script/Deploy.s.sol` (line 25/30) & `DeployAccumulation.s.sol` (line 26/31): remove hardcoded Base USDC; make `USDC_ADDRESS` required (`vm.envAddress`); update rpc-url examples → `monad_testnet`.
- **1.3** Deploy MockUSDC **or** wire Circle native testnet USDC (decision in plan §0.3); keep 6 decimals.
- **1.4** Deploy all contracts to Monad (Monad Foundry fork); write `contracts/deployments/monad-testnet.json` with `chainId: 10143`, explorer, roles, addresses.
- **1.5** Verify every contract on Monadscan (plan §4 Phase 1.6); verify clone implementations once.
- *Acceptance:* `forge test` green; contracts live + verified on Monad testnet; deployments JSON committed.

## Milestone 2 — Backend: chain swap + env
*Blocked-by:* M1 addresses.
- **2.1** Swap `base/baseSepolia` → `monadTestnet` in `src/lib/chain.ts`, `src/lib/circleChain.ts`, `src/lib/onchainIndexer.ts`, `scripts/set-fee-sink.mjs` (collapse the `IS_MAINNET` ternary; RPC default `https://testnet-rpc.monad.xyz`).
- **2.2** `chain.ts`: `networkName()` → `"monad-testnet"`; `explorerUrl()` default → `https://testnet.monadscan.com`; fix `set-fee-sink.mjs` explorer string.
- **2.3** Rename `eth*` → native/MON labels (`PlatformBalances`, `ethBalanceWei`); re-tune `GAS_TOPUP_WEI`/`GAS_MIN_WEI` for Monad gas-limit billing (`[VERIFY]` costs).
- **2.4** Env rename with back-compat reads (`CHAIN_RPC_URL ?? BASE_RPC_URL`, etc.); set Monad contract addresses; fund `PLATFORM_PRIVATE_KEY` with MON.
- **2.5** Indexer for Monad: widen `BLOCK_LOOKBACK`/`getIncomingUsdc` window or add a persisted block cursor; batch reads via Multicall3 and/or move heavy logs to an indexer; respect 50/25 rps limits.
- **2.6** DB: `lib/db/src/schema/wallets.ts` default `network` → `"monad-testnet"`; decide policy for Base-era `circles.contract_address`.
- *Acceptance:* staging API points at Monad; deposit→goal→withdraw and circle create→contribute→settle work; gas tops up in MON; indexer survives a simulated outage.

## Milestone 3 — Frontend: Privy + explorer + copy
*Blocked-by:* Privy dashboard step (enable Monad 10143 + register paymaster — plan §4 Phase 0).
- **3.1** `WalletSetupCard.tsx`: import `monadTestnet`; add `defaultChain`/`supportedChains` to `PrivyProvider` config. `[VERIFY]` key names against `@privy-io/react-auth ^3.28`.
- **3.2** Replace hardcoded `sepolia.basescan.org` in `bits.tsx:52`, `goal-detail.tsx:24`, `circle-detail.tsx:332,358` → Monad explorer (extract one shared constant).
- **3.3** Network label (`WalletSetupCard.tsx:16`, `wallet.tsx:11`) → "Monad Testnet" (retire `VITE_BASE_NETWORK`).
- **3.4** Update ~19 "Base"/"Basescan" copy strings (plan §5 frontend report).
- *Acceptance:* full Privy login → sponsored tx on Monad end-to-end; explorer links resolve; no "Base" copy remains.

## Milestone 4 — Yield core (V2 vaults, share accounting)
*Blocked-by:* `[VERIFY]` a live/audited Monad lender (plan §9.2). Ship on Passthrough first.
- **4.1** New `contracts/src/adapters/`: `IYieldAdapter`, `PassthroughAdapter`, `ERC4626Adapter` (+ tests).
- **4.2** `MoolaHubGoalVaultV2`: share-based accounting + `principalOf` tracking + adapter hook; preserve locked-fee feature and non-custodial invariant.
- **4.3** `MoolaHubSusuAccumulationV2`: share-based, keep `contributed[][]`, add `principalOf`; optional `MAX_MEMBERS`.
- **4.4** Invariant/fuzz tests: `Σ convertToAssets(shares) ≤ totalManagedAssets()`; first-depositor inflation (virtual shares/offset); last-withdrawer can always exit; fee-on-yield.
- **4.5** Deploy V2 with `PassthroughAdapter` (behaves like today); Slither on new code.
- *Acceptance:* V2 deployed on Passthrough = behavior-identical to V1; all invariants pass; Slither clean.

## Milestone 5 — Circle forfeiture logic
*Blocked-by:* M4; product decisions §9.7–9.8 (destination + strict vs pro-rated).
- **5.1** Implement §5.8(A): delinquent member burns all shares, paid `min(principal, grossRedeemable) − fee`; forfeited yield redistributes via exchange rate; all-delinquent → treasury.
- **5.2** Fee branching (§5.8 D): compliant fee on principal+yield, delinquent on principal; clamp `fee ≤ payout`; cancelled = fee-free.
- **5.3** Emit explicit settlement events (`AccumulationSettled(member, principal, yieldPaid, yieldForfeited, fee)`).
- *Acceptance:* tests reproduce the worked examples (compliant $1000+$100→$1078; delinquent→$980 with $100 redistributed); invariants hold.

## Milestone 6 — Three-tier savings
*Blocked-by:* M4–M5; product decisions §9.11–9.14 (venues, strategist, fees, legal).
- **6.1** `SavingsRouter` (or extend GoalVaultV2): per-slot `tier`, `principalOf`, `sharesIn[strategy]`, `lock`.
- **6.2** `IStrategyVault` + `FlexibleStrategy` (lending), `FixedStrategy` (Spectra/Timeswap), `BoostedStrategy` (managed: allowlisted venues, caps, drawdown guard, withdrawal-epoch queue, insurance skim).
- **6.3** Glide-path + auto-derisk circuit breaker hooks; performance/management fee on Boosted.
- **6.4** Risk isolation tests (Boosted loss can't touch Flexible/Fixed); epoch redemption tests.
- *Acceptance:* three tiers selectable per goal/circle; isolation + redemption + insurance-buffer tests pass; no admin path to principal.

## Milestone 7 — Indexer/ledger reconciliation for V2 events
*Blocked-by:* M4–M6 event shapes.
- **7.1** Update ABIs/parsers in `chain.ts` + `onchainIndexer.ts` to the new deposit/withdraw/settlement events.
- **7.2** Add ledger posting types for yield accrual, forfeiture, redistribution, performance fee.
- *Acceptance:* ledger reconciles against V2 on-chain state across all tiers and forfeiture paths.

## Milestone 8 — End-to-end verification & go-live
- Run the full **go-live checklist** in plan §8. Use a subagent for a final security/reader review of contracts + reconciliation before any mainnet discussion.

---

### Suggested PR order
M0 → M1 → M2 → M3 (M1–M3 = the pure migration; shippable on its own) → M4 → M5 → M6 → M7 → M8.
The migration (M1–M3) and the yield program (M4–M7) are independently shippable; you can go live on Monad first, then layer yield.
