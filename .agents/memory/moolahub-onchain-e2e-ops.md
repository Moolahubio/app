---
name: MoolaHub on-chain e2e ops (Monad testnet)
description: Why live on-chain e2e (goals/susu) flake or revert on Monad testnet, and the fixes — RPC read-your-write lag and CircleFactory owner must equal the platform wallet.
---

# Monad testnet on-chain e2e operational gotchas

## RPC read-your-write lag (~12s)
Monad's public RPC (`CHAIN_RPC_URL`) is load-balanced; a write (gas funding, nonce bump, contract deploy) is not immediately visible on the next read from a different backend. Symptoms: intermittent "insufficient balance", "nonce too low" / "higher priority" / "replacement transaction underpriced" on submit, and a freshly-deployed escrow address not resolving yet.

Mitigations, all in `chain.ts`:
- `awaitBalanceVisible` — require several consecutive confirming reads before proceeding (used inside `ensureGas`).
- `submitTx(send, attempts)` — retry ONLY pre-inclusion rejections (matched by `isTransientSubmitError`) with backoff; viem re-fetches a fresh nonce each attempt.
- longer confirmation polls (e.g. `escrowOf` 20 iters ≈ 30s).

**Why:** these are transient RPC-consistency artifacts, not real failures; retrying a pre-inclusion rejection is safe because the tx never entered the mempool. See the `submitTx` docblock for the one mainnet double-send edge on "nonce too low".

## CircleFactory.createCircle is onlyOwner — owner MUST be the platform wallet
`createCircle` (and `setFeeBps`/`setTreasury`/`setGuardian`) are `onlyOwner` on `MoolaHubCircleFactory` (Ownable2Step). The runtime signs `createCircle` with `PLATFORM_PRIVATE_KEY`, and `scripts/set-fee-sink.mjs` treats `PLATFORM_PRIVATE_KEY` as owner (it skips any contract whose `owner()` != platform). So the on-chain factory owner must equal the platform wallet.

If `createCircle` reverts with `0x118cdaa7` (OpenZeppelin `OwnableUnauthorizedAccount(address)`), the factory is owned by someone else — `Deploy.s.sol` sets owner = `OWNER_ADDRESS` (intended as a mainnet multisig, NOT the runtime signer). Fix on testnet: transfer factory ownership OWNER→platform via Ownable2Step — current owner calls `transferOwnership(platform)`, then platform calls `acceptOwnership()`.

`createCircle` also calls `reputation.setReporter(escrow, true)`, so `isAuthorizer[factory]` on the reputation contract must be true (owner sets it via `reputation.setAuthorizer(factory, true)`).

**Why:** the codebase's operational model is platform = factory owner; the deployment defaulted the owner to the multisig-intended `OWNER_ADDRESS`.

**Mainnet caveat:** `onlyOwner` `createCircle` is incompatible with a multisig owner (the backend can't sign as a multisig) — the factory needs a separate operator role before mainnet. Goals are unaffected: the goal vault is a permissionless singleton (deposit/withdraw are user-signed), so it never hits an owner gate at runtime.
