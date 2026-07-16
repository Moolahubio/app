# CLAUDE.md — Moolahub

Orientation for Claude Code working in this repo. Source of truth: https://github.com/Moolahubio/app

## Current initiative: launch on Base Mainnet with real yield
- **Architecture / full spec:** `docs/base-mainnet-architecture.md` — Privy embedded wallets + app-sponsored gas, Privy Earn (Morpho) yield for goals, `MoolaHubCircleVault` for group savings, Stripe/MoonPay onramp, schema/API/UI change map, complete core code, security model, rollout milestones.
- **Build prompt (execution order + gates):** `docs/replit-base-mainnet-build-prompt.md`.
- The previous **Monad migration is cancelled**; `docs/monad-*.md` are superseded and kept only until archived (build Milestone A moves them to `docs/archive/`).

## Non-negotiables
- The double-entry **ledger is the source of truth**; on-chain calls are best-effort — never make a request path throw on RPC failure.
- **Non-custodial:** no admin/owner/guardian path to user principal, in any contract or service. No private key material in Moolahub's DB or env (Privy TEE holds keys).
- **No mock data:** every displayed balance/yield/APY derives from the Privy position API or on-chain reads. Pending state over fabricated numbers, always.
- Before any deploy, **confirm `OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, `TREASURY_ADDRESS` explicitly** (per `replit.md`) — never default to the deployer.
- Resolve the relevant `[VERIFY]` item (architecture §2/§18) before wiring any external API or address.
- Circles stay behind `CIRCLES_ENABLED=false` until the contract audit is signed off.

## Repo map
- `contracts/` — Foundry (solc 0.8.28). Target state: `MoolaHubCircleVault` + factory + `MoolaHubVaultRegistry` (+ kept `MoolaHubTreasury`, `MoolaHubReputation`); legacy `GoalVault`/`SusuEscrow`/`SusuAccumulation` are deleted by the Base build.
- `artifacts/api-server` — Express 5 / Drizzle / viem. Chain & money code: `src/lib/base.ts`, `privyEarn.ts`, `goalFunds.ts`, `circleChain.ts`, `keeper.ts`, `onchainIndexer.ts`, `ledger.ts`. Privy auth: `src/lib/privy.ts`.
- `artifacts/moolahub-app` — Vite/React, Privy React SDK (`@privy-io/react-auth` ≥ 3.33.1 + `@stripe/crypto`), onramp + earnings UI.
- `lib/db` — Drizzle schema (`src/schema/*`). `lib/api-spec` — OpenAPI → codegen.

## Commands
- API dev: `pnpm --filter @workspace/api-server run dev`
- Typecheck/build: `pnpm run typecheck` · `pnpm run build`
- API codegen: `pnpm --filter @workspace/api-spec run codegen`
- DB push (dev): `pnpm --filter @workspace/db run push`
- Contracts: `cd contracts && forge test` (fork tests run against Base Mainnet + the real Morpho vault)

## Base quick facts
Chain **8453** (`eip155:8453`) · gas app-sponsored via Privy (EIP-7702) · USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 dp) · explorer `https://basescan.org` · yield = Morpho ERC-4626 vault via Privy Earn (`assets_in_vault − (total_deposited − total_withdrawn)`) · full verified-facts table in architecture §2.
