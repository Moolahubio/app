---
name: MoolaHub on-chain config route & "isn't available on this deployment" banners
description: What the on-chain degradation banners actually mean and the api-server router-registration gotcha behind them.
---

# "On-chain X isn't available on this deployment" ⇒ check /api/onchain/config first

The frontend banners "On-chain goal savings isn't available on this deployment."
(PrivyGoalDepositForm) and "On-chain contributions aren't available on this deployment."
(PrivyContributeButton) are shown when required addresses are null:
- goal deposit: `!goalVault || !usdcAddress`
- accumulation-circle contribute: `!usdcAddress || !destination` (destination = platform)

All of those come from `useOnchainConfig()` → `GET /api/onchain/config`. If that request FAILS
(non-2xx), the react-query hook throws, `onchainConfig` is `undefined`, and every
`onchainConfig?.usdc / ?.goalVault / ?.platform` collapses to `null` → banners appear.

**So the banner is almost never about missing env/contracts — it's the config endpoint being
unreachable.** The contract addresses (USDC_CONTRACT_ADDRESS, GOAL_VAULT_ADDRESS,
CIRCLE_FACTORY_ADDRESS, ACCUMULATION_FACTORY_ADDRESS, CHAIN_RPC_URL, ENABLE_PRIVY_CUSTODY) live in
`[userenv.shared]` in `.replit` (shared scope ⇒ carries to prod); PLATFORM_PRIVATE_KEY is a Secret
(also carries). `platform` is derived from PLATFORM_PRIVATE_KEY via `platformAddress()`, `usdc` from
USDC_CONTRACT_ADDRESS via `usdcContract()` (both in api-server `lib/chain.ts`); goalVault etc. are
read straight from env in `routes/onchain.ts`.

**Root-cause class (this actually happened): a route file existed but was never mounted.**
`routes/onchain.ts` defined `GET /onchain/config` but was NOT imported/registered in
`routes/index.ts`, so `/api/onchain/config` 404'd in BOTH dev and prod. `app.ts` mounts the single
central router (`./routes`) at `/api`; there is no per-file `app.use` elsewhere.
**Why:** every api-server route must be wired into `routes/index.ts` (import + `router.use(...)`) —
adding a `routes/*.ts` file alone does nothing. Mount order is safe: all sibling routers use
distinct literal prefixes (no root `/:param` catch-alls), so position doesn't shadow.
**How to apply:** when a new api-server endpoint 404s, first confirm it's registered in
`routes/index.ts`. To diagnose these banners in prod, check deployment logs for
`GET /api/onchain/config` status (401 = mounted+auth-gated = good; 404 = unmounted). Unauthenticated
it returns 401 (route is `requireAuth`), which is the expected "mounted" signal.

Fixes here are code-only ⇒ prod (app.moolahub.io) needs a RE-PUBLISH to pick them up.
