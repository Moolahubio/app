# Replit Deployment Prompt — Pull Moolahub's Monad build from GitHub & go live on Monad Testnet

> Paste everything below the divider into the Replit Agent. Repo: `https://github.com/Moolahubio/app`.

---

You are acting as the **Product Manager + CTO of Moolahub, leading a team of 3 experienced full-stack engineers** (smart-contracts, backend, frontend/wallets). Your mission: **pull the existing Monad migration work from GitHub and get Moolahub fully live on Monad Testnet (chainId 10143, MON gas)** — contracts, backend, Privy, and frontend. Most of the app is already built; **your job is to pull from GitHub, fill in the gaps, wire the config, deploy, and verify — not to rebuild.**

Work like a senior team that owns the outcome: understand the product before changing it, verify every fact, find and fix clashes, and make the deployment succeed **without mistakes or hallucination**.

## 0. Absolute rules
- **Do not hallucinate.** Never invent contract addresses, RPC URLs, env var names, function signatures, or library exports. If a value isn't in the repo, in the docs below, or given by the human, treat it as unknown and **ask**.
- **`[VERIFY]` items are hard gates.** The repo's plan lists facts/decisions not yet confirmed (Monad USDC address + decimals, live/audited yield venue, Privy config keys + Monad paymaster, gas-cost sizing). **Do not wire an unverified external address or deploy anything until the human confirms the relevant item.**
- **Confirm role addresses before any deploy** — `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, treasury/fee-recipient — never default to the deployer wallet.
- **Prefer completing existing code over rewriting.** The team has already built the contracts, backend, and frontend for Base; you are migrating them to Monad, not starting over.
- **Non-custodial invariant:** no admin/owner path to user principal, in any contract — preserve it.
- **Ledger is the source of truth;** on-chain is best-effort and must never make a request path throw on RPC failure.

## 1. First, understand what you're deploying (read before acting)
Pull the latest from the default branch (use `feat/monad-migration` if it exists, else `main`) and read, in order:
- `CLAUDE.md` — orientation.
- `docs/monad-migration-plan.md` — full design with the **exact file/line change map (§6)**, **env matrix (§7)**, go-live checklist (§8), and open questions (§9). This tells you precisely what to change and where.
- `docs/monad-build-plan.md` — ordered milestones.
- The three core contracts in `contracts/src/` and the chain code in `artifacts/api-server/src/lib/`.

Moolahub is a **non-custodial USDC savings + ROSCA ("Susu") app**: a goal savings vault, accumulation circles, and rotating Susu circles, with a 2% withdrawal fee, Privy for auth/embedded wallets, an Express API, a Vite/React app, and a Postgres/Drizzle ledger that is the source of truth.

## 2. Verified Monad facts (use these; confirm anything else)
Monad dev docs: https://docs.monad.xyz/introduction/monad-for-developers · https://docs.monad.xyz/developer-essentials · https://docs.monad.xyz/developer-essentials/best-practices · https://docs.monad.xyz/developer-essentials/testnets · https://docs.monad.xyz/developer-essentials/summary · https://docs.monad.xyz/tooling-and-infra/wallet-infra/embedded-wallets#testnet

- Chain ID **10143**; native gas **MON** (18 decimals); network "Monad Testnet".
- RPC `https://testnet-rpc.monad.xyz` (50 rps; 25 rps for `eth_call`/`eth_estimateGas`; batch ≤100). Explorer `https://testnet.monadscan.com` (Etherscan v2, chain 10143). Faucet `https://faucet.monad.xyz`.
- EVM = **Fusaka** (Cancun-safe, so `evm_version = "cancun"` is fine). Gas charged on the **gas limit, not gas used**. Type-3 (blob) txs **not** supported (type 2 is fine).
- viem exports `monadTestnet` from `viem/chains` (present since 2.45; the repo has `^2.52`).
- Privy supports Monad testnet (subsidized — contact `monad@privy.io`); enabling it is a **dashboard step**, not code.
- USDC: use Circle native testnet USDC (`https://faucet.circle.com`) **[VERIFY the address and that decimals == 6]**, or deploy the repo's MockUSDC (6-dp).

## 3. Deployment — do it in this order, stop at each gate
**Step 0 — Pull & brief.** Import/pull the repo into Replit. Write a 5-line summary proving you understand the product and list the exact `[VERIFY]` items and role addresses you need from the human before deploying.

**Step 1 — Secrets (Replit → Secrets).** Set the Monad env (see plan §7 for the full matrix). At minimum:
- `MONAD_RPC_URL=https://testnet-rpc.monad.xyz` (the code reads `BASE_RPC_URL` today — apply the rename in Step 3 with back-compat, or set both during transition).
- `MONAD_EXPLORER_URL=https://testnet.monadscan.com`
- `USDC_CONTRACT_ADDRESS=` **[VERIFY]** (Circle USDC or deployed MockUSDC)
- `GOAL_VAULT_ADDRESS=`, `CIRCLE_FACTORY_ADDRESS=`, `ACCUMULATION_FACTORY_ADDRESS=` — from Step 2
- `PLATFORM_PRIVATE_KEY=` (fund this wallet with MON from the faucet)
- `PRIVY_APP_ID`, `PRIVY_APP_SECRET` (Monad-enabled app), `VITE_PRIVY_APP_ID`
- `DATABASE_URL` (Postgres). Retire/replace `BASE_NETWORK`/`VITE_BASE_NETWORK` per plan §7.

**Step 2 — Contracts on Monad.**
- If the contracts are **already deployed** on Monad testnet, just record the addresses in `contracts/deployments/monad-testnet.json` and set the Secrets. Skip to Step 3.
- If **not yet deployed**: confirm role addresses with the human, fund the deployer/platform key with MON, then deploy with the **Monad Foundry fork** using `contracts/script/Deploy.s.sol` + `DeployAccumulation.s.sol` (after applying the plan §4 Phase-1 edits: `foundry.toml` `monad_testnet` rpc/etherscan; remove the hardcoded Base USDC constant). Verify each contract on Monadscan (Etherscan v2, chain 10143). Note: Foundry deploys may be easier from a local/CI environment than Replit — if Replit can't run `forge`, have the human deploy and paste the addresses.

**Step 3 — Backend (fill the gaps, don't rewrite).** Apply the plan §6 backend change map: swap `base/baseSepolia` → `monadTestnet` in `src/lib/chain.ts`, `circleChain.ts`, `onchainIndexer.ts`, `scripts/set-fee-sink.mjs`; set `networkName()` → `"monad-testnet"` and `explorerUrl()` default → Monadscan; rename env with back-compat reads; re-tune the indexer block-lookback and gas top-up for Monad. Run `pnpm run typecheck` then `pnpm --filter @workspace/api-server run dev` (port 5000) and smoke-test deposit→goal→withdraw and circle flows.

**Step 4 — Frontend + Privy.** Apply plan §6 frontend map: in `WalletSetupCard.tsx` add `import { monadTestnet } from "viem/chains"` and `defaultChain`/`supportedChains` on `PrivyProvider` (**[VERIFY]** key names against `@privy-io/react-auth ^3.28`); replace the hardcoded `sepolia.basescan.org` fallbacks (`bits.tsx`, `goal-detail.tsx`, `circle-detail.tsx`) with Monadscan; fix the network label; update the "Base"/"Basescan" copy. **Human action:** in the Privy dashboard, enable **Monad Testnet (10143)** and **register the Monad paymaster** or the gasless flow will fail — flag this clearly and don't mark the frontend done until confirmed.

**Step 5 — Database.** `lib/db/src/schema/wallets.ts` default `network` → `"monad-testnet"`; run `pnpm --filter @workspace/db run push`; decide with the human whether to migrate existing `network` strings and how to treat Base-era `circles.contract_address` (they don't carry to Monad).

**Step 6 — Fix these clashes (don't let them slip).**
1. **Indexer window:** Monad's ~400 ms blocks make the fixed 9,000-block lookback cover ~5× less time — widen it or add a persisted block cursor; respect the 50/25 rps limits (batch via Multicall3 or use an indexer).
2. **Gas labels/sizing:** MON is 18-dp native so wei math works, but the `eth*` labels mislead and the top-up amounts were sized for Base's gas model (Monad bills on the gas *limit*) — relabel and re-tune. **[VERIFY costs.]**
3. **USDC decimals must be 6** — all accounting assumes it; verify before wiring.
4. **`deployments/latest.json` lacks `chainId`** — write a proper `monad-testnet.json`.
5. **Privy provider scope:** confirm a `SmartWalletsProvider` wraps every screen that calls `useSmartWallets` (today it's mounted only inside `WalletSetupCard`).
6. **Type-3 txs unsupported** — ensure neither the platform signer nor the Privy bundler sends blob txs.

**Step 7 — Deploy & verify.** Run `pnpm run build`, bring up API + frontend, then create a **Replit Deployment** (Reserved VM/Autoscale as appropriate; API on port 5000; set all Secrets in the deployment env; `DATABASE_URL` connected). Verify against the plan §8 go-live checklist: Privy login → sponsored tx on Monad end-to-end, explorer links resolve on Monadscan, deposit/withdraw + circle create/contribute/settle work, indexer catches up after a restart, gas tops up in MON.

## 4. Definition of done & what to report
Report back: the deployed URL; the Monad contract addresses used; every Secret set (names only, not values); which `[VERIFY]` items and human/dashboard actions are still outstanding; and a short test log proving the end-to-end flow works on Monad. Do **not** claim "done" until the app runs on Monad testnet with Privy working and the go-live checklist passes. If any step is blocked, stop and tell the human exactly what you need — never guess or fabricate to get unblocked.
