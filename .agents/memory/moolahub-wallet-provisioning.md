---
name: MoolaHub wallet provisioning
description: Wallets are explicit-only (Privy-gated), never auto-created; money-movement must guard for no-wallet.
---

# Wallet provisioning is explicit, never implicit

Wallets are **not** auto-created on login/signup/dashboard/wallet-read. A user has
no wallet until they explicitly set one up via "Continue with Privy" in the Wallet
section, which calls `POST /auth/privy/link` — the **only** runtime path that calls
`createWalletForUser`.

**Why:** Auto-creating a backend-managed key wallet for every account is wasteful
and not what users expect; the product wants a single explicit Privy entry point
(Privy internally offers email or web3 wallet). The backend-managed (encrypted-key)
wallet is still the settlement signer — Privy is the *gate that triggers
provisioning*, not the custody layer. Full Privy-custodied signing is out of scope.

**How to apply:**
- Never reintroduce `createWalletForUser` into `finishLogin` (auth.ts), `dashboard.ts`,
  or `GET /wallet` (wallet.ts). Those use `getWalletForUser` and tolerate null.
- `GET /wallet` returns `hasWallet`, nullable `address`, plus `faucetEnabled` /
  `syncEnabled` (network/env-gated, see onchain-settlement memory). Frontend renders
  `WalletSetupCard` when `!hasWallet` and hides faucet/sync when their flag is false.
- Any flow that spends/settles funds must call `requireWalletForUser(userId)`
  (lib/wallet.ts) to fail with "Set up your wallet first…" instead of a misleading
  "insufficient balance" or a null signing key. Already wired into `allocateToGoal`,
  `contribute`, and `withdrawToAddress`.
- Adding a new WalletInfo field requires updating openapi.yaml WalletInfo + codegen,
  or `.parse()` strips it (see openapi-response-parse-strips-fields memory).
