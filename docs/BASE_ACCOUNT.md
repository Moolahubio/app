# Base Account + Paymaster (gasless) — enablement

This is **scaffolded and feature-flagged**. With no credentials the app runs on
the server-custodial EVM model (current default). Flip the flag + provide the
CDP credentials below to turn on **Sign in with Base** (passkey smart wallet)
and **gasless USDC withdrawals** (sponsored UserOps). Validate on a networked
deploy (Base Sepolia) — passkeys + paymaster can't run in the CI sandbox.

## What's wired

- `src/lib/base/wagmi.ts` — wagmi config (Coinbase Smart Wallet connector, Base
  Sepolia/Base), `baseAccountEnabled()` flag, paymaster proxy URL.
- `src/components/base/BaseProviders.tsx` — Wagmi + React Query providers (mounted
  only when enabled, browser-only).
- `SignInWithBase.tsx` + `POST /api/auth/base` — connect a passkey smart wallet,
  sign a nonce, verify it server-side (ERC-1271/6492), issue a MoolaHub session.
  Base Account becomes the user's canonical wallet; the custodial key is unused
  for these users (the smart wallet self-signs).
- `BaseWithdraw.tsx` — gasless USDC withdrawal: an **EIP-5792 `useSendCalls`**
  with `capabilities.paymasterService` pointed at our proxy, then
  `recordWithdrawalAction` debits the ledger with the on-chain reference.
- `POST /api/paymaster` — server proxy to the CDP Paymaster (keeps the URL/secret
  off the client).
- Mounted (gated) on `/login` (`BaseAuthPanel`) and `/wallet` (`BaseWalletActions`).

## Provide these (Coinbase Developer Platform — portal.cdp.coinbase.com)

| Env var | What |
| --- | --- |
| `NEXT_PUBLIC_BASE_ACCOUNT` | set to `"true"` to enable the experience |
| `NEXT_PUBLIC_ONCHAINKIT_API_KEY` | CDP client API key |
| `NEXT_PUBLIC_CDP_PROJECT_ID` | CDP project id |
| `PAYMASTER_SERVICE_URL` | CDP Paymaster & Bundler endpoint (server-side) |
| `NEXT_PUBLIC_BASE_RPC_URL` / `BASE_RPC_URL` | dedicated Base RPC (client/server) |
| `NEXT_PUBLIC_USDC_ADDRESS` / `USDC_CONTRACT_ADDRESS` | USDC contract (Base Sepolia default set) |
| `NEXT_PUBLIC_BASE_CHAIN` | `baseSepolia` (default) or `base` |

In the CDP dashboard, set the **Paymaster policy**: allowlist the USDC contract
+ the `transfer` selector, and set per-user / global spend caps so sponsorship
can't be drained.

## Enable + validate

1. Set the env vars above (`NEXT_PUBLIC_BASE_ACCOUNT="true"`), deploy to an HTTPS
   host (passkeys need a secure context + a registered domain).
2. Fund the platform account (server ops) with Base Sepolia ETH + test USDC
   (`npm run base:init` prints the address; faucets: Base docs + faucet.circle.com).
3. On `/login` → "Continue with Base" → create/return a passkey smart wallet.
4. On `/wallet` → "Withdraw USDC · gasless" → confirm a sponsored UserOp lands on
   Base Sepolia (basescan) and the ledger debits.

## Follow-ups (post-validation)

- Resolve the EIP-5792 bundle id → final tx hash via `useCallsStatus` (currently
  the bundle id is recorded as the reference).
- Make the Base Account address the displayed deposit address for these users
  (drop the custodial placeholder) — a small schema/wallet-provisioning change.
- Sponsor circle **contributions** the same way (extend `useSendCalls`).
- Builder Code attribution — deferred to mainnet.
