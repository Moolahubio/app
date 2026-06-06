# MoolaHub Smart Contract Security Audit

> **Remediation round (v2.1) — addresses the GitHub/Slither scan.** All reported items resolved; `forge test` 31/31; `slither` 0 results with the project config. Fixes:
> - **incorrect-equality** (`round == 0`): replaced with `round < 1` (derived sentinel, not a balance check).
> - **missing zero-address validation** (`guardian` in both factories' constructor + `setGuardian`): now reverts on the zero address.
> - **reentrancy in `createCircle` / `createAccumulationCircle`**: factories are now `ReentrancyGuard`/`nonReentrant`, the registry `circleOf` write and event are emitted before the external `setReporter`/`initialize` calls (strict CEI).
> - **reentrancy in `*WithPermit`**: the EIP-2612 permit paths were **removed entirely** — ERC-4337 smart accounts can't produce a valid permit signature (the app uses `approve` + `contribute`), so they were dead code and the source of the external-call-before-state-write. This also cut attack surface.
> - **reentrancy-no-eth in `_contribute`** (found during remediation): rotation settlement is now inlined so every state write (round advance / completion) precedes all token transfers.
> - **calls inside a loop** (`flagRound` / `_flagDelinquents`): now collect delinquents and report via a single `recordStrikeBatch`, wrapped in `try/catch` so a misbehaving registry can never block cancellation/refunds.
> - **shadowing-local** (`setUnlock` param shadowed the `unlockAt` getter): parameter renamed.
> - **uninitialized-local** (settlement locals): explicitly initialized.
> - **block-timestamp** (#6–9): accepted and documented — used only for round/maturity scheduling where validator drift (seconds) is negligible vs. day-long rounds; the `timestamp` detector is excluded in `contracts/slither.config.json` with this rationale.

**Engagement type:** Internal security review (independent audit firm role)
**Date:** June 2026 (v2.1 remediation)
**Network:** Base Sepolia (testnet)
**Codebase:** `Moolahubio/app` — `contracts/` (Foundry, Solidity 0.8.28, OpenZeppelin v5.1.0)
**Deployer / owner under review:** `0xB4376025E1575f8c4f62c69D217Aaff3ffA4d641`

> **Disclaimer.** This review was performed on the contract source in the repository and on the live on-chain configuration on Base Sepolia. It is a best-effort security assessment, not a guarantee of absence of bugs. It does **not** authorize a mainnet launch. A mainnet deployment that custodies real user funds requires a full third-party audit by an independent firm. Findings reflect the code at review time; the **deployed** escrow implementation predates fix **L-01** (see §5).

---

## 1. Executive summary

MoolaHub's on-chain layer comprises six contracts: a rotating-savings escrow (`MoolaHubSusuEscrow`) deployed as clones by `MoolaHubCircleFactory`, a personal-savings vault (`MoolaHubGoalVault`), a fee sink (`MoolaHubTreasury`), a bad-actor registry (`MoolaHubReputation`), and the newly added accumulation-savings circle (`MoolaHubSusuAccumulation`).

**Overall assessment: the contracts are well-structured and follow sound security practices** — `SafeERC20` everywhere, `ReentrancyGuard` on all fund-moving functions, checks-effects-interactions ordering, immutable economic parameters, and a strictly non-discretionary escrow design (no admin can redirect or seize user funds). We found **no Critical or High severity issues.** We identified **1 Medium**, **5 Low**, and several Informational items, plus one false positive from static analysis. The one Low that affects the deployed code (L-01, a CEI ordering nuance, not exploitable) has been fixed in source and should be redeployed.

**Verification performed**
- Manual line-by-line review of all six contracts.
- Full Foundry test suite: **27/27 passing** (rotation, accumulation, goal vault, factory; happy paths, reverts, refunds, delinquency, conservation invariants).
- Static analysis with **Slither**: after remediation, only one reviewed false positive remains.
- **On-chain configuration verification** via live `eth_call` against Base Sepolia (see §3) — the deployment is correctly wired and owned by you.

---

## 2. Scope

| Contract | LoC | Role |
|----------|-----|------|
| `MoolaHubSusuEscrow.sol` | ~240 | Rotation Susu escrow (clone) |
| `MoolaHubCircleFactory.sol` | ~115 | Deterministic clone factory + registry |
| `MoolaHubGoalVault.sol` | ~120 | Personal goal savings (non-custodial) |
| `MoolaHubTreasury.sol` | ~33 | Fee sink |
| `MoolaHubReputation.sol` | ~60 | Bad-actor strike registry |
| `MoolaHubSusuAccumulation.sol` | ~210 | **New** — accumulation Susu (everyone saves their own) |

Out of scope: the Privy/ERC-4337 account layer, the off-chain backend/indexer, the paymaster, and the ERC-20 token itself (USDC).

---

## 3. Deployed instances (verified on-chain)

All addresses below were confirmed by reading their public getters live on Base Sepolia. Configuration matches intent; **all admin roles are held by your address** `0xB437…d641`, and `feeBps = 200` (2%) across the stack.

| Contract | Address | Verified config |
|----------|---------|-----------------|
| Token (test) | `0xf03C3dA6fb2a59775043CAC8ABfb75c4627728bB` | symbol `USDC`, 6 dp — **a MockUSDC, not Circle's USDC** (see I-01) |
| Treasury | `0x2C25dE21170668BFA0DDC1967F746d1D4f5FE8c2` | owner = you |
| Reputation | `0x7F78497494AB186d62200b279bb63aB8d5281b2D` | owner = you; `factory()` → the factory ✓ |
| Escrow implementation | `0xfd6EeE6a3D4208b877a95C19f348F1e7661Dc49A` | logic only (predates L-01 fix) |
| CircleFactory | `0x013e2f7d212Dd06302998a53D4775Fdda126ca4C` | owner = you; guardian = you; feeBps 200; impl/usdc/treasury/reputation all correct ✓ |
| GoalVault | `0xba9d507b7e7f9d3a8b8b28946a4c2f0d4e9781b1` | owner = you; usdc/treasury set; feeBps 200 ✓ |

Note: the contracts are currently **not source-verified** on Basescan (I-01).

---

## 4. Severity definitions

- **Critical** — direct, likely loss/theft of funds or permanent freeze.
- **High** — loss/freeze under specific but realistic conditions.
- **Medium** — value impact requiring privileged access or unlikely conditions; or material fairness issues.
- **Low** — limited impact, defense-in-depth, or recoverable conditions.
- **Informational** — best practice, clarity, ops.

---

## 5. Findings

### M-01 — GoalVault withdrawal fee changes apply retroactively to existing balances · Medium · Open (by design)
`MoolaHubGoalVault.setFeeBps()` lets the owner change the withdrawal fee (capped at `MAX_FEE_BPS = 500`, i.e. 5%) at any time. The fee is applied at `withdraw()` time, so a fee increase affects funds users **already deposited** under a lower fee. A compromised or careless owner could raise the fee to 5% and extract up to 5% of users' saved principal on withdrawal.
- **Impact:** owner-controlled value extraction from existing user savings, bounded by the 5% cap.
- **Note:** this does **not** affect the rotation escrow or the accumulation circle — their `feeBps` is immutable per circle (fixed at creation), so it cannot be changed retroactively.
- **Recommendation (choose one):** (a) snapshot the fee per deposit and charge that rate at withdrawal; (b) put `setFeeBps` behind a timelock so users can exit before a change; (c) lower `MAX_FEE_BPS` (e.g. to 200); and (d) make the owner a multisig. At minimum, route ownership through a timelock before mainnet.

### L-01 — `cancelStalled()` performed an external call before state updates · Low · Fixed in source (redeploy needed)
In the reviewed deployed implementation, `cancelStalled()` called `_flagDelinquents()` (which calls `reputation.recordStrike`) **before** writing `status = Cancelled` and accruing refunds. Slither flagged this as `reentrancy-no-eth` / cross-function reentrancy on `status`.
- **Exploitability:** none in practice — `reputation` is the project's own `MoolaHubReputation`, which makes no external calls back into the escrow, so re-entry is impossible. No funds are at risk.
- **Remediation:** reordered to strict checks-effects-interactions (state written first, external call last) and added `nonReentrant` to `cancelStalled()` and `flagDelinquents()`. Verified by tests + clean Slither re-run.
- **Action:** the **deployed** escrow implementation (`0xfd6EeE6a…c49A`) predates this fix. Because escrow logic is immutable and the factory's `implementation` is immutable, apply the fix by deploying a new implementation + new factory and using those for new circles. Existing testnet circles are unaffected functionally (the issue is non-exploitable).

### L-02 — `MoolaHubSusuEscrow.pause()` is irreversible (no `unpause`) · Low · Open
The guardian can `pause()` (blocking contributions) but there is no `unpause()`. A paused circle can only be wound down via `cancelStalled()` (guardian) → refunds. An accidental pause cannot be undone; the circle must be cancelled and re-created.
- **Recommendation:** add a guardian `unpause()` (pausing must never enable fund movement, only block contributions), or document that pause is terminal-by-design.

### L-03 — Guardian can cancel/halt a healthy circle · Low · Open (acceptable, trusted role)
The guardian may `cancelStalled()` (rotation) / `cancel()` (accumulation) at any time, forcing a circle to wind down. This is a liveness/centralization power. Funds are always returned to their rightful contributors — the guardian can **never** redirect funds to itself — so there is no theft vector; the concern is purely that a trusted role can interrupt a circle.
- **Recommendation:** hold the guardian key in a multisig for mainnet; consider time-bounding guardian cancel to genuinely stalled circles only.

### L-04 — Real USDC blacklist can DoS a single rotation round (recoverable) · Low · Informational for mainnet
Canonical USDC can blacklist addresses; a `transfer` to a blacklisted recipient reverts. In rotation, if a round's scheduled recipient is blacklisted, `_settleRound` reverts, so the round can't settle. The round then never "fills," becomes stalled after its deadline, and `cancelStalled()` refunds contributors — so **funds are recoverable**, but that recipient's round can't pay out.
- **Relevance:** only with real USDC (the testnet deployment uses a MockUSDC with no blacklist). 
- **Recommendation:** document the behavior; consider a pull-payment fallback (credit the recipient a claimable balance instead of pushing) if mainnet USDC blacklisting is a concern.

### L-05 — Circle creation depends on `reputation.setFactory` being set · Low · Resolved on-chain
`CircleFactory.createCircle` calls `reputation.setReporter(escrow, true)`, which requires `reputation.factory == factory`. If unset, all circle creation reverts.
- **Status:** verified on-chain — `reputation.factory()` correctly returns the factory, so creation works. No action needed for the current deployment; noted for any future redeploy (the deploy script handles this when owner == deployer).

### Informational
- **I-01 — Deployed token is a MockUSDC and contracts are unverified.** The stack points at a custom mintable `MockUSDC` (`0xf03C3dA6…`), convenient for testing, **not** Circle's Base Sepolia USDC (`0x036CbD53…`). Also, none of the contracts are source-verified on Basescan, so users can't yet independently read the source. **Recommend:** verify all contracts on Basescan; redeploy against Circle USDC when testing real-USDC flows.
- **I-02 — Counter-based accounting; stray transfers.** The rotation escrow tracks contributions by counter and assumes `pot = contributionAmount × members`. USDC sent directly (not via `contribute`) is stranded with no sweep. The accumulation contract mitigates this with `sweepExcess()` (surplus-only, to treasury). Consider adding an equivalent sweep to the rotation escrow.
- **I-03 — Centralization.** Factory/Treasury/GoalVault/Reputation are owned by a single EOA (you). Acceptable on testnet; **move to a multisig + timelock before mainnet.**
- **I-04 — ERC-20 assumptions.** Contracts assume a standard, non-fee-on-transfer, non-rebasing token. True for USDC; do not point them at exotic tokens.
- **I-05 — Settlement gas.** In rotation, the member whose contribution fills a round pays the gas for that round's payout transfers. Cosmetic/UX.
- **I-06 — Slither `incorrect-equality` (`round == 0`).** Reviewed false positive: comparing `currentRound()`'s sentinel return to `0` is intended control flow, not a value/timestamp equality risk.

---

## 6. Correctness review — "does it work as intended?"

**Rotation (`MoolaHubSusuEscrow`)** — confirmed by tests and review:
- Each round requires all N members to contribute; on the N-th contribution the pot settles automatically to the positional recipient (`members[round-1]`), net of the 2% fee to the treasury; the round advances; after round N the circle completes. A recipient owed 1000 receives 980. ✓
- A member can contribute at most once per round; non-members are rejected. ✓
- Stalled rounds (past deadline + grace) are cancellable; contributors reclaim their unsettled contributions fee-free; defaulters are flagged to the reputation registry. ✓
- No code path lets anyone (including owner/guardian) choose or redirect a payout. ✓ Conservation invariant holds. ✓

**Accumulation (`MoolaHubSusuAccumulation`)** — confirmed by tests and review:
- Members save on a time-windowed schedule; each member's contributions accumulate to their **own** balance — no redistribution between members. ✓
- Withdrawals pay only the caller's own savings, charging 2% (waived if the circle was cancelled). With `lockUntilMaturity`, withdrawals are blocked until maturity (bounded, never indefinite) or cancellation. ✓
- Missed rounds are flaggable after their window closes; only the fund owner can withdraw; `sweepExcess` returns only accidental surplus; conservation holds. ✓

**Fee math** — `fee = amount × feeBps / 10_000`, floored; remainder goes to the user/recipient; treasury receives exactly the fee. No rounding leak. ✓
**Goal vault** — only the balance owner can withdraw; there is no admin path to user principal. ✓ (subject to M-01 on fee mutability)

---

## 7. Pre-mainnet checklist

1. Resolve **M-01** (fee snapshot or timelock; lower cap) and redeploy with **L-01** fixed.
2. Move all owner/guardian roles to a **multisig + timelock**.
3. Point the stack at **Circle's canonical USDC** and **verify all contracts** on the explorer.
4. Add `unpause` (L-02) and consider a rotation-escrow sweep (I-02) and pull-payment fallback (L-04).
5. Commission a **full third-party audit** and run the CI Slither/forge gate on every change.

---

## 8. Appendix

**Test suite (27/27 passing):** rotation (8) — full rotation w/ fee, double-contribute revert, non-member revert, stall→cancel→refund→strike, flag-without-cancel, pause-moves-no-funds, predict==deployed, fee-cap; goal vault (6) — deposit/withdraw fee, partial, owner-only, early-withdraw, admin-cannot-take-funds, conservation; factory (3) — init, duplicate revert, non-owner revert; accumulation (10) — accumulate own savings, double-contribute revert, lock-until-maturity + fee, cancel fee-free, own-funds-only, flag strikes, no-contribution-outside-schedule, pause, sweep-excess, conservation.

**Static analysis:** Slither v latest — post-remediation: 1 result (I-06 false positive).

*Reviewed against repository source; deployed implementation noted in §3/§5. This document should be re-issued after the M-01/L-01 remediations are deployed.*
