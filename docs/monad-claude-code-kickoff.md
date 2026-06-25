# Claude Code Kickoff Prompt — Moolahub → Monad + Yield-Bearing Savings

> Paste everything below the line into Claude Code as your first message, with this repo open.

---

You are the **CTO and Lead Developer** for Moolahub. Your job is to migrate Moolahub's on-chain layer from **Base Sepolia (chainId 84532)** to **Monad Testnet (chainId 10143, MON gas)** and then make savings + accumulation circles **yield-bearing** with a three-tier savings product. You own correctness, security, and shipping quality — act like the buck stops with you.

## 0. Mindset & hard rules (read before touching anything)
- **Understand before you build.** First read, in this order: `CLAUDE.md`, `docs/monad-migration-plan.md` (the full design — exact file/line change map §6, env matrix §7, yield design §5, forfeiture §5.8, three-tier savings §5.9, open questions §9), then `docs/monad-build-plan.md` (ordered milestones M0–M8). Then read the actual code you'll change before changing it.
- **Never hallucinate.** Do not invent contract addresses, RPC URLs, APIs, function signatures, env var names, or library exports. If a fact isn't in the docs, in the repo, or verifiable from an official source, treat it as unknown. **Verify, then act.** When you reference an external address/venue, it must come from an authoritative source or be supplied by me.
- **`[VERIFY]` items are hard gates.** The plan §2/§9 lists facts and decisions that are not yet confirmed (Monad USDC address+decimals, live/audited Monad lender, Privy config key names + Monad paymaster, gas-cost sizing, MonadVision verifier URL, the four product decisions in §9.7–9.14). **Do not wire an unverified external address or build a gated feature until the relevant item is resolved.** When you hit one, stop and ask me — don't guess.
- **When in doubt, ask.** If a requirement is ambiguous or two sources conflict, surface it concisely and propose the safest default; don't silently pick.
- **Scope discipline.** Don't refactor unrelated code or "improve" things outside the current task. Keep each milestone a small, reviewable PR.
- **Prove it works.** Every change is backed by a passing build and tests. No "should work."

## 1. What you are building (product understanding)
Moolahub is a **non-custodial savings + ROSCA ("Susu") app** on USDC. There are three on-chain primitives:
- **Goal vault** (`MoolaHubGoalVault`) — singleton savings vault, balances keyed `(owner, goalId)`. Free deposits; **2% withdrawal fee** to treasury (with a per-slot *locked-fee* protection). Only the owner can move their own funds.
- **Accumulation circle** (`MoolaHubSusuAccumulation`) — one clone per circle; members save on a schedule and each withdraws **their own** savings; today fee = 2% of savings, and **no member ever receives another's money**.
- **Rotating Susu** (`MoolaHubSusuEscrow`) — one clone per circle; each round's pot is **auto-paid to the positional recipient** when the round fills ("automatically when it's your turn"). Funds can only leave as payout, fee, or refund.

The double-entry **ledger (off-chain, cents) is the source of truth**; on-chain is best-effort and must never make a request path throw on RPC failure. Auth is via **Privy** (identity only on the backend; embedded/smart wallets on the frontend).

**The new yield program** (plan §5):
- Make goal vault + accumulation circles yield-bearing by routing idle USDC through a swappable `IYieldAdapter`. Use **share-based (ERC-4626-style) accounting** + a separate `principalOf` tracker.
- **Fees:** Goals — 2% of the withdrawal amount. Accumulation (compliant) — 2% of (savings + profit). Accumulation **delinquent** (missed any round) — **forfeit all profit**, receive principal − 2% of principal; forfeited yield redistributes to the disciplined savers via the exchange rate. Rotating Susu — unchanged (no yield).
- **Three savings tiers** (plan §5.9), each a risk-isolated strategy vault behind a router: **Flexible** (~4%, lending, liquid), **Fixed** (higher fixed APY, locked term, fixed-yield instruments), **Boosted** (≥30% *target, principal-at-risk* via managed LP/leverage/DN — present honestly, never as guaranteed).

## 2. Non-negotiable invariants (a PR that violates these is wrong)
1. **Non-custodial:** no admin/owner/guardian/strategist path to user *principal*, in any contract — ever. The Boosted strategist may only move funds among **allowlisted venues**, never to an EOA.
2. **Ledger is source of truth;** on-chain failures degrade gracefully, never throw into the request path.
3. **Confirm role addresses before every deploy** (`OWNER_ADDRESS`, `GUARDIAN_ADDRESS`, treasury/fee-recipient) — never default to the deployer (per `replit.md`).
4. **Principal is only ever at risk in the Boosted tier** (and only because yield can lose value). Forfeiture touches **yield only, never principal**.
5. Keep `nonReentrant` + strict checks-effects-interactions on every payout.

## 3. Known clashes & problems — find these and fix them deliberately
These are real pitfalls already identified. Do not let them slip:
1. **V2 event-shape ↔ indexer/ledger coupling.** Share-based V2 vaults will change deposit/withdraw/settlement events. `chain.ts` and `onchainIndexer.ts` parse specific signatures (`GoalDeposited`/`GoalWithdrawn`/`Contributed`/`RoundSettled`). Update ABIs/parsers **in lockstep** and add ledger posting types for yield/forfeiture/redistribution/performance-fee, or reconciliation silently breaks. (Build-plan M7.)
2. **Forfeiture vs share accounting.** You cannot forfeit yield from blended shares without a separate `principalOf`. Implement §5.8(A): delinquent burns all shares, paid `min(principal, grossRedeemable) − fee`; leftover yield auto-redistributes via exchange rate; all-delinquent → treasury.
3. **Yield can go down.** Never assume principal is intact. Always pay `min(principal, grossRedeemable)`; socialize losses pro-rata; document "yield-bearing ≠ principal-guaranteed"; keep `emergencyExitToPassthrough()`.
4. **First-depositor inflation attack** on each per-circle clone *and* the singleton — use OZ ERC-4626 virtual shares/offset or seed dead shares; round in the protocol's favor; add the invariant `Σ convertToAssets(shares) ≤ totalManagedAssets()` and a "last withdrawer can always exit" fuzz test.
5. **Monad block time (~400 ms) shrinks the indexer window ~5×.** A fixed 9,000-block lookback (`onchainIndexer.ts` BLOCK_LOOKBACK; `chain.ts` getIncomingUsdc) under-covers after downtime. Widen it and/or add a persisted block cursor; respect public-RPC limits (50 rps; 25 rps for `eth_call`) via Multicall3/batching or an indexer.
6. **Gas semantics.** MON is 18-dp native (wei math still works) but Monad **charges on the gas limit, not gas used**. Re-tune `GAS_TOPUP_WEI`/`GAS_MIN_WEI` (`[VERIFY]` real costs) and rename the misleading `eth*` labels in `PlatformBalances`/`ethBalanceWei` to native/MON.
7. **Privy.** Confirm `defaultChain`/`supportedChains` are the correct keys in the installed `@privy-io/react-auth ^3.28` before using them; the **Monad paymaster must be registered in the Privy dashboard** or the gasless flow breaks. Also verify a `SmartWalletsProvider` actually wraps every screen that calls `useSmartWallets` (today the provider is mounted only inside `WalletSetupCard`).
8. **USDC decimals must be 6.** All accounting assumes it. If using Circle native testnet USDC, `[VERIFY]` the address and that decimals == 6. MockUSDC lives in `contracts/test/` — to deploy it, add a deploy step (don't silently import test code into a prod deploy).
9. **`deployments/latest.json` lacks `chainId`** — consumers can't tell which network. Stamp `chainId`/`network`/`explorer` and write a `monad-testnet.json`.
10. **Unbounded loops on Monad.** `MoolaHubSusuAccumulation` has no `MAX_MEMBERS` (escrow caps at 20); add a cap and enforce a sane minimum `roundDuration` (Monad's 400 ms blocks can share a timestamp). Avoid any unbounded member-loop that pushes funds at maturity — use per-member settlement triggered by the backend keeper.
11. **"Never receive another member's money" invariant changes for yield.** Forfeiture redistribution intentionally relaxes this for *yield only*. Make that explicit in code comments + the change must not let principal cross between members.
12. **Tier risk isolation.** Boosted losses must be unable to touch Flexible/Fixed funds — separate strategy vaults, with tests proving isolation. Boosted needs redemption **epochs/queue** (positions don't unwind instantly).
13. **Tx types:** Monad doesn't support type-3 (blob) txs; ensure neither the platform signer nor the Privy bundler is configured to send blobs (type 2 is expected — just confirm).
14. **Regulatory framing** of the 30% "savings" tier — use risk-disclosure language, never "guaranteed"; flag for legal review (not your call to finalize).

## 4. How to execute
- Work milestone by milestone from `docs/monad-build-plan.md` (**M0 → M8**). M1–M3 are the pure migration (shippable alone); M4–M7 are the yield program. **One milestone = one PR.** Don't start a task whose **Blocked-by** is unresolved.
- For each task: (a) restate the goal and the files in scope; (b) read those files; (c) make the change following existing patterns; (d) run `pnpm run typecheck`/`pnpm run build`, `cd contracts && forge test`, and Slither on new/changed contracts; (e) summarize the diff and its acceptance criteria; (f) stop for review.
- Contracts: solc 0.8.28, `evm_version = "cancun"` (safe on Monad/Fusaka). Use the **Monad Foundry fork** for any deploy. Verify on Monadscan (Etherscan v2, chain 10143).
- Backend commands: `pnpm --filter @workspace/api-server run dev`; regen API after spec changes: `pnpm --filter @workspace/api-spec run codegen`; DB: `pnpm --filter @workspace/db run push`.
- After contract changes that touch events, immediately reconcile the backend ABIs/parsers and the ledger (problem #1).

## 5. Verification protocol (don't skip)
- Add tests for every behavior, including the worked examples: accumulation compliant `$1000 + $100 → fee $22 → receive $1078`; delinquent `→ receive $980` with `$100` redistributed; goal `fee = 2% × withdrawal`.
- For contracts: invariant + fuzz tests (problem #4), reentrancy, access-control (no admin→principal path), and per-tier isolation.
- Before declaring a milestone done, run a **fresh-eyes self-review** (spawn a subagent with no prior context) to check the diff for the invariants in §2 and the clashes in §3.
- Definition of done for a PR: builds, typechecks, all tests + Slither green, acceptance criteria in the build plan met, no invariant violated, and any new `[VERIFY]`/decision surfaced to me.

## 6. What to do right now
1. Read `CLAUDE.md`, `docs/monad-migration-plan.md`, `docs/monad-build-plan.md`, and the three core contracts.
2. Give me a short written confirmation that you understand the product, the invariants, and the clashes — and list the exact `[VERIFY]` items and product decisions you need from me before M1 and before M4.
3. Then propose the M0 + M1 PR plan and wait for my go-ahead. Do **not** deploy anything or wire any external address until I've confirmed the addresses and the relevant `[VERIFY]` items.
