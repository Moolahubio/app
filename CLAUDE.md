# CLAUDE.md — Moolahub

Orientation for Claude Code working in this repo. Source of truth: https://github.com/Moolahubio/app

## Current initiative: migrate to Monad + add yield-bearing savings
- **Design / full plan:** `docs/monad-migration-plan.md` (exact file/line change map §6, env matrix §7, yield design §5, forfeiture rules §5.8, three-tier savings §5.9, open questions §9).
- **Build backlog (do this):** `docs/monad-build-plan.md` — ordered, PR-sized milestones M0–M8 with acceptance criteria and blockers.
- Goal: move the on-chain layer from **Base Sepolia (84532)** to **Monad Testnet (10143, MON gas)**, then make savings + accumulation circles yield-bearing.

## Non-negotiables
- The double-entry **ledger is the source of truth**; on-chain calls are best-effort — never make a request path throw on RPC failure.
- **Non-custodial:** no admin/owner/guardian path to user principal, in any contract. Preserve it.
- Before any deploy, **confirm `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, treasury/fee-recipient explicitly** (per `replit.md`) — never default to the deployer.
- Resolve the relevant `[VERIFY]` item (plan §9) before wiring any external address.

## Repo map
- `contracts/` — Foundry (solc 0.8.28, evm_version cancun). Vaults: `MoolaHubGoalVault` (savings), `MoolaHubSusuAccumulation` (accumulation circles), `MoolaHubSusuEscrow` (rotating Susu), factories, `MoolaHubTreasury`, `MoolaHubReputation`.
- `artifacts/api-server` — Express 5 / Drizzle / viem. Chain code: `src/lib/chain.ts`, `circleChain.ts`, `onchainIndexer.ts`. Privy (auth only): `src/lib/privy.ts`.
- `artifacts/moolahub-app` — Vite/React, Privy embedded/smart wallets (`src/hooks/useOnchain.ts`, `src/components/app/WalletSetupCard.tsx`).
- `lib/db` — Drizzle schema (`src/schema/*`). `lib/api-spec` — OpenAPI → codegen.

## Commands
- API dev: `pnpm --filter @workspace/api-server run dev`
- Typecheck/build: `pnpm run typecheck` · `pnpm run build`
- API codegen: `pnpm --filter @workspace/api-spec run codegen`
- DB push (dev): `pnpm --filter @workspace/db run push`
- Contracts: `cd contracts && forge test` (use the Monad Foundry fork to deploy)

## Monad quick facts
Chain 10143 · MON (18-dp gas) · RPC `https://testnet-rpc.monad.xyz` · explorer `https://testnet.monadscan.com` · EVM = Fusaka (cancun-safe) · gas charged on **gas limit** · viem `monadTestnet` (≥2.45; repo has ^2.52). Full table in plan §2.
