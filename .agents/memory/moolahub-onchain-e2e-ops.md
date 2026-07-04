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

## Platform gas wallet drains → faucet/settlement stuck "settling on-chain…"
ALL on-chain settlement — faucet mints, `ensureGas` user-wallet top-ups (for non-custodial withdrawals), and payouts/goal/circle sends — is gas-funded by ONE platform signer wallet (`PLATFORM_PRIVATE_KEY`). It is a single point of failure: as users claim the faucet and withdraw, its native MON drains to ~0 and every on-chain path stalls at once.

Symptoms: a deposit sits at "settling on-chain…" in the activity UI (`transactions.onchain_status='pending'`, no `tx_hash`); its `onchain_transfers` row keeps `last_error` = `mint reverted "Signer had insufficient balance"`; the reconciler logs `settlement reconciler pass processed=1 confirmed=0` every pass (one poison row it re-claims each time); after `MAX_ATTEMPTS` (default 10) the row dead-letters to `status='failed'`.

**"Signer had insufficient balance" is a NODE-level gas error, NOT a contract/treasury problem.** viem surfaces it under the "contract function reverted" umbrella, which is misleading. Prove the distinction with a read-only probe: `publicClient.call({ account: platform, to: mockUsdc, data: encodeFunctionData(mint,...) })` — `eth_call` runs the logic IGNORING the signer's gas, so if it SUCCEEDS the contract is fine and the failure is pure MON exhaustion. (MockUSDC.mint is a free permissionless `_mint`; platform's MockUSDC balance is irrelevant/0.)

**Fix = refill the platform signer wallet with MON.** On testnet the `DEPLOYER` wallet (`DEPLOYER_PRIVATE_KEY`) holds the most MON and is the natural refill source: send native MON deployer→platform (viem `sendTransaction`, chainId 10143), then restart `artifacts/api-server` (or wait) so the reconciler retries and confirms. `GAS_MIN_WEI`≈0.01 / `GAS_TOPUP_WEI`≈0.05 MON per user top-up, so keep the platform wallet ≥~1 MON for a demo.

**Do NOT manually re-queue a dead-lettered faucet row.** `markFailed`→`reverseForKind`→`reverseLedgerTransaction` already reversed its ledger credit exactly-once (CAS on `status='processing'`), so there is no phantom balance. Flipping a `failed` faucet row back to `pending` would mint 250 test USDC on-chain against a ledger that shows the credit reversed → mismatch. Correct recovery: the user simply re-claims the faucet (a fresh mint), which now succeeds once gas is restored.

**Why:** the reconciler and mint logic are correct; the wallet was empty. Durable prevention (auto-refill platform from a treasury, and/or a fail-fast faucet pre-check that refuses to book a "pending" deposit when platform gas is low so it never shows "settling on-chain…" forever) is a follow-up, not a settlement bug.
