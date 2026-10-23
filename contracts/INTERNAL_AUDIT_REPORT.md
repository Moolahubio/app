# Moolahub Base circle contracts: internal pre-audit report

**Date:** 2026-10-22. **Status:** this is an internal pre-audit only. It does not replace the two external audits the spec's audit gate requires. **Code state:** working-tree snapshot. Nothing is committed and there is no audit tag yet.

## 1. Scope

- **Code:** `contracts/` of the build worktree. Branch `feat/base-mainnet-foundation`, base commit `d4bda46`, with 117 uncommitted paths under `contracts/`.
- **Digest:** sha256 over the sorted per-file sha256 list of `src/circles` is `70c06a53bd6b8015af57c4625bc7bc27c5e89c99c4ae07ac91d19610988d1582`.
- **Toolchain:**
  - forge 1.7.1 (`4072e487`), solc 0.8.28, 200 optimizer runs, EVM cancun, `auto_detect_remappings = false`;
  - OpenZeppelin `69c8def5` (v5.1.0) and forge-std `1eea5bae` (v1.9.4), both clean.

| File | Lines (physical / code) | Runtime bytes (EIP-170 margin) |
|---|---|---|
| MHAccumulationCircle.sol | 1,023 / 715 | 24,106 (**470**) |
| MHRotatingCircle.sol | 905 / 617 | 20,424 (4,152) |
| MHCircleRegistry.sol | 270 / 172 | 5,413 (19,163) |
| MHGuardianCanceller.sol | 235 / 121 | 4,746 (19,830) |
| MHCircleFactory.sol | 124 / 84 | 3,651 (20,925) |
| MHReputation.sol | 87 / 47 | 2,027 (22,549) |
| MHCircleBase.sol (abstract) | 125 / 71 | n/a |
| Constants, Types, Terms (libraries) | 218 / 98 | n/a |
| interfaces/ (8 files, including the vendored `IVaultV2` subset) | 1,346 / 398 | n/a |
| **src/circles total** | **4,333 / 2,323** | |

**Also in scope:**
- the unmodified OZ `TimelockController`;
- the ceremony tooling in `script/` (12 files, 4,113 lines);
- 18,859 lines of tests, plus a vendored Morpho `VaultV2` used as the real-code target.

**Out of scope:**
- the app and backend;
- `.github/` (recommendations only);
- the spec text;
- third-party code (USDC, Morpho, Safe, CreateX). The tooling pins these by codehash.

## 2. Methodology

**Build: five steps, C1 to C6.**
- Retire the legacy contracts.
- Build the registry, reputation, canceller and factory.
- Build both circles.
- Build the analysis suites: invariants, fuzz, Base fork, R8 boundary gas, cold gas bounds and EIP-7702.
- Build the ceremony tooling, VerifyBase, the fork rehearsal and CI pinning.

The two build-time verification steps (C5 and C6) found and fixed two issues before any audit:
- `cancelStalled` was within about 15k gas of the 5M bound;
- Slither reported two `shadowing-local` hits.

**Audit loop.** Each round ran eight auditors in parallel, each on its own copy of the code and each with one lens:
1. access and governance;
2. rotating math;
3. accumulation math;
4. integrations (Vault V2, USDC);
5. liveness and denial of service;
6. economic and adversarial behaviour;
7. spec conformance and test quality, including manual mutation;
8. deployment and operations.

A lead triage merged duplicates by root cause and kept the highest justified severity. Each later round saw every earlier finding and re-reported only fixes it found incomplete.

**Verification rule.**
- **Medium or higher:** two independent verifiers. One checked exploitability and had to produce a runnable PoC; the other checked intent and severity. A finding was confirmed if a PoC reproduced it or if both verifiers agreed.
- **Low:** one verifier.
- **Informational:** accepted without a verifier.
- **Final severity:** the highest severity assigned by any verifier who confirmed the finding.

An engineer then fixed each confirmed finding and turned its PoC into a regression test. Only low and informational findings could be acknowledged instead of fixed.

**Passes.**
1. **Audit 1, round 1:** 31 confirmed. R1-13 and R1-16 were not confirmed.
2. **Audit 1, round 2:** 22 confirmed (A-R2-01 to A-R2-22). The fix run was interrupted. Most of the code landed during audit 2 round 1, and the closeout finished the rest.
3. **Audit 2, round 1:** a second full pass on the fixed code. 29 confirmed, 0 rejected.
4. **Audit 2, round 2:** 18 findings (B-R2-01 to B-R2-18).
   - The 10 informational findings were accepted.
   - The verifiers for the 8 medium and low findings did not finish, and the harness logged those 8 as "rejected". That label means no verdict was reached, not that the findings were refuted.
5. **Closeout:** all 40 outstanding A and B findings were rechecked, and each was reproduced before any fix.
   - B-R2-01 to B-R2-07 all reproduced on the unfixed code.
   - B-R2-08 is reproduced inside its regression test.
6. **Closing review:** two reviewers checked every closeout fix.
   - Neither found anything at medium or higher.
   - They raised five findings, CR-1 to CR-5. Each was reproduced before it was fixed, and each regression test fails on the unfixed code.

## 3. Summary of findings

| Pass | Medium | Low | Info | Total | Fixed | Acknowledged |
|---|---|---|---|---|---|---|
| Audit 1 R1 | 3 | 9 | 19 | 31 | 20 | 11 |
| Audit 1 R2 (A-R2) | 1 | 6 | 15 | 22 | 19 | 3 |
| Audit 2 R1 | 1 | 12 | 16 | 29 | 24 | 5 |
| Audit 2 R2 (B-R2) | 1 | 7 | 10 | 18 | 13 | 5 |
| Closing review (CR) | 0 | 1 | 4 | 5 | 3 | 2 |
| **Total** | **6** | **35** | **64** | **105** | **79** | **26** |

- **No critical or high finding was reported in any pass.**
- All 6 mediums are fixed.
- 33 of the 35 lows are fixed; audit 2 R1-02 and B-R2-04 are acknowledged.
- 40 of the 64 informational findings are fixed.
- "Fixed" includes fixes that touched only tooling, tests or docs (A-R2-19 to A-R2-21, B-R2-10/11/14–17).
- The yield-switch fix was superseded twice: audit 2 R1-09, then B-R2-01, then CR-4.
- Every code or tooling fix names a regression test in `IMPLEMENTATION_NOTES.md`. Acknowledged on-chain behaviour is pinned by a test.

## 4. Notable findings and fixes

### Mediums (all fixed)

| ID | Finding | Fix and evidence |
|---|---|---|
| A1 R1-01 | In a rotating stall, just-in-time or flash collateral, or prepayments during the cure, moved other members' claims. | `_unwind` was rewritten. Security that backs no debt, and contributions to later rounds, are refunded at par outside the pool. E (each member's net position) is computed after these refunds. The defaulter's security stays as the penalty base. Covered by 6 tests and `testFuzz_R1_01_jitMovesNoOtherClaim`. |
| A1 R1-03 | In accumulation circles, a vault whose `previewRedeem` reverts froze every exit after maturity, and strikes landed while nobody could pay. | `guardianCancel` now also works while Matured; the finalize outcomes stand and `claimInKind` needs no NAV. `flagRound` reads the NAV. The permissionless `cancelExpired` came later. Covered by unit tests and a fork test with the real Gauntlet adapter reverting. |
| A1 R1-05 | Signers had no independent way to check the manifest and the Safe batches. | `MHManifestCheck` and `CheckManifest` run offline. They recheck the policy and re-derive the files byte for byte. Without using the planner, they also decode every transaction and recompute every CREATE3 address and Safe hash. Covered by tamper tests A to C. |
| A-R2-01 | Pending ("sleeper") Vault V2 submissions are invisible on chain, so a vault can pass `allowVault` with a weakening already queued. | A mandatory off-chain scan for pending submissions (`MHVaultPending`) runs in `BuildBaseBatch`, `VerifyBase` and `CheckVaultPending`. Regression test on the vendored real `VaultV2`. This control can only exist off-chain. |
| A2 R1-01 | A Vault V2 allocator can instantly block every redemption, which defeats the Guardian's 3-day exit window. Gauntlet's curator is itself an allocator. | New Guardian-only `forceExit`: `forceDeallocate` and redeem in one call, never through the liquidity adapter. Assets are capped at the position's value, and the adapter must belong to the vault. The penalty is at most 2% (0.001% on Gauntlet). Covered by 5 unit tests, 5 Gauntlet fork tests and an invariant oracle. |
| B-R2-01 | Anyone could permanently latch `yieldOff` on any brief `vaultSafe == false` reading, such as a routine adapter-set change or a precautionary delisting. | The registry is now the live gate, and only the Guardian latches yield off; `syncVault` and the join latch are removed. With CR-4, a failed live check delists the vault in the registry (`deployIdle`/`pullFromVault` call `revalidateVault`). Only Gov's reviewed `allowVault` can then resume deposits. Covered by 8 tests on the real VaultV2, the invariant actions `reallowVault` and `curatorTimelock`, and 2 boundary-gas tests. |

### Most important lows

- **Rotating payment order** (audit 2 R1-11, then B-R2-02/03, then CR-1).
  - The in-order rule from R1-11 caused two regressions. A non-nettable recipient could prepay round 2 and then default on round 1. A member drawn in full for round s could not pay round s+1.
  - Both are fixed by `_catchUp`, a zero-pull walk that `amountDue` mirrors.
  - The new fuzzer then found a third variant: a late settlement of the recipient's own round used up collateral that later rounds relied on. The recipient's own round is now netted in full from its payout.
  - CR-1: late collateral now records a LATE strike for every round it pays, whatever the keeper's timing. A 10,000-run differential fuzz checks this against the `contribute` path.
- **Recipient netting** (A1 R1-07, audit 2 R1-03/R1-19).
  - The recipient's own part is netted from its payout with no strike, and never counts in E.
  - Paying, withholding and flash-depositing all give the same result.
- **Accumulation economics** (A1 R1-09/10/11, B-R2-06/07):
  - forfeits go back to the exiters when nobody remains;
  - the fee applies even when nobody is compliant;
  - the delinquent cap is applied once, at finalize;
  - `finalize` runs as soon as everyone has exited;
  - a member who exits after the last deadline still owes the last round.
- **`cancelExpired`** (audit 2 R1-05/06/07) opens only when all three hold:
  - 90 days have passed since the last NAV read;
  - a fixed-gas (3M) `previewRedeem` probe still fails, and the caller cannot starve it of gas;
  - USDC is live.
- **Vault checks** (A1 R1-04, A-R2-07, audit 2 R1-10):
  - timelocks of at least 7 days for allocators, adapters and the adapter registry;
  - at least 3 days for caps, fees and `burnShares`;
  - up to 16 adapters, read with bounded calls that fail closed;
  - `vaultSafe` walks every adapter.

  The Guardian's response window is therefore 3 days.
- **Blacklists** (A1 R1-14/15, A-R2-11).
  - Vault shares owed to a blacklisted recipient are queued.
  - A blacklisted circle queues its payouts and treats every strike or stall gate like a pause.
- **Ceremony** (A1 R1-17, A-R2-03/04/16/17/18, audit 2 R1-04/13/25/26, B-R2-08, CR-3):
  - Safe owners and the operator must be EOAs; an EIP-7702 delegation counts as code;
  - each role has its own threshold policy;
  - runtime codehashes are derived, not copied;
  - the vault is pinned;
  - batch 1 is split into 1a and 1b;
  - the vault scan runs before any output is written;
  - signers pass the audited tag or SHA, plus an `--inputs-hash` taken from an independent ceremony record;
  - owners are sorted.

## 5. Rejected and acknowledged items

**Rejected.**
- Audit 1 R1-13 and R1-16 were not confirmed. Their text and the verifiers' reasons were not kept, so they cannot be rechecked from the record.
- The eight list-B findings logged as "rejected" all reproduced (see section 2).

**Acknowledged (26), grouped by the decision each one is waiting on:**
- **σ < 100% Trusted-tier economics (5):** A1 R1-26, R1-30, A-R2-15, audit 2 R1-02 (Low), CR-2.
  - A stall writes off the unsecured balances of members already paid out. For example, slot 1 gains $900 at n = 20.
  - A partly drawn debtor keeps its wallet part by skipping.
  - Mitigations: the `PositionWrittenOff` event, COVERED strikes, and off-chain caps on exposure and on launch size ($25k).
  - Still open for the founder: write-off, continuation or wind-down.
- **Relief after a pause or outage (4):** A1 R1-08, A-R2-10, A-R2-12, B-R2-04 (Low).
  - After a USDC pause or a sequencer outage that spans the end of a rotating grace period, the first block can record strikes. A long pause can also stall the circle.
  - Mitigations: the Guardian's `extendDeadline` (it works while USDC is paused) and pre-signed L1 `OptimismPortal` deposits. Accumulation circles have a cure gate.
- **Spec semantics awaiting sign-off (4):** A1 R1-27/28/29 and audit 2 R1-21. They cover the cover rules, the units of the D4 penalty, extensions and the exit-forfeit cliff.
- **Accumulation liveness (4):**
  - A1 R1-18: the Active cancel between maturity and finalize is uncapped.
  - A1 R1-22: superseded by `forceExit`.
  - B-R2-12: a single failed probe after 90 dormant days is enough to open `cancelExpired`. An "arm, then fire" redesign is deferred.
  - CR-5: `exitEarly` waits for vault liquidity. An in-kind exit would need most of the 470 bytes of size margin left.
- **Governance and operations (7):**
  - A1 R1-19: a rotation with a predecessor.
  - A1 R1-21 and audit 2 R1-22: the extension budget.
  - Audit 2 R1-18: an operation of more than about 128 KB cannot be cancelled.
  - B-R2-09: replacing the Guardian takes longer than the 3-day window.
  - B-R2-13: `forceExit` can be front-run.
  - B-R2-18: circle creation opens right after batch 2. The runbook withholds the operator key until verification passes.
- **Product (1):** audit 2 R1-20. A stall in round 1 costs the staller only a strike.
- **Outside scope (1):** A1 R1-25, CI hardening.

## 6. Static analysis

Slither 0.11.6 on `src/circles` (this run, `--config-file slither.config.json --fail-high`) exited 0. It reported **0 High, 30 Medium, 33 Low and 4 Informational (67 in total)**, the same as the closing-review figures.

| Impact | Detector (count) | Triage |
|---|---|---|
| Medium | `uninitialized-local` (17) | False positive: these are zero-initialised accumulators, bitmaps and bools. |
| Medium | `incorrect-equality` (11) | False positive: zero sentinels on tracked counters or config, never on a balance anyone can manipulate. |
| Medium | `reentrancy-no-eth` (1) | Accepted. `forceExit` writes state from the vault calls' results; it is `nonReentrant` and the vault is allowlisted. |
| Medium | `unused-return` (1) | By design. `_strike` ignores the bool from `record`, which is false only for a duplicate. |
| Low | `calls-loop` (16) | Accepted. The loops call the immutable Reputation contract (at most 50 iterations, worst case measured cold) and the registry's adapter walk (at most 16, fail-closed, with a gas floor). |
| Low | `reentrancy-benign` (10) | Accepted. Each write follows a call to the allowlisted vault or the immutable registry, or follows the factory's spec order. Every entry point has the transient `nonReentrant` guard. |
| Low | `missing-zero-check` (7) | Roles are checked in `_checkRoles`. `WRAPPER` may legitimately be zero. |
| Info | `assembly` (2), `cyclomatic-complexity` (1), `unimplemented-functions` (1) | Bounded static calls into scratch space. `finalize` (complexity 13) is fully tested. Slither misreads the mapping getters. |

**Correction to the record.**
- The notes say a run with every detector enabled gave identical results. In fact Slither loads `slither.config.json` from the working directory automatically, so the exclusions still applied.
- With nothing excluded there are 122 results: the same 67, plus 34 `timestamp` (Low) and 21 `naming-convention` (Info).
- Timestamp triage: the gates work on a scale of days, with at least 48h of grace.
- Naming triage: the hits are UPPER_CASE immutables.

**Not run:** Aderyn, Halmos and tool-based mutation testing.

## 7. Tests, invariants and coverage

**Runs for this report:**
- **`forge build --force --sizes`:** exit 0, no negative size margin.
- **`forge test`:** **477 passed, 0 failed, 4 skipped**, across 41 suites.
  - The 4 skipped are the fork suites, which skip unless `BASE_RPC_URL` is set.
  - The run includes 18 fuzz tests at 256 runs and both invariant suites at 32 runs × depth 100.
- **Fork suites at block 52,933,005:** **62/62 pass** (SafeDeployRehearsal 43, MHCirclesFork 8, MHAuditRound1Fork 5, MHAudit2Fork 6). The run took 9 s, so the state probably came from Foundry's RPC cache.

**From the notes:**
- **CI profile:** 475 non-invariant tests pass.
- **Fuzzers at 10,000 runs:** the CR-1 differential fuzz and the overlapping-round fuzzer.
- **Closing reviewers' extra fuzzing:** 20,000 adversarial runs and 10,000 claim-invariance runs.
- **Invariants at 2,000 runs × depth 150 (300,000 calls each):**
  - accumulation passes with 0 reverts (656 s);
  - rotating passes with 1,085 handler-level reverts (486 s);
  - **the CI profile (10,000 × 200) last ran at build step 4, before any audit fix.**
- **Invariant oracles:**
  - exact identities for the USDC and vault-share balances;
  - a ghost ledger per member;
  - no admin or attacker ever receives value;
  - the treasury receives only fees, residual and donations;
  - the bounds from the spec's D1–D4 default scenarios;
  - independent predictions of who defaults and of finalize outcomes;
  - gas under 5M;
  - every circle can be driven to an end state using only permissionless calls.
- **R8 boundary gas:** every state-changing function either completes fully or leaves no partial state, at every gas limit.
- **Cold worst cases at n = 50 (all under 5M):**
  - `cancelStalled` 3.80M;
  - `settleRound` 3.34M;
  - `contribute` catch-up 2.65M;
  - `depositCollateral` 1.74M;
  - `flagRound` 2.90M.
- **Fork coverage:**
  - the Appendix A pins;
  - Gauntlet passes `allowVault` and Steakhouse fails;
  - an allocator draining liquidity, answered by `forceExit`;
  - illiquidity with in-kind settlement;
  - curator fee changes;
  - real USDC pause and blacklist;
  - the full Safe ceremony, with batches 1a, 1b and 2 at 4.79M, 5.65M and 6.00M gas;
  - the VerifyBase tamper cases.
- **Manual mutation:**
  - build: 14/14, 46/48 (the 2 survivors are equivalent mutants) and 69/69;
  - conformance passes: 92/98 and 127/136, with every survivor killed later;
  - later rounds: 31/31, 32/32 and 12/12.
- **Shell regressions:** 12/12 and 4/4.

**Logs:**
- `/private/tmp/claude-501/-Users-jerry-Projects-moolahub-app/35945dd9-15c6-4b7a-930c-ae66df300798/scratchpad/audit/report-sizes-force.log`
- `/private/tmp/claude-501/-Users-jerry-Projects-moolahub-app/35945dd9-15c6-4b7a-930c-ae66df300798/scratchpad/audit/report-test.log`
- `/private/tmp/claude-501/-Users-jerry-Projects-moolahub-app/35945dd9-15c6-4b7a-930c-ae66df300798/scratchpad/audit/report-fork.log`
- `/private/tmp/claude-501/-Users-jerry-Projects-moolahub-app/35945dd9-15c6-4b7a-930c-ae66df300798/scratchpad/audit/report-slither.json`
- `/private/tmp/claude-501/-Users-jerry-Projects-moolahub-app/35945dd9-15c6-4b7a-930c-ae66df300798/scratchpad/audit/report-slither-all2.json`

## 8. Creation-code hashes

- Computed with `forge inspect <C> bytecode | cast keccak`, without constructor arguments.
- The values are identical after a `--force` rebuild and in the build worktree's own artifacts.
- Any change to the source, including comments, changes them. They must be reissued against the audit tag.

| Contract | Initcode (bytes) | keccak256(creation code) |
|---|---|---|
| MHRotatingCircle | 21,027 | `0x13cb7fdb25e1c5a2fb55d842485c6cb414026d637af1e874fb05ecd5f31a0815` |
| MHAccumulationCircle | 24,765 | `0x064f7309843066323c59c61f3d6485023fee4727b11230001cfce00f4ac82277` |
| MHCircleRegistry | 6,251 | `0x135c09f642f2044f579fbf8f4267d08d30f4b197c2062cd348824649a660ba7d` |
| MHReputation | 2,400 | `0x3450b2a6914ed130c7db68cdd482757bb35818a8f3350ab496b937f326f0d10a` |
| MHCircleFactory | 4,940 | `0x5df89b42822992bbe20b12eb8a0892d4db9ca571d88baddd80391a3beaa03763` |
| MHGuardianCanceller | 5,198 | `0xcf29f883117b3dc35789dc1115a32ada40359bc816658e2c5b511352bbaa201f` |
| TimelockController (OZ 5.1.0) | 7,468 | `0x5383ac5460a8a9beff1b7f65bf1645a8162ef47ae157ce37917f9dd8ee46f7f6` |

## 9. Residual risks and trust assumptions

**Morpho Vault V2:**
- **Allocators act instantly** and are trusted for liquidity. `forceExit` caps the cost of leaving at 2%, but it can be front-run, and `exitEarly` waits for liquidity.
- **Curator changes are timelocked:** 7 days for allocators and adapters, 3 days for caps, fees and `burnShares`. The Guardian therefore has a 3-day window, and replacing a Guardian takes at least 48h.
- **Sleeper submissions** are caught only by the mandatory `CheckVaultPending` scan.
- **An atomic curator transaction defeats any live check.** The curator executes a matured `decreaseTimelock`, submits a change and restores the timelock, all in one transaction. Only the Guardian's monitor on Submit events catches this.
- **Any adapter-set change lets anyone delist the vault.** That pauses deposits in every circle on that vault until Gov re-allows it. The cost is yield only.
- **Members bear** bad debt, the curator's fees and drift in `previewRedeem`. Principal is not guaranteed.
- **`NAV_PROBE_GAS` is 3M.** A vault whose valuation costs more gas than that would be treated as broken.

**USDC (Circle):**
- Circle can pause USDC, blacklist addresses (members, the treasury or a circle), and upgrade the token's implementation. Only the proxy codehash is pinned.
- Payouts are queued while USDC is paused or while the recipient or the circle is blacklisted.
- Timer gates revert while USDC is paused or the circle is blacklisted.
- Relief from rotating strikes after a pause depends on the Guardian (B-R2-04).

**Base sequencer:**
- The sequencer sets block timestamps.
- An outage longer than the forced-inclusion window lets the first block after it race the Guardian. The mitigations are pre-signed L1 deposits and the accumulation cure gate.

**Keys:**
- **Gov Safe:** acts through the Timelock (48h to 7 days). Its threshold must be a majority and at least 3 signers, or 2-of-3.
- **Guardian Safe:** its keys are separate from Gov's. It can cancel any queued Timelock operation except a batch that only rotates the Guardian.
- **Gov cannot reach principal:** there is no upgrade path, no vault setter and no rescue function. However:
  - `treasury()` is read at the moment of payment, so after the Timelock delay a compromised Gov can redirect future fees, residual and donations of live circles, unless the Guardian cancels the change;
  - Gov can allowlist a hostile vault for new circles.
- **A compromised Guardian cannot take principal.** It can:
  - cost up to 2% via `forceExit`;
  - switch yield off;
  - cancel circles (members get refunds with no fee);
  - use up the extension budget;
  - delist vaults and pause circle creation.
- **Partial Guardian rotation:** if only part of a rotation lands, nobody can cancel Timelock operations until it is completed (it fails closed).
- **Ceremony:** signers must run `check-manifest-bytecode.sh --signer <tag/SHA> --inputs-hash <record>` and compare the hashes shown on their devices. How Safe{Wallet} wraps the batches is still marked [VERIFY].

**Keeper and backend:**
- Every function needed for liveness is permissionless, so a keeper outage affects timing, not safety.
- The backend must:
  - call `revalidateVault` before pulling from the vault;
  - check for the `IdleDeployed` event instead of relying on the transaction succeeding;
  - finalize and settle promptly;
  - index `PositionWrittenOff`, COVERED strikes and `CancelReason.Expired`.
- The exposure and launch caps are enforced off-chain only.

## 10. Focus list for the external auditors

1. **Rotating multi-round paths, the most-reworked code:** `_catchUp`/`_catchUpFrom`, the `amountDue` simulation, `_latePaid`, `_nettable`/`_collect` and the `withdrawSecurity` locks. Check that they stay consistent with each other under any keeper timing.
2. **Rotating unwind:** `_unwind`, `_refund`/`_refundAt`, `_positions`, `_weights`, fees folded back only up to the creditors' shortfall, and the amended D2 to D4 numbers.
3. **Accumulation against the real Vault V2, including its transient-storage accrual:**
   - `forceExit` sequencing and its penalty bound;
   - `_takeCash`;
   - `_navReadable` gas under the 63/64 rule;
   - `cancelExpired` and the Matured cancel;
   - `finalize` when everyone has exited, and `_returnForfeits`;
   - virtual-share rounding and `owedShares`.
4. **CR-4, the delisting that sticks until Gov re-allows the vault:** circles writing registry state, rollback when the call reverts, griefing through delisting, and whether a third party can make a healthy vault fail `_vaultCheck`.
5. **`_vaultCheck` completeness** against the full Vault V2 selector set. `sendAssetsGate` and `setSkimRecipient` are deliberately unchecked. Also the adapter bounds and `adapterSetHash`.
6. **`MHGuardianCanceller`:** how rotation-only batches are classified, the clean-word checks, whether operation ids equal OZ 5.1.0's, and partial rotations.
7. **No admin path to principal** for any role, including the treasury address read at payment time.
8. **Gas at n = 50** and 63/64 gas griefing in loops that call Reputation and the registry.
9. **Tooling:** whether `MHManifestCheck` is really independent of the planner, the CREATE3 and Safe-hash recomputation, the signer's git checks, and the VerifyBase role replay.
10. **Gaps to close on the audit tag:**
    - the CI-profile invariants (10,000 × 200);
    - tool-based mutation testing;
    - Aderyn and Halmos;
    - the diff against the TypeScript port;
    - a size plan before any change to `MHAccumulationCircle`.

## 11. Record discrepancies

- **Audit 1 R1:** the notes say 30 confirmed findings, but their table lists 31.
- **Closeout tally:** the summary line says 15 already-fixed, 13 fixed and 12 acknowledged. The per-row labels give 16, 16 and 8. This report uses the per-row labels.
- **Slither:** the notes claim an "every detector" run gave identical results. That run still used the config's exclusions (see section 6).
- **Commit and spec:** nothing is committed. About 30 spec amendments are still waiting for founder sign-off, and the external auditors should treat them as the specification.