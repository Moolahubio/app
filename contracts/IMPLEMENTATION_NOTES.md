# Circle contracts: implementation notes

Authoritative design: `docs/base-build-spec-v2.md` (build spec v3) §0, §4, §5, Appendix A. Architect briefs (circle spec, multisig plan) were used as secondary input; where they differ, the spec wins. Each build step appends a section below.

---

## Step 1: C1 retire legacy, C2 registry/reputation/canceller, C4 factory (2026-10-22)

### What was done
- **C1 (retire).** Deleted all of `src/` (9 contracts, `adapters/*`, `interfaces/*`), all legacy tests (`test/*.t.sol`, `test/adapters/*`, `test/mocks/MockERC4626.sol`, the old `MockUSDC.sol`), `script/Deploy.s.sol` and `script/DeployAccumulation.s.sol`. Added a "Retired" banner to `README.md` and `DEPLOYMENT.md`. `deployments/*.json` (legacy Base Sepolia/Monad records) were left untouched.
- **C2/C4 (new, `src/circles/`).**

| File | Role |
|---|---|
| `MHCircleConstants.sol` | §4.1 constants table (library, `internal constant`) |
| `MHCircleTypes.sol` | `CircleMode`, `CircleStatus`, `RotatingConfig/Params`, `AccumulationConfig/Params` |
| `MHCircleTerms.sol` | terms-hash formula (pure library, explicit chain id and circle address) |
| `MHCircleBase.sol` | abstract base for both circles: `USDC`/`REGISTRY`/`REPUTATION` immutables, `_disableInitializers()`, `owed`/`owedTotal`, `_pay`, `claimOwed`, `_requireUsdcLive`, `_strike`, terms-hash helpers, `ReentrancyGuardTransient` |
| `MHCircleRegistry.sol` | Ownable2Step (Timelock); operator, guardian, treasury, `creationPaused`, `isAllowedVault` |
| `MHReputation.sol` | Ownable2Step (Timelock); `constructor(owner, factory)`; `setReporter` (factory only); idempotent `record` |
| `MHGuardianCanceller.sol` | holds `CANCELLER_ROLE`; `cancel` / `cancelBatch`; rotation-only operations refused |
| `MHCircleFactory.sol` | ownerless; `createRotating` / `createAccumulation` / `predictAddress` |
| `interfaces/IMHCircle.sol` | shared circle surface, §4.5 error list, `PayoutQueued`/`OwedClaimed` |
| `interfaces/IMHRotatingCircle.sol`, `IMHAccumulationCircle.sol` | the `initialize(params)` contract the next steps implement |
| `interfaces/IMHCircleRegistry.sol`, `IMHReputation.sol`, `IMHCircleFactory.sol` | public surfaces, errors and events |
| `interfaces/IUSDC.sol` | `IERC20` + `isBlacklisted`, `paused` |
| `interfaces/IVaultV2.sol` | vendored Morpho Vault V2 subset (see below) |

- **Tests (`test/circles/`, `test/mocks/`).** `CircleFixture.sol` deploys the stack in the spec §5 order: implementations, then Timelock with Gov as temporary admin, canceller, `grantRole(CANCELLER_ROLE)`, Registry, Reputation with the predicted factory, Factory, `renounceRole(DEFAULT_ADMIN_ROLE, Gov)`. Addresses that are needed early are predicted from CREATE nonces, standing in for CreateX `deployCreate3`. The mocks are test-only and none is in `src`:
  - `MockUSDC`: FiatToken-style blacklist and pause.
  - `MockVaultV2`: the Vault V2 governance surface only.
  - `MockRotatingCircle` / `MockAccumulationCircle`: inherit the real `MHCircleBase` and record `initialize` inputs and ordering probes.
- **`foundry.toml`.**
  - Monad endpoints dropped. Added `rpc_endpoints.base` (`${BASE_RPC_URL}`) and `rpc_endpoints.base_sepolia` (`${BASE_SEPOLIA_RPC_URL}`).
  - Added Etherscan v2 entries for chains 8453 and 84532, both on one `${ETHERSCAN_API_KEY}`.
  - Added `[profile.ci.fuzz] runs = 1000` and `[profile.ci.invariant] runs = 10000, depth = 200`. The default profile is unchanged (256 runs).

### TypeScript coupling check (task a)
Grepped the whole worktree for imports of `contracts/src`, `contracts/out`, `*.sol` or forge artifacts from TS/JS/JSON/YAML/shell: **none found**. Every consumer uses inline viem `parseAbi` fragments, which still compile:
- `artifacts/api-server/src/lib/chain.ts:51-95` (ERC20, MockUSDC, factory, escrow and goal-vault ABIs);
- `artifacts/api-server/src/lib/circleChain.ts` and `artifacts/api-server/src/lib/onchainIndexer.ts:51+` (event signatures);
- `artifacts/moolahub-app/src/lib/onchain/abis.ts` (`contribute()`, `claimRefund()`, `withdraw()`, goal-vault `deposit`/`withdraw`).

These ABIs describe the **retired** contracts and are now functionally stale. They are for A4/A11 to replace. A comment in `artifacts/api-server/src/lib/circles.ts:36` still says "Must match MAX_MEMBERS in MoolaHubSusuEscrow.sol"; the new bound is `MHCircleConstants.MAX_MEMBERS = 50`. `threat_model.md:37` still lists `contracts/deployments/*.json`.

### Deviations and resolved ambiguities
1. **Terms hash shape.**
   - The spec formula is `keccak256(abi.encode(block.chainid, address(this), params, members, securityBps))`. `params` is read as the *scalar* config struct (`RotatingConfig` / `AccumulationConfig`, all value types), with `members` and `securityBps` encoded separately.
   - Accumulation circles have no sigma, so they hash an empty `uint16[]` in that position, which keeps one formula.
   - The accumulation `vault` and `lockUntilMaturity` sit inside the config struct, so they are bound.
   - `MHCircleTerms` takes the chain id and the circle explicitly, so tests and off-chain code can reproduce it.
2. **`allowVault` is stricter than the literal spec, in two places.**
   - Spec: "the receiveAssets, receiveShares and sendShares gates are abdicated". The code also requires each gate to be `address(0)`, as the circle brief asks. A non-zero abdicated gate would be a permanent third-party veto over exits.
   - Spec: "setIsAllocator and addAdapter timelocks ≥ 7 days". The code also accepts an **abdicated** selector, which is strictly stronger because the function can never run again (`VaultV2.timelocked()` checks `abdicated`).
   - `sendAssetsGate` is not checked, per spec: it can block deposits but not exits.
   - Failures revert with `VaultCheckFailed(bytes4 selector)`, naming the Vault V2 selector whose check failed.
   - Limits on what the checks can see:
     - A **pending** submission cannot be seen on-chain, because `executableAt` is keyed by full calldata.
     - Submissions made before a timelock increase keep their old `executableAt`.

     Human review during the 48h Timelock window remains part of the check, as the spec says.
3. **Registry roles.**
   - `operator`, `guardian` and `treasury` must be non-zero **and pairwise distinct**, enforced in the constructor and every setter with `RoleCollision`. This puts non-negotiable 3 and BuildBaseBatch's "duplicate role" rule on-chain.
   - Permissions are exactly as the spec says. The owner sets roles, `allowVault` and `unpauseCreation`. The Guardian calls `pauseCreation` and `disallowVault`.
   - The brief also let the Timelock call `disallowVault`. The spec doesn't, so the owner cannot.
4. **`renounceOwnership` is disabled** (reverts with `RenounceDisabled`) on Registry and Reputation.
   - Renouncing would freeze roles forever and break VerifyBase's `owner()==Timelock` assertion.
   - Two-step transfer (R5) is unchanged OZ `Ownable2Step`. There is no `setOwner`, and a test proves the selector is absent.
5. **Reputation.**
   - `record` returns `bool recorded`.
   - A registered reporter that passes `circle != msg.sender` is **ignored (returns false), not reverted**. A circle can't strike under another circle's address, and "never reverts for a registered reporter" still holds.
   - Strikes are keyed `(user, circle, round, reason)`, the fix for the legacy reason-less key.
   - Counters `strikeCount` and `strikesByReason` were added for the backend.
   - `Reason` ordinals: LATE=0, MISSED=1, COVERED=2, DEFAULT=3.
   - `setReporter` rejects address(0).
   - The owner (Timelock) has **no** powers beyond ownership, because the spec defines none. `FACTORY` is immutable (see open question 2).
   - "No strikes until every member has joined" is the circles' job: they only call `_strike` while Active.
6. **Guardian canceller.**
   - There are two entry points: `cancel(target, value, data, predecessor, salt)` for `schedule` and `cancelBatch(targets, values, payloads, predecessor, salt)` for `scheduleBatch`. A one-call batch and a single op have different ids, so one generic entry point would be ambiguous.
   - Ids are recomputed **locally** with the exact OZ 5.1.0 formulas, and tests assert equality with `hashOperation` and `hashOperationBatch`. Calling the Timelock's pure helpers would copy the operation twice and could make a near-limit batch uncancellable. Measured with 200 calls: cancel about 0.34M execution gas, schedule about 1.04M.
   - A **rotation call** must match exactly: value 0, exact ABI length (36 or 68 bytes), and one of:
     - `REGISTRY.setGuardian(address)`;
     - `address(this).setGuardian(address)`;
     - `WRAPPER.setIsSentinel(address,bool)`.

     Anything else is cancellable, including an extra ETH value, extra or short calldata, or the same selector on another target.
   - An **empty batch is not rotation-only**, so the Guardian can cancel it.
   - `WRAPPER` is an immutable constructor argument and **may be zero**, meaning the Timelock owns no wrapper. In that case no `setIsSentinel` is protected. Adding a wrapper later means deploying a new canceller.
   - The rotation scan over the operation's calls is **not capped**. This is a deliberate exception to "every loop ≤ 50": a cap would let Gov schedule an uncancellable oversized batch. The loop is bounded by the operation itself, which the schedule transaction already paid for, at a higher per-call cost.
   - The canceller keeps its **own** `guardian` (spec: `canceller.setGuardian`, Timelock only). A rotation must update the Registry, the canceller and the wrapper sentinel in one batch. The fixture test executes exactly that batch.
   - Per spec, `wrapper.setIsSentinel(x, b)` is protected for **any** `x`. So a compromised Gov can add a sentinel uncancellably. Vault V2 sentinels can revoke, deallocate and decrease caps, but cannot reach principal.
7. **Factory.**
   - Spec order is kept: clone → `setReporter` → `initialize` → `isCircle = true` → `CircleCreated`. The mock records `reporterAtInit = true` and `isCircleAtInit = false` to prove it.
   - **Added** `circleOf[circleId]` (written right after the clone, before any external call) and `CircleIdUsed`. A circle id can be used once, across **both** modes, so `circleId` is a unique on-chain key and a retried create fails cleanly.
   - **Added constructor wiring checks** (`WiringMismatch`):
     - `reputation.FACTORY() == address(this)`;
     - each implementation reports the right `circleMode()`;
     - each implementation has the same `REGISTRY`, the same `REPUTATION`, and `USDC == registry.USDC()`.

     This requires Registry, Reputation and both implementations to **have code before the factory is deployed**, which matches the spec §5 order (implementations in batch 1; Registry and Reputation before the Factory in batch 2). C6 must keep that order.
   - **Added** `circleMode()` (pure) to `IMHCircle`, so the factory can tell implementations apart.
   - `CircleCreated(circleId, circle, mode, termsHash, operator)`. The spec doesn't fix its fields.
   - `nonReentrant` on both create functions.
8. **`_pay`.**
   - It follows spec §4.1: blacklisted recipient or USDC paused → `owed[to] += x`, `owedTotal += x`, `PayoutQueued`. Otherwise `SafeERC20.safeTransfer`, which reverts on failure.
   - **A zero amount is a no-op** (no event).
   - `claimOwed` pays `msg.sender` only and reverts `UsdcPaused` first while paused. Effects run before the transfer. A still-blacklisted caller reverts inside USDC and keeps the entry.
9. **Constants.** Two were added beyond the §4.1 table: `MIN_MEMBERS = 2` (a one-member circle is degenerate) and `MIN_VAULT_TIMELOCK = 7 days`. The $25k per-circle launch cap is **not** encoded on-chain (see open question 3).
10. **Vendored Vault V2 interface.**
    - Every signature is copied verbatim from `morpho-org/vault-v2` `src/interfaces/IVaultV2.sol` and `IERC4626.sol` at `main @ abaae813e754218061e7326e37487df718edd576` (fetched 2026-10-22).
    - It includes the ERC-4626 functions the accumulation circle will need: `deposit`, `withdraw`, `redeem`, `previewRedeem`, `previewWithdraw`, `convertTo*` and `totalAssets`.
    - It extends OZ `IERC20`, whose function signatures are identical to Morpho's `IERC20`.
    - `maxRedeem` and `maxWithdraw` are deliberately omitted: they always return 0 on Vault V2.
11. **Style.**
    - `src` pins `pragma solidity 0.8.28` exactly.
    - `forge fmt` was run with the repo's `[fmt]` config; `forge fmt --check` and `forge lint` are clean.
    - Every external function carries NatSpec (`@inheritdoc` from the interfaces).

### Contract for the next steps (C3: MHRotatingCircle / MHAccumulationCircle)
- Inherit `MHCircleBase` and implement `IMHRotatingCircle` / `IMHAccumulationCircle`.
- Pass `(usdc, registry, reputation)` to the base constructor. The base disables initializers.
- Implement `circleMode()` as `pure`. Also implement `circleId()` and `termsHash()`; public state variables are fine.
- `initialize(params) external initializer` must check:
  - `circleId != 0` and every §4.1 bound;
  - members unique and non-zero;
  - rotating: `totalRounds == n` and `securityBps.length == n`;
  - accumulation: the vault is 0 or allowlisted.

  Then set `termsHash` with `_rotatingTermsHash` / `_accumulationTermsHash`.
- Use `_pay` only after all effects, inside `nonReentrant` functions. Call `_requireUsdcLive()` at the top of every function that records strikes or stalls a circle on a timer. Call `_strike` only while Active.
- `MockVaultV2` covers governance views only; extend it with ERC-4626 mechanics, illiquidity, gate, loss and rounding toggles for the C3 invariant suite.
- The factory immutables `ROTATING_IMPL` and `ACCUMULATION_IMPL` are whatever addresses are deployed. No factory change is needed when the real implementations land; only the tests swap the mocks for them.

### Results
- `forge build`: OK (solc 0.8.28, cancun).
- `forge test`: **106 passed, 0 failed**:

  | Suite | Tests |
  |---|---|
  | Registry | 28 |
  | Factory | 24 |
  | Canceller | 22 |
  | Reputation | 17 |
  | Base | 15 |

  `FOUNDRY_PROFILE=ci` (1000 fuzz runs) also passes.
- Quick manual mutation check: 14 single-line mutations across canceller, factory, reputation, registry and base were all killed by the suite.
- `forge build --sizes`:

  | Contract | Runtime (B) | Initcode (B) |
  |---|---|---|
  | MHCircleFactory | 3,651 | 4,940 |
  | MHGuardianCanceller | 3,348 | 3,758 |
  | MHCircleRegistry | 3,192 | 4,030 |
  | MHReputation | 1,856 | 2,229 |

  All are far below 24,576 / 49,152.

### Open questions
1. **Wrapper ownership.** Does the Timelock own the Earn wrapper (Privy [VERIFY], spec §3.4)? If not, deploy the canceller with `WRAPPER = 0`. If the wrapper is created after the circles are deployed, a new canceller is needed to protect its `setIsSentinel`.
2. **Future factory.** Should Reputation's owner be able to authorize a future factory (a timelocked `setFactory`)? Today `FACTORY` is immutable, so a v2 factory needs a new Reputation, which loses on-chain history continuity.
3. **Launch cap.** Should the $25k per-circle cap (spec §4.3, audit gate 7) be enforced on-chain, for example by an `initialize` check on `contribution × rounds × members`, or by backend and feature flag only? It is not encoded yet.
4. **Collateral cap.** Should `MIN_MEMBERS = 2` stand? And should there be a per-member collateral cap? (C3.)
5. **`setIsSentinel` scope.** Should the protected `setIsSentinel` be restricted further (for example only `(oldGuardian,false)` / `(newGuardian,true)`)? The spec lists the selector only. Restricting it would need the canceller to know the incoming guardian.
6. **CI pinning.** `contracts-ci.yml` still uses `foundry-toolchain version: stable` and tag clones. Pinning is C6 and was not touched in this step.

---

## Step 2: C3 rotating circle, `MHRotatingCircle` (2026-10-22)

### What was done
- **New `src/circles/MHRotatingCircle.sol`** (EIP-1167 implementation; `MHCircleBase` constructor disables initializers; immutables `USDC`, `REGISTRY`, `REPUTATION`). Idle USDC only, no yield. Implements spec §4.2, §4.4, §4.5 (common and rotating rows) and §4.7.
- **`interfaces/IMHRotatingCircle.sol`** now holds the full rotating surface: `MemberState`, `CancelReason`, `ZeroAmount`, every event, function and view, all with NatSpec. The factory still only calls `initialize`.
- **`MHCircleConstants.sol`** gained `MAX_CURE`, `MAX_START_DELAY` and `MAX_CONTRIBUTION` (deviations 13–15).
- **Tests:**
  - `test/circles/RotatingFixture.sol` is the step-1 stack with the real implementation behind the factory. Its helpers act like the app: exact approval plus `contribute(r, amountDue)`, forward-only time travel to round gates, and an exact bucket and conservation check (`_assertBuckets`).
  - `test/circles/MHRotatingCircle.t.sol` (60 tests) covers every function, revert and event.
  - `test/circles/MHRotatingScenarios.t.sol` (17 tests) covers:
    - the worked example and D1–D4 with exact numbers;
    - regressions R1, R4 and R8;
    - n = 50 gas bounds;
    - three fuzz properties.
- **Test plumbing changes:**
  - `CircleFixture` deploys the implementations through two virtual one-CREATE hooks (`_deployRotatingImpl` / `_deployAccumulationImpl`), so step 3 can drop in the real accumulation circle the same way.
  - `MockRotatingCircle` no longer inherits `IMHRotatingCircle`. It keeps a selector-compatible `initialize`, which is all the factory calls.
  - `MockUSDC` gained FiatToken-style `blacklist` / `unBlacklist` / `pause` / `unpause`, next to the existing setters.
- **Reference model:** expected numbers were derived independently with an integer Python model of the same rules (`scratchpad/sim/rot_ref.py`, outside the repo).

### Mechanics as implemented
- **Security requirement:** `S_k = ceil(σ_k·(n−k)·c / 1e4)`. Holdback at payout is `max(0, S_k − sec)`. `requiredSecurity(m)` is `S_k` before the member's payout and `ceil(σ·(n − paidRounds)·c)` after it.
- **Draw:** `draw = min(c, max(0, sec − reqAfter))`, where `reqAfter` is `ceil(σ·(remaining − 1)·c)` after payout or `S_k` before it. The wallet owes `c − draw`, which is what `amountDue` returns.
- **`settleRound`** handles round `nextSettle` only, and only once that round has opened. For each member who has not contributed:
  - if `draw == c`, the draw is taken with no strike;
  - otherwise, after grace and only if `sec ≥ c`, the whole `c` is covered from security with a COVERED strike;
  - otherwise the call reverts `RoundShort`.

  Then `fee = floor(gross·feeBps)`, `cash = gross − fee − holdback`, and the cash goes through `_pay`, so it lands in `owed` if the recipient is blacklisted or USDC is paused.
- **`cancelStalled`** runs after `deadline + grace + cure`. A defaulter is a member who has not paid and has `sec < c`, which is exactly the case `settleRound` cannot cover; if there are none, it reverts `NotStalled`. The unwind then:
  1. folds `sec + unsettled pots + feeEscrow` into `A` (fees are waived);
  2. computes `E = max(0, cashIn − cashOut)` for every member;
  3. takes `min(E, c)` from each defaulter and gives it to the other members pro rata to their E;
  4. sets `claim = floor(A·W/ΣW)`, with the remainder kept as residual;
  5. records the DEFAULT strikes after all of the above.
- **Strikes:** every strike is recorded after all effects. Each timer gate that records a strike or stalls the circle reverts `UsdcPaused` while USDC is paused: a late `contribute`, a `settleRound` that needs a cover, `cancelStalled` and `cancelUnjoined`.

### Spec numbers: all reproduced exactly (n = 6, c = $100, fee 2%)

| Case | Spec | Implementation |
|---|---|---|
| Worked example σ=100%, no collateral | 88/188/288/388/488/588; wallet $0 after payout | identical; everyone −$12; treasury $72 |
| σ=100%, slot 1 posts $500 | **588**/188/…/588 | identical |
| σ=50% | 338/388/438/488/538/588; wallet $50 after payout | identical |
| D1 | security pays rounds 2–6, no strikes, all −$12 | identical; `strikeCount == 0` for everyone |
| D2 | cancels at round 4; $786 of $1,200 (65.5%); 4–6 −$138; 1/2/3 +$238/+$88/+$88 | identical; slot 1: COVERED in rounds 2 and 3, DEFAULT in round 4 |
| D3 | A = ΣE = $1,124; fees waived; slot 5 −$100; others share +$100 | slot 5 exactly −$100. The others get +$1.298701 ×2 and +$32.467532 ×3 (= $99.999998); 2 micro-USDC residual goes to the treasury after all claims |
| D4 | creditors ≈ −$75 without the penalty; slot 5's $100 penalty shared | without the penalty, −$75.272728 each. **With it:** creditors 3/4/6 end at −$50.303031, slot 5 at −$125.090910, slots 1/2 at +$138 |

**D4 reading.** The spec's "$100 penalty" is a shift of net position, not of dollars. Slot 5's weight E drops from 200 to 100, and each creditor's E rises by 33.33. Because only 74.9% of positions is recovered ($824 of $1,100), the creditors gain about $24.97 each in dollars, not $33.33. This is exactly the spec's formula `claim_m = floor(A·E'_m/ΣE')`. The spec's prose doesn't give the dollar figures, so there was nothing to correct.

### Deviations and resolved ambiguities
1. **Cover uses all of the security, not only "security above the requirement".** The literal wording contradicts the spec's own D2 numbers. In D2, after round 2's draw slot 1 holds exactly its requirement ($200), so a literal reading cancels at round 2 (A = $762 of ΣE $1,000, 76.2% recovered) instead of round 4 (65.5%). The implementation covers when `sec ≥ c`, taking the full `c` (the draw plus the unpaid wallet part), with no partial cover. This matches the D2 table and the brief's "secAssets ≥ c".
2. **"remaining" in `reqAfter`** means the rounds this member still owes, including the one being paid: `n − paidRounds`. In order, that equals `n − r + 1`. If a member pre-pays a later open round, the requirement still follows what they actually owe.
3. **Draws at settlement write no `paid` flag.** `paid(round, member)` is a view: true for every member when `round < nextSettle`, otherwise the contribution flag. This saves a fresh-slot SSTORE per drawn or covered member, about 1M gas at n = 50, which keeps `settleRound` under 5M (see Gas).
4. **LATE strike** applies only when a wallet payment (`pulled > 0`) is made after grace. A member whose wallet owes nothing is never struck, even when calling late (spec: "never asked to pay and never struck").
5. **`withdrawSecurity` while Active** allows `sec − requiredSecurity`, where the requirement before payout is `S_k`. That is the spec's own pre-payout requirement for draws. The brief allowed "unlimited before payout"; the spec wins.
   - Pending reverts `NotActive`, because the spec says "while Active".
   - Cancelled reverts `NotActive`, because security has already become claims.
6. **Holdback uses the literal `S_k`.** If the recipient pre-paid a later open round before its payout settled, `S_k` exceeds what it still owes. The excess is immediately withdrawable or drawable; a test covers this.
7. **Penalty with no counterparty.** If no non-defaulter has `E > 0`, nothing is moved and the defaulters keep their positions. A penalty can never reach the treasury.
   - The `Defaulted` event then reports a penalty of 0.
   - Floor dust from splitting the penalty stays in the pool (ΣW < ΣE), so it is spread pro rata.
8. **`guardianCancel`** works while Pending or Active as long as `nextSettle == 1` (R4).
   - After a payout it reverts `BadRound`; the spec list has no dedicated error.
   - An ended circle reverts `NotActive`.
   - The Guardian is read from `REGISTRY.guardian()` at call time; a test executes a Timelock rotation.
9. **`cancelUnjoined`** reverts `NotStalled` before `joinDeadline` (it is open at `> joinDeadline`; joining is allowed at `== joinDeadline`). It is treated as a stall on a timer, so it also reverts `UsdcPaused`.
10. **`extendDeadline`** is allowed only while Active.
    - It shifts every round deadline, and so the late, cover and stall gates: `deadline(r) = start + r·D + extension`.
    - It does not move round openings (`currentRound`), which stay monotonic.
    - Pending circles cannot be extended: the join deadline is part of the signed terms, and an unjoined circle just cancels with exact refunds.
    - `by == 0`, more than 7 days in one call, or more than 30 days in total revert `ExtensionLimit`.
11. **`settleRound` requires `nextSettle ≤ currentRound()`** (`BadRound`). Otherwise a round funded entirely by draws (rich collateral) could settle before it opens.
12. **`depositCollateral`** works in Pending or Active, for **joined** members only (`NotMember` otherwise, including a listed member who has not joined). Zero reverts `ZeroAmount`, a new error that is also used by `withdrawSecurity(0)`.
13. **`MAX_CURE = 30 days` (new).** An unbounded `cure`, set by a compromised operator or server, would make a stalled circle uncancellable forever and break §4.7 liveness (invariant 7).
14. **`MAX_START_DELAY = 30 days` (new).** `plannedStart ≤ joinDeadline + 30 days`, for the same liveness reason: collateral posted at join cannot sit in an Active circle that never opens.
15. **`MAX_CONTRIBUTION = 2^64 − 1` (new).** This is overflow hygiene, not a product limit: it keeps `σ·units·c` far from overflow, so no arithmetic can brick a circle.
16. **Storage packing.**
    - A member is two slots: `{uint80 cashIn, cashOut, claim}` and `{uint80 sec, uint32 paidRounds, uint16 σ, uint8 slot, bool joined, bool received}`. Every write goes through `SafeCast.toUint80`; 80 bits hold 1.2e18 USDC, and a test shows an oversized amount reverts.
    - `claim` shares a slot with `cashIn`/`cashOut`, which are non-zero whenever a claim is. So assigning 50 claims never writes fresh slots.
    - `memberState()` returns the interface's `MemberState` with `uint256` amounts.
17. **Pot clearing on cancel** loops `nextSettle..currentRound()`, because only rounds that have opened can hold contributions.
18. **Events.**
    - Named by the spec: `RoundSettled(r, recipient, gross, fee, holdback, cash)` and `Contributed(m, r, fromWallet, fromSecurity, late)` (ledger mapping §4.6, emitted for wallet payments, draws and covers alike).
    - Added: `Joined`, `Activated`, `CollateralDeposited`, `Covered`, `CircleCompleted`, `SecurityWithdrawn`, `Defaulted`, `ClaimAssigned(m, E, claim)`, `CircleCancelled(reason, assets, residual)`, `Claimed`, `FeesFlushed`, `DeadlineExtended`, `DonationsSwept`, `ResidualSwept`.
    - **A cover emits both `Contributed(…, fromSecurity = c, late = true)` and `Covered`.** The indexer must post only from `Contributed`.
19. **No per-member `settled` field** on the rotating circle. Its end-state is `claim` (Cancelled) or `sec` (Completed), and §4.2 lists `settled` for both modes generically.
20. **`sweepResidual`** requires Completed or Cancelled with `secTotal == 0 && claimTotal == 0` ("every member bucket is 0"). Outstanding `owed` entries do not block it: they are reserved separately. `sweepDonations` sends `balance − trackedAssets − owedTotal`, which tests show equals exactly the untracked USDC.
21. **Rounding.** `S_k`, `reqAfter` and the requirement use ceil (against the member being paid); the fee uses floor (against the treasury); claims use floor, with the remainder as residual.
    - Because contributions are whole cents (1e4) and BPS = 1e4, `σ·units·c` and `gross·feeBps` are always exact, so the S_k ceil and the fee floor never actually round. A fuzz test pins this.
    - Consequence: the cash formula `gross − fee − holdback` is exact, and `cash ≥ 0` is tight at n = 50, fee 2%, σ = 100% (slot 1 cash = 0, tested).

### Results
- `forge build`: OK.
- `forge test`: **183 passed, 0 failed**:

  | Suite | Tests |
  |---|---|
  | Rotating unit | 60 |
  | Rotating scenarios | 17 |
  | Registry | 28 |
  | Factory | 24 |
  | Canceller | 22 |
  | Reputation | 17 |
  | Base | 15 |

  - `FOUNDRY_PROFILE=ci` (1000 fuzz runs) passes.
  - `forge fmt --check` and `forge lint` are clean.
  - No try/catch, `tx.origin`, code-size check, `receive`/`fallback` or low-level call appears in `src`.
- **Every rotating test asserts the buckets.** `Σsec == secTotal`, `Σpot == potTotal`, `Σclaim == claimTotal`, `balance == trackedAssets + owedTotal`, and `ΣcashIn − ΣcashOut == trackedAssets + treasury inflow`.
- **Fuzz properties** (§4.7 invariant 5), each at 1000 runs:
  - With no defaults, any σ per slot, random collateral, fee and timing within grace, every member nets exactly −fee, the treasury gets n fees, and the circle ends empty.
  - At σ = 100% with any single defaulter and stop round, a completed circle nets everyone −fee, and on a cancellation every honest member's net is ≥ 0.
- **Regressions:**
  - **R1:** the n = 3 counterexample now unwinds by net position. Slot 2 ends at −$1.84 (legacy: +$144), creditor slot 3 at −$92.16 (legacy: −$150), and their combined loss is exactly the defaulter's +$94 gain plus 1 micro-USDC.
  - **R4:** `guardianCancel` reverts after the first payout in every later round.
  - **R8:** gas-limit sweeps on `settleRound` (cover, strike and payout), `contribute`, `cancelStalled` (unwind and strikes) and `claim`. Every out-of-gas attempt left no partial state.
- **Gas at n = 50** (spec ≤ 5M):

  | Case | Gas |
  |---|---|
  | `settleRound` with 49 covers and 49 strikes | 4,051,111 |
  | `cancelStalled` with 50 defaulters, each with a security reset and a claim, called once all 50 rounds are open | 4,205,575 |
  | `guardianCancel` | 254,259 |

  The first version (unpacked members, `paid` flags written at settlement) measured 4.94M with 48 covers. Its true worst cases would have exceeded 5M.
- **Mutation check:** 48 hand-written single-line mutants of `MHRotatingCircle` were run in a scratch copy; 46 were killed. The 2 survivors (S_k ceil→floor, fee floor→ceil) are equivalent mutants by deviation 21.
- **Sizes** (`forge build --sizes`): `MHRotatingCircle` is **16,682 B runtime / 17,264 B initcode**, with margins of 7,894 / 31,888. The step-1 contracts are unchanged.

### Open questions (step 2)
1. **Cover wording vs D2** (deviation 1). Confirm that a cover may use security below the requirement, as the D2 numbers need, and amend the §4.4 wording.
2. **D4 penalty unit.** Confirm that `min(E, c)` shifts net-position weight, worth about $74.91 to the creditors at 74.9% recovery, rather than a dollar transfer of up to `c` from the defaulter's claim.
3. **Collateral before payout.** Locked down to `S_k` (spec reading) or fully withdrawable (brief)? The second is economically safe too: a not-yet-paid member is a creditor.
4. **New bounds.** `MAX_CURE = 30 days` and `MAX_START_DELAY = 30 days` (liveness) need a founder or product OK on the values.
5. **Reputation gas headroom.** Each first-time strike costs about 71k gas, which is about 85% of the n = 50 worst cases. Packing `strikeCount` and `strikesByReason` into one slot in `MHReputation` (step-1 code, same external interface) would save about 21k per strike (about 1M at n = 50). Not done here, to keep step 1 frozen.
6. **Guardian extension while Pending.** Should a USDC pause near `joinDeadline` be extendable, or is cancel-and-recreate enough (the current behaviour)?
7. **Indexer.** Covers emit both `Contributed` and `Covered` (deviation 18). Confirm that A11 posts only from `Contributed`.

---

## Step 3: C3 accumulation circle, `MHAccumulationCircle` (2026-10-22)

### What was done
- **New `src/circles/MHAccumulationCircle.sol`** (EIP-1167 implementation; `MHCircleBase` constructor disables initializers; immutables `USDC`, `REGISTRY`, `REPUTATION`). Implements spec §4.2, §4.3, §4.5 (common and accumulation rows) and §4.7.
- **`interfaces/IMHAccumulationCircle.sol`** now holds the full accumulation surface: `MemberState`, `CancelReason {Unjoined, Guardian}`, three new errors, every event, function and view, all with NatSpec.
- **Tests:**
  - `test/mocks/MockVaultV2.sol` was extended from a governance-only mock into an ERC-20/ERC-4626 Vault V2. It keeps the constructor, the gate, timelock, abdication and sentinel views and their setters, so the registry and canceller suites run unchanged.
    - Conversions use Vault V2's exact formulas from `VaultV2.sol` @ `abaae813`: `virtualShares = 1e12`, deposit and redeem round down, withdraw rounds up, all over `(totalSupply + virtualShares)` and `(totalAssets + 1)`.
    - Knobs: yield (`mockYield` mints USDC into the vault), loss (`mockLoss` sends USDC away), illiquidity (an exhaustible exit-liquidity budget), deposit and exit blocks (gates), and a `previewRedeem` discount. The discount models a conservative, drifting preview; actual exits still use the true price.
    - `maxRedeem` and `maxWithdraw` **revert**, so any code path that calls a `max*` function fails the tests.
  - `test/circles/AccumulationFixture.sol` is the step-1 stack with the real implementation behind the factory and the mock vault allowlisted through the Timelock. Its helpers act like the app and the keeper.
  - `_assertBuckets()` checks the share-bucket identity, the per-member sums, tracked counters equal to balances, and Σ toAssets(bucket) ≤ NAV.
  - `test/circles/MHAccumulationCircle.t.sol` (48 tests) covers every function, revert and event.
  - `test/circles/MHAccumulationScenarios.t.sol` (15 tests) covers:
    - the spec example and its 1% loss case with exact numbers;
    - the settlement-order effect;
    - a circle with no yield;
    - R2, R3 and R8;
    - `previewRedeem` drift;
    - n = 50 gas bounds;
    - three fuzz properties.
  - `test/mocks/MockCircles.sol`: `MockAccumulationCircle` no longer inherits `IMHAccumulationCircle`. It keeps a selector-compatible `initialize`, which is all the factory calls. This is the same treatment the rotating mock got in step 2.
- **Reference model:** the expected numbers come from an independent integer Python model of the spec rules over Vault V2's formulas (`scratchpad/sim/acc_ref.py`, outside the repo).

### Mechanics as implemented
- **Pool accounting.**
  - Tracked counters only: `idleAssets`, `vaultShares`, `totalShares`. `balanceOf` is read only by `sweepDonations`, to find untracked funds.
  - `NAV = idleAssets + vault.previewRedeem(vaultShares)`, read once in each transaction that values shares. `claimInKind`, `guardianCancel` and the sweeps do not read it.
  - Conversions use `Math.mulDiv` with explicit rounding:
    - mint `floor(a·(T+1e6)/(NAV+1))`;
    - payout `floor(s·(NAV+1)/(T+1e6))`;
    - burns for an asset amount use `Ceil`.
  - Buckets: `Σacc + Σclaim + forfeitShares + residualShares == totalShares`, asserted in every test step.
- **Moving funds.**
  - `deployIdle` is permissionless and Active-only. It deposits the whole idle balance with `forceApprove(vault, amount)` followed by `vault.deposit(amount, this)`, adds the returned shares, and reverts on failure. `contribute` never calls it.
  - `_takeIdle(x)` (the spec's `_ensureIdle`) withdraws exactly `x − idle` and lets reverts bubble. Because `x ≤ NAV`, the vault never burns more shares than the circle holds.
  - `emergencyExit` and `pullFromVault` `redeem` a bounded chunk each time.
- **Fee.** `floor(max(0, gross − principal)·feeBps)`, charged only when a **compliant** member settles at maturity. It is never charged on contributions, `exitEarly`, cancellations or claims, or when a delinquent member settles. In kind, it is taken pro rata from the USDC part and the vault-share part, each rounded down (against the treasury).
- **Maturity.**
  - `finalize` is open to anyone after `deadline(N) + grace`. Compliant means `paidRounds == N && !exited`.
  - If someone is compliant, each delinquent member whose value (floored) exceeds principal keeps `toShares(principal)` (floor), and the rest goes to forfeit.
  - Snapshots: `forfeitSnap`, `compliantSnap` and `bonusBase` (the bonus denominator).
  - `settleMember(m)` is open to anyone and pays only `m`:
    - compliant: `toAssets(acc + floor(forfeitSnap·acc/bonusBase))` minus the fee;
    - delinquent: `min(P, toAssets(acc))` with no fee. When capped, `ceil(toShares(P))` shares are burned and the leftover goes to residual.
  - The last settlement closes the circle (`Closed`) and moves the bonus-rounding dust from forfeit to residual.
- **Guardian.**
  - `emergencyExit(maxShares)` switches yield off (one-way) and redeems `min(maxShares, vaultShares)`. With `maxShares = 0` it only switches yield off, which works even when the vault is fully illiquid (R3).
  - `guardianCancel` works while Active. Each member's claim is `acc + floor(forfeit·acc/Σacc)`, the dust goes to residual, and no fee is charged.
  - `extendDeadline` works while Active, at most 7 days per call and 30 days in total.

### Spec numbers: all reproduced (spec §4.5 example; 4 members, $100, 12 rounds, fee 10%)
D skips rounds 4 and 8, everyone deposits each round, and the yield or loss is applied after the last contribution, so every member's value per dollar is identical.

| Item | Spec | Implementation (micro-USDC, exact; reference-model match) |
|---|---|---|
| Values before maturity | A/B/C $1,230; D $1,025 | 1,230,000,000 ± 1; 1,025,000,000 ± 1 |
| D forfeits | $25 | 24,390,243,690,350 pool shares = $25.000000 ± 1 |
| A, B, C bonus | $8.33 each | 8,130,081,230,116 shares = $8.333333 each |
| A gross / fee / net | $1,238.33 / $3.83 / $1,234.50 | A (settled first): 1,238,333,332 / 3,833,333 / 1,234,499,999. B, C: 1,238,333,333 / 3,833,333 / 1,234,500,000 |
| D | $1,000, no fee | 1,000,000,000, fee 0 |
| Treasury | — | 11,499,999 (three fees). Residual after sweep: 2 pool shares, worth 1 micro-USDC of vault shares |
| 1% loss | no forfeit, no fee; A $1,188, D $990 | A, B, C 1,188,000,000; D 990,000,000; forfeit 0; fee 0 |

**Settlement order.** Order only moves floor-rounding dust. In the order D, C, B, A, D settles first and gets 999,999,999. Its retained shares are `floor(toShares(P))` and its payout is floored, both against the member leaving (spec §4.3). B and C get 1,234,500,000 either way.

### Deviations and resolved ambiguities
1. **`join(terms, collateral)`** keeps the rotating signature, so one client call serves both modes. Accumulation circles take no collateral, so a non-zero `collateral` reverts `BadTerms`, as the brief says.
2. **Contribution window.**
   - It is implemented as `1 ≤ r ≤ currentRound()`, `now ≤ deadline(r) + grace`, and `r` not flagged.
   - With no extension this is exactly the spec's "the current round, or the previous one while its grace lasts", because grace is shorter than a round. With a Guardian extension it follows the extended deadlines.
   - A flagged round stays closed even if an extension would reopen it, so a MISSED strike and a later payment cannot coexist.
   - Consequence: an accumulation payment is never past grace, so **accumulation circles record no LATE strikes**. Missing a round costs a MISSED strike (through `flagRound`) and compliance.
3. **`Contributed(m, r, fromWallet, fromSecurity, late)`** has the rotating event's exact shape, so one indexer decoder serves both. Here `fromSecurity = 0` and `late = false` always.
4. **`cure`** is part of the shared config. It is bounds-checked and hashed into `termsHash`, but accumulation circles do not use it.
5. **`exitEarly`.**
   - Active only, including after the last round but before `finalize`.
   - It records `exitRound = currentRound()`, marks the member `exited` and `settled`, and counts the member in `settledCount`.
   - In a loss, `min(P, value)` is the value, and only rounding dust (under one micro-USDC) is forfeited.
   - Exited members are flagged MISSED only for rounds before `exitRound`, so leaving does not erase strikes already earned. Rounds after the exit are not owed.
6. **`flagRound`** works while Active, Matured or Closed: every member has joined, and §4.1's actual rule is "no strikes until every member has joined". The step-1 note said circles strike "only while Active"; that is relaxed so rounds can still be flagged after maturity. Pending and Cancelled revert `NotActive`. Range, too-early and already-flagged all revert `BadRound`.
7. **`finalize` reverts `UsdcPaused` while USDC is paused**, because it applies timing-based penalties (spec §4.5 rule for timer functions). Before `deadline(N) + grace` it reverts `NotMatured`.
8. **Retained shares** `floor(P·T/NAV)` are read under the §4.3 virtual-share conversion: `toShares(P) = floor(P·(T+1e6)/(NAV+1))`. The cap applies when the floored value is strictly greater than P, so a value exactly equal to P is never touched (a test pins this).
9. **The all-delinquent rule** (`compliantSnap == 0`, a founder call).
   - Nothing is capped, and no fee is charged, as the spec says ("toAssets(acc), uncapped").
   - The spec does not say what happens to a forfeit pool left by early exits in this case: its own formula divides by zero. The implementation shares it pro rata to every remaining member's shares (`bonusBase = Σacc`), so members' yield never goes to the treasury. If nobody remains (`bonusBase == 0`), the forfeit goes to residual.
10. **Everyone exited.** `finalize` moves the forfeit to residual and goes straight to `Closed`.
11. **`settleMemberInKind(m)`** requires `msg.sender == m` (otherwise `NotMember`). Anyone may call the cash `settleMember(m)`, but nobody can force vault shares on a member.
12. **In-kind pro rata** uses `T + VIRTUAL_SHARES` as the denominator, consistent with `toAssets`, so an in-kind payout is never worth more than its cash equivalent. Vault shares are sent with `SafeERC20.safeTransfer` on the vault token; Vault V2 share transfers do not touch USDC, and the allowlisted share gates are zero and abdicated.
13. **`cashOut`** counts USDC paid or queued only. In-kind vault shares are reported in `MemberSettledInKind` and `ClaimedInKind`. `principal` is the member's `cashIn`; there is no collateral.
14. **`sweepResidual`**, once `accTotal == 0 && claimTotal == 0` (Closed, or Cancelled with every claim taken):
    - It sends **everything left** to the treasury: idle USDC through `_pay`, and vault shares in kind. That covers residual shares plus the virtual-share remainder the last member to leave cannot take.
    - It never needs a full redeem (R3).
    - Afterwards every counter is zero.
15. **`sweepDonations`** also sweeps vault shares above `vaultShares`, as the brief says. It never touches `owed`.
16. **`emergencyExit`** works in any status and reverts `NoYield` on a circle with no vault. **`pullFromVault`** is capped at the shares held and reverts `ZeroAmount` when there is nothing to redeem.
17. **`guardianCancel`** works while Active only, as the spec says (rotating also allowed Pending; an accumulation circle holds nothing while Pending). Members with zero shares, including exited ones, get no claim and no event. After a cancellation, `claim()` pays in cash and `claimInKind()` pays in kind; neither charges a fee.
18. **New errors** in `IMHAccumulationCircle`:
    - `ZeroAmount`: `pullFromVault` has nothing to redeem.
    - `NoYield`: no vault, or `deployIdle` after yield was switched off.
    - `NothingToDeploy`: idle is below `MIN_DEPLOY`.
19. **`initialize` vault check.** Besides `REGISTRY.isAllowedVault(vault)`, it also requires `vault.asset() == USDC` (defense in depth). A vault delisted before creation is rejected with `BadConfig`; one delisted between creation and the last join switches yield off at activation, as the spec says.
20. **`cancelUnjoined`** reverts `UsdcPaused` while USDC is paused, for consistency with the rotating circle, even though an accumulation circle holds nothing before activation. **`extendDeadline`** works only while Active (same as rotating).
21. **Views added** beyond the spec list: `nav()`, `memberValue(m)` (`toAssets(acc)` at the current NAV), `bonusBase()`, `settledCount()`, `paid(r, m)`, `amountDue(m, r)`, `memberState(m)` (including a derived `compliant`), `roundDeadline(r)`.
22. **Storage.**
    - A member is two slots: `{uint128 acc, uint128 claim}` and `{uint88 principal, uint88 cashOut, uint32 paidRounds, uint16 exitRound, uint8 slot, bool joined, exited, settled}`. Every write is range-checked with `SafeCast`.
    - Paid rounds are a per-member bitmap (word `r >> 8`), because accumulation circles can run 520 rounds.
    - No loop runs over rounds.
23. **Vault-level rounding.** Vault V2 `withdraw` rounds the burned shares up, so the remaining pool can lose under one micro-USDC per withdrawal. This is borne pro rata by the members who stay, because NAV is re-read each transaction. Nobody is promised a stored asset amount.

### Results
- `forge build`: OK.
- `forge test`: **246 passed, 0 failed**:

  | Suite | Tests |
  |---|---|
  | Accumulation unit | 48 |
  | Accumulation scenarios | 15 |
  | Rotating unit | 60 |
  | Rotating scenarios | 17 |
  | Registry | 28 |
  | Factory | 24 |
  | Canceller | 22 |
  | Reputation | 17 |
  | Base | 15 |

  - `FOUNDRY_PROFILE=ci` (1000 fuzz runs) passes.
  - `forge fmt --check` and `forge lint` are clean.
  - No try/catch, `tx.origin`, code-size check, `receive`/`fallback` or low-level call appears in `src`.
- **Fuzz properties** (§4.7 invariants 1–6), each at 1000 runs:
  - **Lifecycle:** n, rounds, fee, missed rounds and an optional early exit vary, with a uniform yield or loss of −20% to +20%. Buckets and Σ toAssets ≤ NAV are checked at every step. At the end:
    - Σ bonus ≤ `forfeitSnap`, and the bonus dust goes to residual;
    - the fee is exactly `floor(earnings·feeBps)` for compliant members and 0 otherwise;
    - a delinquent member gets at most its principal;
    - a compliant member gets at least as much per dollar as a delinquent one;
    - with no earnings the fee is 0;
    - residual is at most n + 2 micro-USDC.
  - **No admin path:** gov, Timelock, Guardian, operator, treasury and an attacker call every function with random arguments mid-life, and the Guardian uses its real powers (chunked exits, extensions, cancellation, delisting). Afterwards:
    - no admin holds USDC or vault shares;
    - no member's net is below −2 micro-USDC;
    - the treasury got at most 15% of the yield plus dust.
  - **Conversion rounding:** a mint followed by a payout never returns more than went in, and a ceil burn for a floored payout never exceeds the shares held.
- **Regressions:**
  - **R2:** no setter for the vault or adapter exists (6 legacy selectors fail for every role). Allowlisting another vault or delisting this one leaves a live circle untouched.
  - **R3:** with the vault fully illiquid:
    1. cash settlement and a single large `emergencyExit` revert;
    2. `emergencyExit(0)` switches yield off;
    3. anyone pulls chunks as liquidity returns;
    4. one member settles in cash and three in kind;
    5. everyone nets +$21.60 (± 3 micro-USDC).

    The mock reverts on `max*`.
  - **R8:** gas-limit sweeps over `contribute`, `deployIdle`, `exitEarly`, `flagRound`, `emergencyExit`, `finalize`, `settleMember` and `settleMemberInKind`. Every out-of-gas attempt left no partial state.
- **Gas at n = 50** (spec ≤ 5M; measured with `forge test --isolate`, so storage is cold):

  | Function | Gas |
  |---|---|
  | `flagRound`, 50 MISSED strikes | 3,995,360 |
  | `finalize`, 49 caps | 831,506 |
  | `guardianCancel` | 580,139–733,123 |
  | `settleMember` | 193,077 |
  | `exitEarly` | 167,708 |
  | `settleMemberInKind` | 148,916 |
  | `claim` | 134,841 |
  | `claimInKind` | 83,233 |
  | `sweepResidual` | 57,593 |

  The same isolated run measures the step-2 rotating `cancelStalled` worst case at **4,832,639**. Step 2 reported 4.21M from a non-isolated run, where storage is warm.
- **Mutation check:** 69 hand-written single-line mutants of `MHAccumulationCircle` were run in a scratch copy; all 69 were killed. The first pass left 3 survivors and the second 1; four targeted assertions were added to kill them:
  - a value exactly at principal is not capped;
  - the last member to leave in kind leaves the virtual-share remainder;
  - an exited member is not compliant;
  - no `ClaimAssigned` event is emitted for a zero-share member.
- **Sizes** (`forge build --sizes`): `MHAccumulationCircle` is **20,295 B runtime / 20,919 B initcode**, with margins of 4,281 / 28,233. The other contracts are unchanged.

### Open questions (step 3)
1. **Liveness if `previewRedeem` itself reverts** (for example a Vault V2 adapter's `realAssets` reverting). Every NAV-based path reverts: `finalize`, `settleMember`, `settleMemberInKind`, `exitEarly`, `claim` and `contribute`. While Active, the Guardian can `guardianCancel`, and `claimInKind` needs no NAV. After `finalize` there is no NAV-free exit, which breaks §4.7 invariant 7 in that failure mode. Options:
   - allow `guardianCancel` while Matured;
   - add a NAV-free in-kind settlement (pro rata by shares, with no fee or caps) behind a Guardian-set flag.

   Both need a spec change.
2. **All-delinquent rule** (founder call): confirm that exit forfeits are shared pro rata among remaining members (deviation 9) and that no fee is charged.
3. **Delinquent rounding.** Floor retention means a delinquent member can get P − 1 micro-USDC. Is exact P wanted? That would mean ceil retention with the leftover going to residual.
4. **Yield after maturity on a capped delinquent's shares** goes to residual (the treasury), per the spec's "leftover shares go to residual". It is dust if the keeper settles promptly, but grows if settlement is delayed. Should it go to the compliant members instead? `forfeitSnap` is fixed at maturity, so that would need a second distribution.
5. **`exitEarly` after the last round but before `finalize`** is allowed: a compliant member can give up its earnings and leave. Should it be restricted to rounds that are still open?
6. **Rotating gas headroom.** Isolated, `cancelStalled` at n = 50 is 4.83M against a 5M cap. Step-2 open question 5 (packing Reputation's counters) or measuring with `--isolate` in CI (C5/C6) is recommended.
7. **`cure`** is unused by accumulation circles. Should it be kept in the shared terms, or required to equal `MIN_CURE`?
8. **Handler-based invariant suite** (10k runs at depth 200, spec §4.7) is left to C5. This step's fuzz tests assert the invariants after every step of randomized lifecycles.
9. **Residual vault shares** go to the treasury in kind rather than being redeemed. Confirm the Treasury Safe is fine holding Vault V2 shares.

---

## Step 4: C5 analysis suites (2026-10-22)

### What was done
- **Invariant suites** (`test/circles/invariant/`), handler-based with a ghost ledger, one circle per run:
  - `RotatingHandler.sol` + `MHRotatingInvariant.t.sol` (22 actions);
  - `AccumulationHandler.sol` + `MHAccumulationInvariant.t.sol` (33 actions, mock Vault V2 knobs included).
- **Fuzz suites:** `test/circles/MHRotatingFuzz.t.sol` (D1–D4 properties) and `test/circles/MHAccumulationFuzz.t.sol` (whole accumulation paths).
- **Base fork tests** (`test/fork/`): `BaseForkFixture.sol`, `ForkInterfaces.sol`, `MHCirclesFork.t.sol` (8 tests). Gas snapshots in `snapshots/circles-fork.json`.
- **R8 boundary-gas harness:** `test/circles/BoundaryGas.sol` + `MHBoundaryGas.t.sol` (37 tests: every state-changing public function of both circles, plus factory creates and `canceller.cancel`).
- **Cold gas bounds** (`MHGasBounds.t.sol`, isolated: every call is its own transaction) for the n = 50 worst cases.
- **EIP-7702 member** (`MH7702Member.t.sol`, `test/mocks/Mock7702.sol`): an EOA delegated to a Kernel-style batch executor runs a rotating and an accumulation lifecycle with batched [approve, action] calls.
- **Mocks:** `MockUSDC` and `MockVaultV2` gained a test-only flow ledger (`watch`, `sent`, `received`, `recipientsOf`) so the invariant suites see every token movement out of and into a circle. No behaviour change for the other suites.
- **`foundry.toml`:** `[profile.default.invariant]` runs = 32, depth = 100 (local); `[profile.ci.invariant]` runs = 10,000, depth = 200 (unchanged numbers, `fail_on_revert = false` added to both).
- **Source changes** (both regression-tested, see "Fixes"): `MHRotatingCircle` no longer clears per-round pots on a cancellation (`pot` is now an explicit view that reads 0 once Cancelled), and two `IMHAccumulationCircle` parameter names were renamed for Slither's `shadowing-local` (no ABI change).

### Invariant suites (spec §4.7 invariants 1–8)
- **Per run:** the first call creates the circle from a hashed seed.
  - Rotating: n 2–8, c $1–$500 in whole cents, fee 0–200 bps, σ all 100% / all 50% / mixed, round 7–14 days, any grace and cure, collateral, and a random set of unreliable members, each with its own stop round.
  - Accumulation: n 2–6, rounds 1–8, c $1–$500, fee 0–1,500 bps, the mock vault or none, lock on or off, and unreliable members that skip a third of their rounds.
  - Three runs in four join straight away; the rest exercise the unjoined path.
- **Actors:** the members, the Gov Safe, the Timelock, the Guardian, the operator, the treasury and an attacker.
  - `adminPoke` lets any admin or the attacker call any circle function with arbitrary arguments, including re-`initialize`.
  - The real Guardian also cancels, extends, exits in chunks and delists, at low rates so most runs live long enough to settle rounds.
  - Circle (the issuer) pauses USDC and blacklists a member or the treasury now and then.
  - Outsiders donate USDC, and vault shares to yield circles.
  - The vault gains, loses, goes illiquid, blocks deposits or exits, and drifts its preview.
- **Checked after every call (rotating):**
  1. `balance == secTotal + potTotal + feeEscrow + claimTotal + residual + owedTotal + unswept donations`, exactly;
  2. `Σsec`, `Σclaim` and `Σpot` equal their totals, and claims only exist after a cancellation;
  3. per member, USDC pulled == `cashIn` and USDC sent + `owed` == `cashOut`;
  4. ΣcashIn − ΣcashOut == tracked buckets + fees flushed + residual swept;
  5. USDC leaves only to members and the treasury, and no admin or the attacker ever receives anything;
  6. the treasury receives only `flushFees` (only once Completed, at most n × fee), `sweepResidual` (< n units) and `sweepDonations` (≤ donated);
  7. Completed ⇒ every member's `cashIn − cashOut − sec == fee` (nets −fee once security is withdrawn);
  8. Cancelled ⇒ an unjoined or Guardian cancellation refunds exactly. Otherwise, with σ = 100% everywhere, a non-defaulter never loses and a defaulter loses at most min(E, c) and never gains (D3). At any σ, a member gains at most its uncollateralised credit (n−k)·c − S_k plus the redistributed penalties (D2/D4);
  9. the largest gas used by any call is under 5M.
- **Checked after every call (accumulation):**
  1. USDC balance == `idleAssets + owedTotal + unswept donations` and vault-share balance == `vaultShares + unswept share donations`, exactly;
  2. the share buckets sum to `totalShares`, and Σ toAssets(bucket) ≤ NAV;
  3. per member, USDC pulled == `principal` and USDC sent + `owed` == `cashOut`;
  4. USDC leaves only to members, the treasury and the vault (deposits), and vault shares only to members and the treasury (or burned);
  5. the treasury receives only settlement fees (only at maturity), residual and donations;
  6. Σ bonus ≤ `forfeitSnap`;
  7. every settlement is checked when it happens against the spec §4.5 formula, evaluated independently just before the call:
     - a cash settlement pays exactly `gross − fee` and the treasury exactly `floor(max(0, gross − P)·fee)`;
     - an in-kind settlement is worth no more than its cash value, and its fee no more than the fee on earnings (+1 unit);
     - a delinquent member gets at most its principal;
     - an exit pays at most principal;
  8. gas under 5M.
- **After every run (`afterInvariant`, invariant 7):** the circle is driven to an end state with time, permissionless calls and members acting for themselves only.
  - USDC is unpaused (the issuer's call).
  - The vault is left as the run left it, possibly illiquid, gated or discounted, so in-kind paths are taken when cash cannot be paid.
  - Reliable members keep paying, and each step that must succeed is asserted.
  - Every claim and queued payout is then paid, everything is swept, and the circle must end with zero USDC, zero vault shares and zero buckets.
  - Accumulation additionally checks per-dollar fairness when no loss or preview discount occurred.
- **Runs:**
  - local (default profile, 32 × 100) passes in about 5 s per suite;
  - 1,000 runs × depth 200 passed for both suites (200,000 calls each; about 5–6 minutes per suite);
  - CI profile (10,000 × 200): **both pass**. Each made 2,000,000 calls with 0 handler reverts; rotating took 3,342 s and accumulation 2,796 s (about 56 minutes wall clock in parallel on this machine).
- **Coverage probe (100 runs, 200 calls).**
  - Rotating: about 30% of runs complete, 40% stall and cancel, 17% are Guardian-cancelled and 12% unjoined; settled rounds per run range from 0 to 8.
  - Accumulation: Active, Matured, Closed and Cancelled end states all occur, and the in-kind paths are taken.

### Fuzz suites (spec §4.7 fuzz)
- **`testFuzz_rotating_defaultPatterns`.** Varies:
  - n 2–12 and c $1–$10,000;
  - fee 0–200 bps;
  - σ mode (all 100%, all 50%, or mixed);
  - collateral;
  - a random set of defaulters with random stop rounds;
  - on-time payment moments within the round and grace;
  - one payment in six made late (after grace, before the end of cure);
  - withdrawals of free security after payout.

  It asserts:
  - exact money conservation (members + treasury = 0);
  - Completed ⇒ every member nets exactly −fee and the treasury gets n fees;
  - D1: at σ = 100%, members that stop only after their own payout never stall the circle and get no COVERED or DEFAULT strike;
  - D3: at σ = 100%, on a stall an honest member never loses, and a defaulter loses between 0 and min(E, c);
  - D2/D4: at any σ, a member gains at most its credit plus penalties, and total losses are bounded by the credit extended plus penalties;
  - LATE strikes exactly for wallet payments made after grace;
  - COVERED only for non-payers, and DEFAULT only on a stall.

  It passed 5,000 runs.
- **`testFuzz_accumulation_paths`.** Varies:
  - n 2–8, rounds 1–10 and c $1–$1,000;
  - fee 0–1,500 bps;
  - payment moments, including paying the previous round within its grace;
  - unreliable members;
  - early exits, with lock on or off;
  - a Guardian extension;
  - a per-round vault path: none, yield only, or yield and loss;
  - cash or in-kind settlement, with the vault fully illiquid at maturity.

  It asserts:
  - buckets after every step;
  - MISSED strikes exactly for unpaid rounds (none for rounds after an exit), and never a LATE strike;
  - every settlement against the independent spec evaluation (fee exact, delinquent ≤ principal, in-kind ≤ cash);
  - Σ bonus ≤ forfeitSnap;
  - exits pay at most principal and charge no fee;
  - compliant ≥ delinquent per dollar when the share price never falls;
  - with no yield and no loss, nobody gains or loses beyond vault rounding;
  - the circle ends empty and the treasury holds only fees plus dust.

  It passed 5,000 runs.
- The existing step-2/3 fuzz tests and the exact D1–D4 and accumulation-example unit tests are unchanged.

### Base fork tests (spec §4.7 "Base fork")
- **Setup.**
  - Skipped unless `BASE_RPC_URL` is set (`vm.skip` in `setUp`).
  - Forks block **52,933,005** (the Appendix A check block), overridable with `BASE_FORK_BLOCK`. The RPC must serve historical state; `https://mainnet.base.org` does.
  - Deploys the whole stack in the §5 order against real USDC.
  - Allowlists Gauntlet USDC Prime through the Timelock with the real `allowVault` checks.
- **Isolation is required.** The suite runs with `forge-config: default.isolate = true`. Vault V2 accrues interest once per transaction (`firstTotalAssets` is transient storage), so a non-isolated test sees one frozen NAV, and the first run without isolation failed exactly that way. On chain every call is its own transaction, so isolation is the faithful model.
- **Run once with `BASE_RPC_URL=https://mainnet.base.org`: 8 passed, 0 failed.**

| Test | What it shows |
|---|---|
| `appendixA_codeAndGauntletChecks` | All nine Appendix A addresses, and Morpho Blue, have code. USDC's `isBlacklisted` and `paused` respond. On Gauntlet: `asset == USDC`; the three exit gates are 0 and abdicated; `setIsAllocator` and `addAdapter` are timelocked 7 days; the liquidity adapter is the Appendix A one; `maxRedeem` and `maxWithdraw` return 0. Monitor inputs pinned: performance-fee timelock **3 days**, force-deallocate penalty 1e13 (0.001%) |
| `allowVault_rejectsSteakhouse` | Steakhouse Prime USDC fails the real check with `VaultCheckFailed(setIsAllocator)`: its allocator timelock is 0 |
| `allowVault_rejectsShortenedAllocatorTimelock` | The curator submits `decreaseTimelock(setIsAllocator, 1 day)` and executes it after 7 days; a new `allowVault(Gauntlet)` then fails |
| `previewRedeemDrift_andFullLifecycle` | NAV drifts by +$6.07 on $3,000 over 15 days. `previewRedeem` == `redeem` within one block. `max*` is 0 while the circle holds shares. A full lifecycle pays every member principal plus earnings; the fee is ≤ 10% of earnings; the circle ends empty |
| `illiquidity_chunkedExit_inKindSettlement` | The liquidity market (cbBTC/USDC 86%) is borrowed out with dealt cbBTC; the vault holds no idle USDC. `settleMember` and a one-shot `emergencyExit(max)` revert; `emergencyExit(0)` switches yield off; a member settles in kind (fee shares to the treasury). A partial repay lets anyone `pullFromVault` a bounded chunk and the next member settles in cash. After a full repay, the last one settles in cash and the in-kind member redeems its shares directly |
| `curatorPerformanceFeeChange` | The curator submits `setPerformanceFee(25%)`; anyone executes it after 3 days. Over 30 days NAV is $2,006.41 against $2,008.28 without the fee. Principal stays intact and members still get at least principal |
| `usdcBlacklistAndPause` | Pranking Circle's real `pauser` and `blacklister`: `finalize` reverts `UsdcPaused`. While paused, a cash settlement reverts (the vault withdraw moves USDC) and an in-kind settlement works. A blacklisted member's payout is queued (`PayoutQueued`), `claimOwed` reverts until the blacklist is lifted, then pays it |
| `rotating_realUsdc_blacklistedRecipient` | Real USDC rotating circle (n = 3, fee 2%). Round 1's recipient is blacklisted, so its payout is queued; the circle completes; every member nets exactly −$6 and the treasury gets $18 |

- **Gas snapshots** (`snapshots/circles-fork.json`, real Gauntlet, cold):

| Call | Gas |
|---|---|
| `accumulation.contribute` | 131,497 |
| `accumulation.deployIdle` | 383,570 |
| `accumulation.finalize` | 278,868 |
| `accumulation.settleMember` (with vault withdraw) | 493,983 |
| `accumulation.settleMemberInKind` | 291,122 |
| `accumulation.emergencyExit(0)` | 39,574 |
| `accumulation.pullFromVault` | 356,166 |
| `claimOwed` | 66,884 |
| `rotating.contribute` | 173,849 |
| `rotating.settleRound` | 134,500 |
| `rotating.settleRound` (payout queued) | 173,343 |

### R8 boundary-gas test (`BoundaryGas.sol`)
- **Method.** For each call that succeeds with unlimited gas:
  1. the harness binary-searches the exact minimum gas limit;
  2. it then tries every limit in a ±128 window around it and a sweep every 499 gas from 21,000 to the minimum + 40,000.
- **Assertion.** Every attempt either reverts with the probed state unchanged, or succeeds with exactly the unconstrained end state. The probe covers every bucket, every member's state, `owed`, balances, strikes and pots. No gas limit may produce a third outcome, such as a skipped strike, a queued instead of a sent payout, or a partial unwind. That is the 63/64-rule griefing R8 is about.
- **Scope:** all 15 rotating and 18 accumulation state-changing functions, each in its most interesting state (cover + strike + payout, a queued payout, an unwind with strikes, vault withdraws, cap + forfeit, in kind with fee, chunked exits, and so on), plus `createRotating`, `createAccumulation` (n = 8) and `canceller.cancel`.
- **Result:** all pass. Minimum gas limits range from 6,447 (`cancelUnjoined` on an accumulation circle) to 193,680 (`cancelStalled`, n = 4); the creates take 0.68M at n = 8.

### Cold gas bounds at n = 50 (spec §4.7 invariant 8; `MHGasBounds.t.sol`, isolated)

| Function, worst case | Gas |
|---|---|
| Rotating `cancelStalled`: 50 DEFAULT strikes, 50 claims, 49 non-empty pots, called at round 50 | **4,719,320** (before the fix: 4,960,889 of execution, about 4.99M with transaction overhead) |
| Rotating `settleRound`: 49 covers + 49 strikes | 4,466,152 |
| Accumulation `flagRound`: 50 MISSED strikes | 3,995,465 |
| Accumulation `finalize`: 49 caps | 831,710 |
| Accumulation `guardianCancel` | 562,266 |
| `createRotating` / `createAccumulation`, n = 50 | 2,658,761 / 2,608,815 |

### Fixes (with regression tests)
1. **Rotating `cancelStalled` was within about 15k gas of the 5M bound.**
   - Found by: this step's worst-case search. The step-3 isolated measurement (4.83M) had only one non-empty pot. The true worst case has every opened round pre-paid, which is allowed because members can pay any opened round. That costs 4,960,889 of execution, roughly 4.99M as a transaction.
   - Fix: `_unwind` no longer zeroes the per-round pots. The unsettled pot money was already folded into `assets` through `potTotal`. The mapping is now private (`_pot`), and `pot(round)` is an explicit view that returns 0 once Cancelled, so every reader (the indexer, `_assertBuckets`, the invariant) still sees Σpot == potTotal == 0.
   - New worst case: 4,719,320. Runtime size went from 16,682 to 16,622 bytes.
   - Regression: `test_gas_n50_cancelStalled_everyPotFull_cold`, which also checks that pots read 0 and claims pay out.
2. **Slither `shadowing-local` (Low).** In `IMHAccumulationCircle`, the `claimInKind` return name and the `pullFromVault` parameter shadowed the `vaultShares()` getter. They are renamed to `vShares` and `maxVaultShares`. Names do not affect selectors or the ABI encoding.

The invariant, fuzz, fork and boundary suites found **no correctness defect** in the circle contracts.

### Deviations and resolved ambiguities
1. **Invariant 4 wording.** "USDC leaves only to members" is checked as members and the treasury, plus the allowlisted vault itself for `deployIdle` deposits. Vault shares may also be burned on redeem. The treasury categories are enforced exactly: fees (Completed only, rotating; maturity only, accumulation), residual and donations.
2. **Invariant 5 "honest member" at σ = 100%** means "not struck DEFAULT". Late and covered members are honest; a covered member's own security paid its round. For σ < 100%, where honest members can lose by design (D2/D4), the suites assert the credit bound instead.
3. **Invariant 6 "compliant ≥ delinquent per dollar" only holds when the share price never falls.**
   - Counterexample under path-dependent losses: share price 2, 1, 1 over three rounds, with the delinquent member skipping round 1. The compliant member's value per dollar is 0.83; the delinquent's is 1.0, which is not capped because it is not above principal.
   - This follows from share accounting and the spec's own rules, not from the code. The suites assert it when no loss or preview discount occurred (yield only, or a uniform move after the last contribution, as in the existing step-3 fuzz).
   - The spec wording should say "for a non-decreasing share price".
4. **Everyone exits early.** The exits' forfeited yield has no remaining member to go to, so it becomes residual for the treasury (step-3 deviation 10). The path fuzz allows it, and only it, beyond rounding dust.
5. **Tokens other than USDC and the circle's own vault shares** sent to a circle are stuck by design, because there is no rescue function, which would be an admin path. The invariant handler only donates vault shares to circles that use that vault.
6. **Gas bound reading.** "At most 5M gas" is measured as the cold execution gas of the call, before refunds, without the 21k intrinsic cost. The worst case now has about 280k headroom.
7. **Fork test details.**
   - USDC and cbBTC are funded with forge-std `deal`.
   - Illiquidity is simulated by borrowing out the vault's liquidity market, as the circle brief suggests.
   - Morpho Blue's address (not in Appendix A) is taken from the Gauntlet liquidity adapter's `morpho()`. The vendored test interfaces copy their signatures from morpho-org/vault-v2 @ `abaae813` and morpho-blue `IMorpho.sol`.
8. **7702 member** ([VERIFY forge-std `signDelegation`] resolved). forge 1.7.1 provides `signAndAttachDelegation` and `setEvmVersion`; forge-std v1.9.4 does not declare them, so `Mock7702.sol` declares them locally. The test switches the EVM to Prague at runtime, while the build stays `cancun`.
9. **Not done in this step:**
   - the TypeScript-port diff (no TS circle math exists yet; A11);
   - Aderyn and Halmos, which are not installed here;
   - the ≥80% mutation-score run. Steps 2–3 ran hand-written mutants; `slither-mutate` is available for C6/CI.

### Slither (0.11.6) on `src/circles`
`slither src/circles` was run twice:
- with the repo's `slither.config.json` (which excludes `timestamp` and `naming-convention`);
- with every detector enabled.

Both runs give the same 44 results: **0 High, 22 Medium, 19 Low, 3 Informational**. Before this step there were 46; the 2 `shadowing-local` Lows were fixed above. No finding is silenced in code; the triage is below.

| Impact | Detector (count) | Where | Triage |
|---|---|---|---|
| Medium | `incorrect-equality` (7) | `_nav` (`held == 0`), `_pay` (`x == 0`), both `currentRound` (`start == 0`), both `roundDeadline` (`startTime == 0`), accumulation `sweepDonations` (`assets == 0 && shares == 0`) | **False positive.** Each is a zero-sentinel check on a tracked counter or on config, not an equality on a manipulable balance. In `sweepDonations` the zero check only decides `NothingToClaim`; a donor making it non-zero is the function's purpose |
| Medium | `uninitialized-local` (14) | Accumulators and bitmaps in `finalize`, `flagRound`, `guardianCancel`, `settleMemberInKind`, `sweepDonations`, `cancelStalled` and `_unwind` | **False positive.** Solidity zero-initialises locals, and every one is meant to start at 0 |
| Medium | `unused-return` (1) | `MHCircleBase._strike` ignores `REPUTATION.record`'s bool | **By design.** `false` means a duplicate strike, or a mismatched circle that is ignored; the circle has nothing to do differently. Reputation never reverts for a registered reporter, and every clone is registered before `initialize` |
| Low | `calls-loop` (3) | `_strike` inside `flagRound`, `settleRound` (covers) and `cancelStalled` (defaults) | **Accepted.** The callee is the immutable, trusted `MHReputation`; loops are at most 50 iterations; worst cases are measured cold under 5M (table above); R8 boundary tests show no partial outcome at any gas limit |
| Low | `missing-zero-check` (7) | Registry constructor and the three setters; canceller `wrapper` | **False positive / by design.** Registry roles are checked in the private `_checkRoles` (`ZeroAddress`, `RoleCollision`), which Slither does not follow. The canceller's `WRAPPER` may be zero by design (step-1 deviation 6) |
| Low | `reentrancy-benign` (9) | State written after calls to the allowlisted vault (`deployIdle`, `_takeIdle`, `_redeem`, and through them `exitEarly`, `claim`, `settleMember`); `settleRound`'s `_pay` after strikes; the factory's `isCircle` after `initialize` | **Accepted.** The writes need the call's return value (shares minted or burned, assets redeemed), or are in the spec-mandated order (factory). Every state-changing entry point is `nonReentrant` (transient guard), and neither USDC, Vault V2 nor Reputation calls back into a circle. Residual risk is limited to read-only views observed by a third party during a vault call (for example `nav()` while `idleAssets` is already decremented). Only a curator-added adapter could do that, behind a 7-day timelock, and it cannot affect circle state |
| Info | `cyclomatic-complexity` (2) | `finalize` (12), `_unwind` (15) | Accepted; fully covered by unit, fuzz and invariant tests |
| Info | `unimplemented-functions` (1) | `MHReputation.struck` / `strikesByReason` | **False positive.** They are implemented by public mapping getters (enum-keyed), which Slither misreads; the tests call both |

CI's `crytic/slither-action` uses `fail-on: high`, so these do not fail the job; the SARIF upload will list them as open alerts until they are dismissed with the reasons above.

### Results
- `forge build`: OK.
- `forge test` (default profile): **294 passed, 0 failed, 1 skipped**. The skipped entry is the fork suite, which skips in `setUp` without `BASE_RPC_URL`; with it set, all **8 fork tests pass**.

  | Suite | Tests |
  |---|---|
  | Rotating unit / scenarios / fuzz | 60 / 17 / 1 |
  | Accumulation unit / scenarios / fuzz | 48 / 15 / 1 |
  | Invariant: rotating / accumulation | 1 / 1 (each with its `afterInvariant` liveness drive) |
  | R8 boundary gas: rotating / accumulation / factory + canceller | 15 / 18 / 4 |
  | Cold gas bounds: rotating / accumulation | 2 / 3 |
  | EIP-7702 member: rotating / accumulation | 1 / 1 |
  | Registry / Factory / Canceller / Reputation / Base | 28 / 24 / 22 / 17 / 15 |
  | Base fork (`BASE_RPC_URL` set) | 8 |

  `FOUNDRY_PROFILE=ci` (1,000 fuzz runs) passes for every non-invariant suite: 292 passed, 1 skipped. Both invariant suites pass at the CI profile (10,000 runs × depth 200, 2M calls each).
- `forge fmt --check` and `forge lint` are clean. No try/catch, `tx.origin`, code-size check, `receive`/`fallback` or low-level call appears in `src`. The low-level calls in `test/` are harness code.
- `forge build --sizes`: `MHRotatingCircle` 16,622 / 17,204 B (was 16,682 / 17,264). The others are unchanged (`MHAccumulationCircle` 20,295 / 20,919; factory 3,651; canceller 3,348; registry 3,192; reputation 1,856).

### Open questions (step 4)
1. **CI must opt in to the CI profile.** `contracts-ci.yml` runs plain `forge test`, so it uses the default (32 × 100) invariant profile and skips the fork suite.
   - The invariant suites at the CI profile take about an hour each on one core.
   - Recommendation for C6: a job, or a nightly, with `FOUNDRY_PROFILE=ci forge test --match-path 'test/circles/invariant/*'`.
   - Also a fork job with an archive `BASE_RPC_URL` secret, and `forge build --sizes`.
   - The workflow was not touched here.
2. **Invariant 6 wording:** confirm "per dollar" fairness is only promised for a non-decreasing share price (deviation 3).
3. **Everyone exits early:** confirm the forfeited yield should go to the treasury rather than, for example, back to the exiters pro rata (deviation 4).
4. **Vault monitors, at the pinned block.**
   - Gauntlet's performance fee is timelocked only 3 days, and its force-deallocate penalty 1 day.
   - Steakhouse Prime fails `allowVault` (allocator timelock 0), so only Gauntlet qualifies today.
5. **Reputation packing** (step-2 open question 5) is still recommended for more headroom: rotating `settleRound` is 4.47M cold at n = 50, and `cancelStalled` 4.72M.
6. **`snapshots/circles-fork.json`** is produced by the fork run; decide whether to commit it as the gas baseline (C6).

---

## Step 5: C6 deployment tooling, VerifyBase, fork rehearsal, CI pinning (2026-10-22)

### What was done
- **`script/BuildBaseBatch.s.sol`** builds the spec §5 ceremony. It never broadcasts: there is no `vm.broadcast` anywhere, and the script reverts `NeverBroadcast()` under `forge script --broadcast` or `--resume`.
  - It reads every input from the environment with no defaults (README §Inputs) and validates them against the live chain (see "Checks" below).
  - It plans CreateX `deployCreate3` deployments with guarded salts `GovSafe ‖ 0x01 ‖ 11 bytes` and builds the two Gov Safe batches (MultiSendCallOnly DELEGATECALL) and their EIP-712 hashes.
  - It simulates both batches through the **real** Gov Safe: pranked `approveHash` by `threshold` owners, then `execTransaction`, with every touched account cooled first. It reads runtime codehashes and gas, and simulates the allowVault proposal through the Timelock. All of that is reverted with `snapshotState`/`revertToState`.
  - It writes to `deployments/<network>/`:
    - `manifest.json`;
    - `batch1-implementations.safe.json` and `batch2-governance.safe.json`;
    - `proposal-allow-vault.{schedule,execute}.safe.json`, when a circle vault is set.
- **`script/VerifyBase.s.sol`** is read-only and asserts every spec §5 item except Sourcify, which needs HTTP; that check is `script/check-sourcify.sh`. Details are under "VerifyBase" below.
- **`script/ceremony/`** holds the shared code:
  - `BaseChain.sol`: pinned addresses and codehashes, Safe storage slots and typehashes, ceremony bounds;
  - `DeployInterfaces.sol`: Safe v1.4.1, SafeProxyFactory, MultiSendCallOnly and CreateX subsets, signatures copied from the sources;
  - `MHDeployPlan.sol`: a pure planner;
  - `MHDeployJson.sol`: a deterministic JSON writer, including the Transaction Builder checksum.

  The directory was first called `script/lib/`. The existing `contracts/.gitignore` rule `lib/` matches any `lib` directory, so git silently ignored it; it was renamed.
- **Shell helpers** (read-only, no keys):
  - `script/check-manifest-bytecode.sh` is offline. It checks the local build against a manifest's creation-code and initcode hashes.
  - `script/check-sourcify.sh` queries the Sourcify v2 API and requires `runtimeMatch == "exact_match"` for all seven contracts.
- **Tests:**
  - `test/fork/SafeDeployRehearsal.t.sol`: 35 fork tests (see below).
  - `test/script/MHDeployPlan.t.sol`: 11 offline planner and JSON tests, which run in every CI job.
- **Config:**
  - `foundry.toml`: `auto_detect_remappings = false` with the two explicit remappings (see deviation 9).
  - `.gitattributes`: `*.sol` and `*.json` are checked out LF.
  - `.gitignore`: `deployments/rehearsal/` (fork-rehearsal output).
- **Docs:**
  - `README.md` is rewritten: layout, setup, tests, fork tests, and the ceremony (inputs, outputs, runbook).
  - `DEPLOYMENT.md`: the retired banner now points to it.
- **CI** (`.github/workflows/contracts-ci.yml`): see "CI" below.

### The plan (what the Gov Safe signs)
- **Batch 1** (nonce N): `CreateX.deployCreate3(salt, initcode)` for `MHRotatingCircle`, then for `MHAccumulationCircle`. Constructor arguments are `(USDC, predicted registry, predicted reputation)`.
- **Batch 2** (nonce N+1), in the spec §5 order:
  1. `TimelockController(delay, [Gov], [Gov], Gov)`;
  2. `MHGuardianCanceller(timelock, registry, EARN_WRAPPER, GuardianSafe)`;
  3. `timelock.grantRole(CANCELLER_ROLE, canceller)`;
  4. `MHCircleRegistry(timelock, USDC, OPERATOR, GuardianSafe, TreasurySafe)`;
  5. `MHReputation(timelock, predicted factory)`;
  6. `MHCircleFactory(registry, reputation, rotImpl, accImpl)`;
  7. `timelock.renounceRole(DEFAULT_ADMIN_ROLE, Gov)`.

  Every address is predicted locally (Solady/CreateX CREATE3 formula) and cross-checked against `CreateX.computeCreate3Address` on chain.
- **Each batch** is one Safe transaction:
  - `to` = MultiSendCallOnly `0x9641…02e2`, `operation` = 1, value 0;
  - `safeTxGas`, `baseGas` and `gasPrice` 0; no gas token or refund receiver.

  The manifest records the domain hash, the message hash and the `safeTxHash`. The script checks them against the Gov Safe's own `getTransactionHash` and `domainSeparator`.
- **Gas.** The 10M budget holds for both batches:

  | | Simulated (cold) | Executed on an anvil fork (receipt) |
  |---|---|---|
  | Batch 1 | 8,727,447 | 8,734,947 |
  | Batch 2 | 5,132,179 | 5,124,779 |

  - The two columns agree within 0.15%, so the script refuses a batch whose simulated gas plus 1% exceeds 10M.
  - Batch 1 has about 1.27M of headroom. If `MHAccumulationCircle` grows by more than about 6 KB of runtime, the implementations must be split into two Safe transactions.
  - Gas is measured with `vm.lastCallGas().gasTotalUsed`, the Safe's frame only. The intrinsic cost is added as max(EIP-2028 calldata, EIP-7623 floor).
  - Measuring with `gasleft()` around the call was about 1–2% off: it counted the caller's ABI encoding and memory.

### Checks in `BuildBaseBatch.validate`
- **Chain and pinned contracts:**
  - the chain is 8453 or 84532;
  - `USDC` is that chain's canonical address, with its pinned proxy codehash and `decimals() == 6`, and `isBlacklisted`/`paused` respond;
  - CreateX, SafeL2, SafeProxyFactory, MultiSendCallOnly and CompatibilityFallbackHandler match their pinned codehashes.
- **Roles:**
  - each role is non-zero;
  - roles are pairwise distinct (Gov, Guardian, Treasury, operator, plus the vault and wrapper when set);
  - no role equals `msg.sender`.
- **Each Safe:**
  - has code, the pinned SafeProxy codehash, and singleton (slot 0) SafeL2 v1.4.1;
  - has exactly the expected threshold and owner set; the expected list may not contain zero, the sentinel or duplicates;
  - satisfies threshold ≥ 2 and threshold < owners;
  - has no module (`getModulesPaginated`), no guard (guard slot) and the 1.4.1 fallback handler (fallback slot).
- **Keys:**
  - Gov and Guardian owner sets are disjoint;
  - the operator owns no Safe.
- **Vault and wrapper:**
  - `CIRCLE_VAULT`, when set, has code, `asset() == USDC` and passes the same gate and timelock checks as `registry.allowVault`;
  - `EARN_WRAPPER`, when set, has code and `asset() == USDC`.
- **Parameters:**
  - fees are at most 200 and 1,500 bps;
  - the delay is between 48h and 7 days;
  - the salt seed is non-zero;
  - the commit is 40 lowercase hex characters;
  - `GOV_SAFE_NONCE` ≥ the Safe's current nonce.
- **Plan** (`checkPlan`):
  - every predicted address is free;
  - every initcode is at most 49,152 bytes;
  - the simulation checks every runtime is at most 24,576 bytes and that the deployed state matches (roles, delay, links).

### VerifyBase
`run()` needs `MANIFEST_PATH`, `DEPLOY_EOAS` and `BATCH2_BLOCK`; `verify()` also takes role events directly, which the fork test uses. It asserts:
- **Codehashes:** the pinned external codehashes, and every deployed contract's runtime codehash equal to the manifest's, which comes from the build simulation.
- **Timelock roles:**
  - `getMinDelay()` equals the manifest delay;
  - every `RoleGranted`/`RoleRevoked` the Timelock emitted, from `BATCH2_BLOCK` to the head (`vm.eth_getLogs`, 5,000-block chunks), is replayed;
  - the surviving set must be exactly {(admin, Timelock), (proposer, Gov), (executor, Gov), (canceller, Gov), (canceller, MHGuardianCanceller)}, each confirmed live with `hasRole`;
  - a `hasRole` matrix over every known address must match: address(0) (an open role), the Safes, every Safe owner, the operator, all seven contracts and CreateX.
- **Ownership and links:**
  - Registry and Reputation have `owner() == Timelock` and `pendingOwner() == 0`;
  - registry `USDC`, operator, guardian and treasury;
  - `reputation.FACTORY() == factory`;
  - the factory's four immutables;
  - the canceller's `TIMELOCK`, `REGISTRY`, `WRAPPER` and `guardian()`;
  - each implementation's mode, `USDC`, `REGISTRY` and `REPUTATION`.
- **Implementations cannot be initialized:**
  - `initialize` reverts with exactly `InvalidInitialization()` (by staticcall: an initializable implementation would hit a static-context violation and fail the check);
  - the OZ `Initializable` ERC-7201 slot is `type(uint64).max`.
- **Deployment EOAs:** no `DEPLOY_EOAS` entry holds a Timelock role, owns or is pending owner of Registry or Reputation, is operator, guardian or treasury, is the canceller guardian, or is one of the Safes.
- **Safes:** canonical proxy codehash, the SafeL2 v1.4.1 singleton, the manifest's owners and threshold, no modules, no guard, and the 1.4.1 fallback handler.
- **Mutable state is logged, not asserted:** `creationPaused` and `isAllowedVault(circleVault)` change legitimately after deployment.

### Fork rehearsal (`test/fork/SafeDeployRehearsal.t.sol`, 35 tests; skips without `BASE_RPC_URL`)
- **Setup:** at block 52,933,005 it deploys three real Safes from the canonical SafeProxyFactory with test owners: Gov 3-of-5, Guardian 2-of-4, Treasury 2-of-3.
- **Appendix A:** all nine addresses have code; the codehashes match the pins; a fresh proxy has the pinned SafeProxy codehash; the local CREATE3 formula equals CreateX's.
- **Full ceremony:**
  - build → read the Transaction Builder files back → rebuild the MultiSend payload → execute batch 1 and batch 2 through the Gov Safe (pranked `approveHash`, type-1 signatures sorted by owner, executed by a non-owner EOA);
  - the clock is unchanged by the build's simulation;
  - the simulated gas is an upper bound on executed gas and within 1% of it;
  - sizes are within limits and codehashes match the plan;
  - `VerifyBase.verify` passes with role events from `vm.recordLogs`.
- **Files:**
  - the manifest and all four batch files are byte-identical across two independent builds;
  - manifest fields equal the plan, and the salt layout is checked;
  - batch file → MultiSend payload → the Safe's own `getTransactionHash` equals the manifest.
- **Smoke tests:**
  - the allowVault proposal files go through the Timelock; execution reverts one second early and succeeds at the delay; Gauntlet ends up allowlisted;
  - the Guardian cancels Gov's `setTreasury` through `MHGuardianCanceller` from the Guardian Safe, but cannot cancel Gov's `registry.setGuardian` rotation;
  - a Guardian `pauseCreation` blocks the operator, and the Guardian cannot unpause;
  - a rotating circle runs to completion on real USDC; at fee 0 every member is made whole and the circle ends empty;
  - an accumulation circle's contributions are deposited into Gauntlet.
- **Refusals:** every `BuildBaseBatch` refusal listed above has a test. `checkPlan`'s `AddressInUse` is tested after batch 1 really executes. There are also a future-nonce build and a no-vault build with a wrapper set.
- **VerifyBase tamper cases:**
  - a wrong runtime codehash;
  - a deployment EOA that holds a role (the operator);
  - an extra Timelock proposer, detected by the log replay, and an extra executor on a known address, detected by the `hasRole` matrix;
  - a pending registry owner;
  - a Guardian Safe module;
  - missing role logs;
  - an implementation whose `Initializable` slot was cleared.
- **Environment test:** `test_env_loadConfigAndRun` is the only test that writes the environment. It checks an env round-trip, a full `run()` through `DEPLOY_OUT_DIR`, and that an emptied variable reverts. Every other test passes a config struct, so parallel tests cannot race on process environment.

### End-to-end run of the real scripts (local anvil fork, nothing sent to any public network)
A driver outside the repo (`scratchpad/c6-tools/anvil_rehearsal.sh`) ran the following against `anvil --fork-url https://mainnet.base.org --fork-block-number 52933005`:
1. Created the three Safes with anvil accounts.
2. Ran `forge script script/BuildBaseBatch.s.sol --rpc-url <anvil>`, which succeeded.
3. Ran the same with `--broadcast`, which reverted with `NeverBroadcast()`.
4. Executed both batch files with `cast` (`approveHash` from 3 owners, then `execTransaction`); both returned status 1, with the gas above.
5. Ran `forge script script/VerifyBase.s.sol` with `BATCH2_BLOCK`. It passed, which exercises the real `eth_getLogs` path.
6. Executed the allowVault schedule, advanced the clock 48h, then executed; `isAllowedVault(Gauntlet)` is true.
7. Re-ran VerifyBase with the operator in `DEPLOY_EOAS`. It failed with `VerifyFailed("deploy EOA holds a registry role")`.
8. Ran `check-manifest-bytecode.sh` on the fresh manifest: all seven OK. The stale manifest from before the remapping change fails all seven.
9. Ran `check-sourcify.sh`: it reports FAIL for unpublished addresses and for a `match` that is not exact (CreateX on Base).

### CI (`.github/workflows/contracts-ci.yml`)
- **Pins:**
  - Foundry `v1.7.1`, with the job asserting forge's commit `4072e487…`;
  - OpenZeppelin `69c8def5…` (v5.1.0) and forge-std `1eea5bae…` (v1.9.4), fetched by commit with `HEAD` asserted;
  - every action by commit SHA: checkout v7.0.1, foundry-toolchain v1.9.2, setup-python v7.1.0, codeql upload-sarif v4.39.1;
  - Slither 0.11.6 and crytic-compile 0.4.2 through pip. This replaces `slither-action`, whose Docker image installs unpinned tools.
- **Jobs:**
  - **`build-test`:**
    - `forge build --sizes`, which exits non-zero on EIP-170;
    - an explicit jq gate on `runtime_margin < 0 || init_margin < 0`, so initcode over EIP-3860 also fails;
    - `forge test`;
    - `check-manifest-bytecode.sh` on any committed `deployments/base-{mainnet,sepolia}/manifest.json`;
    - `forge fmt --check`, still informational as before.
  - **`ci-profile`**, a matrix with `FOUNDRY_PROFILE=ci` and a 180-minute timeout: the rotating invariants (10,000 × 200), the accumulation invariants (10,000 × 200), and every other suite at 1,000 fuzz runs.
  - **`fork`:** `forge test --match-path "test/fork/*"` with the `BASE_RPC_URL` secret. It warns instead when the secret is absent, as on PRs from forks.
  - **`slither`:** `forge build --build-info`, then `slither . --ignore-compile --fail-high --sarif`, then a SARIF upload.
- **Triggers:** PRs and pushes to `main` that touch `contracts/`, a nightly cron and manual dispatch.

### Deviations and resolved ambiguities
1. **CREATE3, not CREATE2.** The spec (`deployCreate3`) wins over the multisig brief (CREATE2, "the address is the bytecode checksum"). Under CREATE3 an address commits only to the Gov Safe, the chain and the salt, so bytecode integrity is checked separately:
   - the manifest's `creationCodeHash`, `initCodeHash` and `dataHash` (what signers compare against the calldata);
   - `runtimeCodeHash`, asserted by VerifyBase;
   - `check-manifest-bytecode.sh`.
2. **Salt entropy comes from one seed.** "11 random bytes … supplied via env" is implemented as one `CREATE3_SALT_SEED` (32 random bytes). Each contract's 11 bytes are `bytes11(keccak256(abi.encode(seed, label)))`. This is reproducible from a single value, and guarded salts are sender- and chain-bound, so the entropy only needs to be unique.
3. **Two fee inputs.** The spec says "the fee" and the brief `FEE_BPS ≤ 200`. The circles have two caps (200 bps rotating, 1,500 bps accumulation), so there are `ROTATING_FEE_BPS` and `ACCUMULATION_FEE_BPS`.
   - Fees are per circle and set by the operator, so these values are recorded in the manifest as launch policy and not deployed.
   - A non-zero value prints a decision-13 warning.
4. **The vault and the wrapper may be explicitly zero.** Both variables must be present, so there is still no default.
   - `CIRCLE_VAULT = 0` means no allowVault proposal. This matches "no-yield circles first", and is required for the Sepolia rehearsal, which has no Vault V2 on Sepolia USDC.
   - `EARN_WRAPPER = 0` keeps step-1 deviation 6.
5. **The vault is used through extra output files.** The spec's two batches cannot allowlist a vault, because `allowVault` is Timelock-only. So the script also writes the schedule and execute Transaction Builder files and records the Timelock operation id. The salt is `keccak256(abi.encode(keccak256("moolahub.circles.allowVault"), vault, seed))`. These are single calls, which Safe{Wallet} sends as a direct CALL, so the manifest has no `safeTxHash` for them (their nonce is not known in advance).
6. **Stricter than the spec.** The script adds checks the spec does not list:
   - Safe policy: threshold ≥ 2 and < owners (spec: "at minimum 2-of-3");
   - Gov and Guardian keys disjoint (spec: "Guardian 2-of-4 on separate keys");
   - the operator owns no Safe;
   - a pinned Safe singleton, proxy codehash and fallback handler;
   - the vault passes every `allowVault` check up front (spec: "non-USDC vault"), so a proposal cannot fail 48h later;
   - the delay between 48h and 7 days;
   - the commit format;
   - an unused nonce and free addresses.
7. **"Role equal to the sender" compares against `msg.sender` only.** The brief also lists `tx.origin`; it is left out so that no `tx.origin` appears anywhere. In `forge script` they are the same address (`--sender`), and VerifyBase's `DEPLOY_EOAS` covers every deployment EOA after the fact.
8. **Transaction Builder format.**
   - Files use format `1.0`, with `createdAt: 0` so they are reproducible.
   - `txBuilderVersion` is "1.19.0" (safe-react-apps `main`).
   - Raw `data` transactions only.
   - A real `meta.checksum`, reimplementing `serializeJSONObject` and keccak256. It was checked with an independent Python port that reproduces tx-builder's own test vector `0x4ecbfd36…db64c`, and every generated file validates, so import shows no "modified file" warning.
9. **Reproducible bytecode.** `auto_detect_remappings = false`. Auto-detection had added `openzeppelin-contracts/=lib/openzeppelin-contracts/` to every contract's solc metadata, and a checkout with OZ's own submodules populated would add more, changing every initcode hash between signers.
   - This changes the CBOR metadata hash of every artifact against step 4. Sizes, behaviour and gas are unchanged. No manifest existed yet.
   - forge's cache did **not** pick up the remapping change until `forge clean`, so the runbook says `forge clean` first.
   - `.gitattributes` forces LF, because CRLF would change the source hashes in the metadata.
10. **Sourcify is a shell script** (`check-sourcify.sh`). Forge cannot make HTTP requests without `ffi`, which stays off. Runtime `exact_match` is required. `creationMatch` is only reported, because Sourcify may not locate the creation transaction of a CREATE3 deployment.
11. **External codehash pins.** Safe codehashes equal safe-deployments' published `codeHash` (canonical), and CreateX's equals its README value. All are identical on 8453 and 84532. For USDC only the FiatTokenProxy codehash is pinned: Circle can upgrade the implementation, but the proxy code never changes. The SafeProxy runtime codehash was computed with `cast call --create` and confirmed against a live proxy on the fork.
12. **Simulation details.**
    - When `GOV_SAFE_NONCE` is above the Safe's nonce (pending transactions), the simulation stores the nonce, so the hashes are the ones that will be signed.
    - Simulated execution uses a fixed stand-in executor.
    - Accounts are cooled with forge's `cool` cheatcode (forge ≥ 1.0), declared locally as `IVmCool` because forge-std v1.9.4 lacks it.
13. **Test contracts can exceed EIP-170.** forge test does not enforce code-size limits, so the rehearsal asserts runtime and initcode sizes explicitly, and the build script reverts on them. `forge build --sizes` excludes Script contracts, which embed every creation code.

### Results
- `forge build`: OK.
- `forge build --sizes`: unchanged from step 4.

  | Contract | Runtime (B) | Initcode (B) |
  |---|---|---|
  | MHAccumulationCircle | 20,295 | 20,919 |
  | MHRotatingCircle | 16,622 | 17,204 |
  | TimelockController (OZ) | 6,550 | 7,468 |
  | MHCircleFactory | 3,651 | 4,940 |
  | MHGuardianCanceller | 3,348 | 3,758 |
  | MHCircleRegistry | 3,192 | 4,030 |
  | MHReputation | 1,856 | 2,229 |

  Initcode with constructor arguments, as deployed, is at most 21,015 bytes (accumulation).
- `forge test` (default profile): **305 passed, 0 failed, 2 skipped**. The 2 skipped are the fork suites; the 11 new offline planner tests account for the increase over step 4.
- `BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"`: **43 passed, 0 failed** (8 circle fork tests + 35 rehearsal tests).
- `FOUNDRY_PROFILE=ci forge test --no-match-path "test/circles/invariant/*"`: **303 passed, 0 failed, 2 skipped**. The 10,000 × 200 invariant runs were not repeated in this step: `src/` is unchanged apart from the metadata hash, and step 4 ran them.
- `forge fmt --check` and `forge lint`: clean.
- Slither 0.11.6 (`--ignore-compile --fail-high`): exit 0; 0 High, 22 Medium, 19 Low, 3 Informational, the same 44 findings as step 4. `script/` and `test/` are filtered by `slither.config.json`.
- No try/catch or `tx.origin` anywhere in `src/` or `script/`.

### Open questions (step 5)
1. **Safe{Wallet} wrapping [VERIFY on the Sepolia rehearsal].** Confirm that the Transaction Builder submits these multi-call batches as a DELEGATECALL to MultiSendCallOnly 1.4.1 at `0x9641…02e2` with `safeTxGas = 0` for a 1.4.1 Safe. If it chooses another MultiSend or non-zero gas fields, the UI's `safeTxHash` will not equal the manifest's, and signers must reject. `safe-cli` with the manifest's exact fields is the fallback.
2. **Seed-derived salt entropy** (deviation 2): confirm, or require per-contract random bytes.
3. **Invariants in CI.** The CI-profile invariant jobs run on every PR, about an hour each in parallel. Keep them, or move them to nightly and `main` only?
4. **`BASE_RPC_URL` secret:** it must serve historical state at block 52,933,005 (archive). `mainnet.base.org` did today; that is not guaranteed.
5. **The Sepolia rehearsal cannot exercise the vault path** (no Vault V2 on Sepolia USDC). The allowVault proposal is rehearsed only on the mainnet fork.
6. **The Timelock delay bound is [48h, 7 days].** The spec's later move to 7 days fits. Confirm that nothing longer is wanted.
7. **Still open from step 1:** whether the Timelock owns the Earn wrapper (`EARN_WRAPPER`, immutable in the canceller). From step 4: whether to commit `snapshots/circles-fork.json`.
8. **Legacy `deployments/*.json`** (Monad and Base Sepolia records of retired contracts) are untouched. New manifests go to `deployments/base-mainnet/` and `deployments/base-sepolia/`.

---

## Round 1 fixes (audit round 1, 2026-10-22)

Scope: the 30 confirmed round-1 findings (R1-01 to R1-33; R1-13 and R1-16 were not confirmed). Every finding with a verifier PoC has that PoC turned into a regression in the real suite; the PoC scenarios are replayed and now assert the fixed outcome (or, for an acknowledged finding, pin the accepted behaviour so any change is deliberate). Nothing is committed. Work stayed inside `contracts/`: the spec (`docs/base-build-spec-v2.md`) and `.github/` were not edited, so every spec change below is recorded here as an amendment for founder sign-off.

### Status by finding

| ID | Sev. | Status | Change | Covered by |
|---|---|---|---|---|
| R1-01 | Medium | **Fixed** | `MHRotatingCircle._unwind` rewritten (`_positions`, `_refund`, `_weights`). At a cancellation, security that backs no debt is refunded at par outside the pool: all of a not-yet-paid-out member's security, and a paid-out member's excess over `ceil(σ·(n − paidRounds)·c)`. Contributions to rounds after the settling round are first returned to the contributor's security, and on a stall a non-defaulter that has not paid the settling round is covered for it (as `settleRound` would). E is computed after the refund. A defaulter's security is not refunded (it is the penalty base, see R1-06). JIT deposits, withdrawals and prepayments by any non-defaulter therefore change nobody else's claim, by a single unit. | `MHAuditRound1Rotating`: `test_R1_01_jitCollateralDuringCure_isRefundedAtPar_othersUnchanged`, `test_R1_01_flashCollateralSameTx_earnsOnlyOwnPosition`, `test_R1_01_sybilPairCannotRecyclePenalty`, `test_R1_01_haircut_independentOfWithdrawOrder`, `test_R1_01_honestFreeCollateralAtJoin_doesNotSkewPenalty`, `test_R1_01_prepaymentBeforeCancel_isRefundedAtPar_othersUnchanged`, `testFuzz_R1_01_jitMovesNoOtherClaim` (1,000 runs in the CI profile) |
| R1-02 | Low | **Fixed** (spec D3 amended) | A paid-out member's position is charged its fee (`E = cashIn − cashOut − refund − fee`). Escrowed fees go back into the pool only up to the creditors' shortfall (the sum of negative positions); the rest stays in `feeEscrow` and `flushFees` now also works once Cancelled. At σ = 100% nobody is short, so every paid-out fee reaches the treasury. The PoC's last-round skip no longer cancels at all: slot n's own part is netted from its payout (R1-07). | `test_R1_02_lastRoundSkip_isNetted_treasuryGetsEveryFee` (n = 6 and n = 20 × $500), `test_R1_02_engineeredStall_paidOutFeesReachTreasury`, `test_R1_02_feesFoldBackOnlyUpToTheShortfall`; updated `test_D3_sigma100_slot5StopsAtRound3`, `test_R1_cancellationUnwindsByNetPosition` |
| R1-03 | Medium | **Fixed** | `guardianCancel` also works while Matured and then applies the finalize outcomes (delinquent members keep their capped shares; exactly the members `settleMember` would pay a bonus get it, from `forfeitSnap`/`bonusBase`; no fee), so `claimInKind` pays idle USDC plus vault shares with no NAV read. `flagRound` reads `_nav()` while Active, so no MISSED strike can be recorded while members cannot pay (the Guardian extends meanwhile). `MockVaultV2` gained a `navBroken` knob (previewRedeem, deposit, withdraw, redeem revert); the invariant handler toggles it (`vaultBreak`) and `afterInvariant` reaches an end state through the NAV-free path. While fixing this, the Matured cancel was found to overwrite `claimTotal` when R1-09 claims already existed; it now adds to it. | `MHAuditRound1Accumulation`: `test_R1_03_maturedBrokenVault_guardianCancelThenClaimInKind`, `test_R1_03_dustShareVariant_idleStillReachable`, `test_R1_03_maturedCancel_keepsFinalizeOutcomes`, `test_R1_03_activeBrokenVault_noStrikesWhileNobodyCanPay`, `test_R1_03_maturedCancel_keepsReturnedForfeitClaims`; fork (real Gauntlet adapter reverting): `test_R1_03_fork_maturedAdapterRevert_guardianCancelPaysInKind`, `test_R1_03_fork_activeOutage_noStrikes`; `invariant_accumulation` |
| R1-04 | Low | **Fixed** (spec §4.3 and Guardian SLA amended) | `allowVault` (and `BuildBaseBatch._checkVault`, same order) now also requires: `removeAdapter` and `setAdapterRegistry` ≥ 7 days or abdicated; an adapter registry set; `increaseAbsoluteCap`, `increaseRelativeCap`, `setPerformanceFee`, `setManagementFee` ≥ 3 days (`MIN_VAULT_EXPOSURE_TIMELOCK`) or abdicated; every adapter's `burnShares` ≥ 3 days or abdicated (at most 16 adapters; an adapter without Morpho's timelock views fails closed). Gauntlet USDC Prime passes (caps and fees are 3 days there); Steakhouse still fails. The real reaction window for the cap path is therefore 3 days, not 7: the Guardian SLA becomes 3 days. Not done: `VaultV2Factory.isVaultV2` provenance (factory address not verified, [VERIFY]), rejecting curator-is-allocator (Gauntlet's curator is an allocator), `setSkimRecipient` (timelock 0 on Gauntlet; `skim` moves only the adapter's own token balance, which holds no depositor USDC). | `test_R1_04_allowVault_rejectsEveryShortCuratorTimelock` (includes the mock PoC's `removeAdapter` = 0), `test_R1_04_allowVault_requiresAnAdapterRegistry`, `test_R1_04_allowVault_checksEveryAdapter`, `test_R1_04_vaultSafe_skipsAdapterWalk`; fork: `test_R1_04_fork_gauntletPassesExtendedChecks`, `test_R1_04_fork_shortenedCapTimelock_unsafeAndDelistable`, `test_R1_04_fork_guardianExitInside3DaysProtectsCircle` (the verifier's junk-market rug, defeated by an exit inside the window) |
| R1-05 | Medium | **Fixed** | New `script/ceremony/MHManifestCheck.sol` + `script/CheckManifest.s.sol` (offline, no RPC). It trusts only the manifest's inputs and the local build: (1) re-applies the policy bounds (delay in [48h, 7d], fee caps, Safe thresholds, distinct roles, no Safe owned by a role, Gov/Guardian keys disjoint, canonical USDC, seed, commit format); (2) re-derives the manifest, both batch files and the proposal files with `MHDeployPlan.plan` and requires byte equality (only runtime codehashes, which need the fork simulation, are copied; VerifyBase checks them on chain); (3) independently of the planner, recomputes every CREATE3 address from its salt, decodes every constructor argument list against the roles, decodes every transaction in the batch files and recomputes the MultiSend data hash, domain, message and `safeTxHash`. `check-manifest-bytecode.sh` now runs it (CI's existing step therefore runs it too) plus the local creation-code comparison. `VerifyBase.run` runs it on `MANIFEST_PATH` first, and `verify` re-applies the policy to the live state (delay bound, Safe threshold policy, disjoint keys). README runbook step 5: reproduce into a separate `DEPLOY_OUT_DIR` and `diff -r`. | `test/script/MHManifestCheck.t.sol`: `test_R1_05_honestCeremonyPasses`, `test_R1_05_tamperA_extraTimelockProposer`, `test_R1_05_tamperB_implementationSubstitution`, `test_R1_05_tamperC_zeroDelayConsistent`, `test_R1_05_handEditedFilesRejected` (tampers A and B are also rejected by the independent layer alone); fork: `test_R1_05_manifestCheck_realBuild_honestPasses_tamperRejected` |
| R1-06 | Info | **Fixed** | `withdrawSecurity`: after `_graceEnd(nextSettle)`, a member that has not paid the settling round cannot take its security below c (paying the round first lifts it). Combined with R1-01 (a defaulter's security stays in the penalty base), the D3 penalty `min(E, c)` is restored. A withdrawal before the grace end is still possible and equivalent to never posting the collateral (accepted: the penalty is proportional to the stake at default). | `test_R1_06_defaulterCannotWithdrawAfterGrace`, `test_R1_06_sigma50_partialWithdrawBlocked`, `test_R1_06_withdrawStillAllowedWhenNotADefaulter` |
| R1-07 | Low | **Fixed** (spec §4.5 `settleRound` amended) | `_collect`: when the round's recipient has not paid and its draw is short, its unpaid part is netted from its payout whenever `n·c − fee − holdback ≥ c − draw`, at any time, with no strike (new event `OwnContributionNetted`); `cancelStalled` no longer counts such a recipient as a defaulter. A recipient with `sec ≥ c` is always nettable (its payout is at least `sec − draw`), so a recipient is never covered or given a COVERED strike any more. Slot 1 at σ = 100% with no collateral and a non-zero fee cannot be netted (its payout `c − fee` is below `c`) and still stalls (documented limit). The misleading test comment is fixed. | `test_R1_07_blacklistedRecipient_isNetted_circleCompletes`, `test_R1_07_slot1_nettedOnlyIfItsPayoutCoversC`, `MHRotatingCircle.t.sol::test_settleRound_recipientsOwnPartIsNetted`; `test_gas_n50_settleRoundWith48CoversAndNetting`, `test_gas_n50_settleRound_48CoversAndNetting_cold` |
| R1-08 | Info | **Acknowledged** | Automatic pause relief (notePause / FLAG_DELAY / reopening flagged rounds) changes timer semantics in both circles and the registry; deferred to a spec decision. The verifier showed `extendDeadline` works while USDC is paused, which removes the race. Runbook: on a USDC `Pause` event (alerted), the Guardian extends every Active circle before the unpause; for a sequencer outage longer than 12h, the same right after it. R1-03's `flagRound` NAV read also blocks strikes during a vault outage. | `MHAuditRound1Governance`: `test_R1_08_pinned_cancelAtUnpauseWithoutGuardian`, `test_R1_08_guardianExtendsWhilePaused_noStall`, `test_R1_08_pinned_flagAtUnpauseWithoutGuardian`, `test_R1_08_guardianExtendsWhilePaused_noRace` |
| R1-09 | Low | **Fixed** | `exitEarly` records each member's forfeited pool shares. When nobody remains at `finalize`, each exited member gets its own forfeited shares back as a claim (`claim`/`claimInKind`), less `floor(forfeited·feeBps/BPS)`, which is paid to the treasury in kind immediately (`FeePaidInKind`). Residual holds rounding dust only. | `test_R1_09_allExit_fee0_yieldBackToMembers`, `test_R1_09_allExit_fee15_onlyTheNormalFee`, `test_R1_09_allExit_postExitYieldAlsoReturned`; `MHAccumulationCircle.t.sol::test_finalize_everyoneExited_returnsForfeits` |
| R1-10 | Low | **Fixed** (deviation 9 amended) | `_value`: when nobody is compliant, the §4.3 fee on `max(0, gross − principal)` is charged (cash and in kind). Skipping the last round no longer beats paying it. | `test_R1_10_universalDelinquency_doesNotWaiveTheFee` (n = 2 and 4, per-round accrual as in the PoC), `test_R1_10_lastMemberStaysDelinquent_paysTheFee`; `test_settleMember_allDelinquent_uncappedFeeOnEarningsSharesExitForfeit` |
| R1-11 | Low | **Fixed** (invariant 6 wording amended) | The delinquent cap is applied once, at `finalize`; `settleMember`/`settleMemberInKind` pay a delinquent `toAssets(retained shares)` with no fee and no second cap, so its principal earns post-maturity yield like every other bucket and nothing reaches residual (`Settlement.leftover` removed). The suites now bound the treasury by the circle's own `feeBps` (not the global cap), bound a delinquent by its principal at the finalize price scaled by the share price since, and compare per-dollar fairness in pool shares (timing-independent). | `test_R1_11_delayedDelinquent_keepsItsPostMaturityYield`, `test_R1_11_fee10_treasuryTakesOnlyFees`; `test_settleMember_delinquentKeepsPostMaturityYield`; `testFuzz_noAdminPathToPrincipal`, `testFuzz_accumulation_paths`, `invariant_accumulation` |
| R1-12 | Info | **Fixed** | Registry: `vaultSafe(v)` = allowlisted and passing every vault-level check live (it skips the adapter walk so it cannot revert on a real Vault V2); permissionless `revalidateVault(v)` delists a vault that fails the full checks. Accumulation `initialize` and the activating `join` use `vaultSafe` (activation switches yield off). Existing deposits remain the Guardian's job (`emergencyExit`), as the verifier noted. | `test_R1_12_weakenedVault_refusedLiveAndDelistable`, `test_R1_12_revalidate_noopWhileSafe`; fork `test_R1_04_fork_shortenedCapTimelock_unsafeAndDelistable` |
| R1-14 | Low | **Fixed** | `_sendShares` queues vault shares for a USDC-blacklisted recipient in `owedShares` (new `claimOwedShares`, reverting `Blacklisted` while still blacklisted); this covers `claimInKind`, `settleMemberInKind`, the treasury fee-share leg and the sweeps. `sweepDonations` counts queued shares as held. | `test_R1_14_settleMemberInKind_queuesSharesForBlacklistedMember`, `test_R1_14_claimInKind_queuesSharesForBlacklistedMember`, `test_R1_14_blacklistedTreasury_feeSharesQueued`; invariant (balance == tracked + queued) |
| R1-15 | Low | **Fixed** | `MHCircleBase._pay` also queues when the circle itself is blacklisted, so in-kind exits complete and deliver the vault shares; the USDC follows once the blacklist is lifted. (A cash settlement that needs a vault withdraw still reverts: the vault cannot send USDC to a blacklisted circle.) | `test_R1_15_selfBlacklist_inKindExitsStillDeliverShares`, `test_R1_15_selfBlacklist_claimInKindWorks` |
| R1-17 | Low | **Fixed** | `BuildBaseBatch.validate`: every owner of the Gov, Guardian and Treasury Safes must be an EOA (no code, or an EIP-7702 delegation designator) and no owner may be a role address (new errors `SafeOwnerNotEoa`, `SafeOwnerIsRole`). `VerifyBase.verify` re-applies the same on the live Safes; `MHManifestCheck` rejects a role as an owner offline. | offline `test_R1_17_safeOwnedByARoleRejected`; fork `test_R1_17_build_rejectsNestedSafeAndContractOwners` (the PoC's nested Gov Safe and helper Safes), `test_R1_17_verify_rejectsContractOwnerAddedLater` |
| R1-18 | Info | **Acknowledged** | The Active-state cancel between maturity and `finalize` stays uncapped because it is the only exit when the vault cannot value shares before `finalize` (R1-03; finalize needs NAV). Once finalized, the Matured cancel applies the finalize outcomes. Runbook: the keeper finalizes promptly; the Guardian cancels after maturity only when `finalize` reverts. | `test_R1_18_pinned_cancelBetweenMaturityAndFinalize`, `test_R1_03_maturedCancel_keepsFinalizeOutcomes` |
| R1-19 | Info | **Acknowledged** | Runbook/tooling: rotation-only operations are scheduled with predecessor 0; monitors alert on a rotation `CallScheduled` with a non-zero predecessor. | `test_R1_19_rotationWithPredecessor_canBeBlocked_usePredecessorZero` |
| R1-20 | Info | **Fixed** | `MHGuardianCanceller.cancel`/`cancelBatch` require the caller to be both the stored Guardian and `REGISTRY.guardian()`. A partial rotation removes the replaced Guardian's veto at once (fails closed until `canceller.setGuardian` lands). No interface or deployment-plan change. | `test_R1_20_partialRotation_oldGuardianLosesVetoAtOnce`; `MHGuardianCanceller.t.sol` (22, unchanged) |
| R1-21 | Info | **Acknowledged** | The 30-day total is the only real bound; the 7-day per-call cap is kept because the spec table states it, and it is documented as not a rate limit. Per-incident budgets belong to the R1-08 decision. | `test_R1_21_pinned_perCallCapIsNotARateLimit` |
| R1-22 | Info | **Acknowledged** | Liveness only; in-kind settlement and claims cover illiquidity (R3 tests). Runbook: when the liquidity market is fully utilised, a keeper holding its own vault shares calls `vault.forceDeallocate(adapter, data, assets, keeper)` (paying the penalty, 0.001% on Gauntlet) to move liquidity to idle before `emergencyExit`/cash settlement. No Guardian helper added. | existing `test_R3_illiquidity_chunkedExit_inKindSettlement`, fork `illiquidity_chunkedExit_inKindSettlement` |
| R1-23 | Info | **Fixed** | `VerifyBase.run` fetches every `CallScheduled` id and every `VaultAllowed` vault since `BATCH2_BLOCK`; `verifyGovernanceQueue` requires each scheduled id to be done or cancelled, except the manifest's allowVault operation, and no vault other than the manifest's to be allowlisted. | fork `test_R1_23_verify_rejectsPendingOperationAndForeignVault` |
| R1-24 | Info | **Fixed** (tooling) | `check-manifest-bytecode.sh --signer` also checks `git rev-parse HEAD == manifest.commit` and a clean work tree; `CheckManifest` prints every `initCodeHash` for comparison with the audit report. | exercised by hand (prints `FAIL checkout is …` on a mismatching or dirty tree) |
| R1-25 | Info | **Acknowledged** | Outside `contracts/` (`.github/workflows/*`). Recommendation stands for the CI owner: assert `forge --version` against `FOUNDRY_COMMIT` in every job, pin every action by SHA, install Slither with `pip install --require-hashes`. | n/a |
| R1-26 | Info | **Acknowledged** | Founder calls: (a) σ < 100% default-after-payout dominance (enforce a uniform σ or a Trusted-tier flag; see R1-30), (b) late-payment griefing (accept or shorten `cure`), (c) the round-1 Guardian-cancel race. No code change. | n/a |
| R1-27 | Info | **Acknowledged** | Founder sign-off pending on the implemented semantics (cover from all security; D4 penalty in E-units; invariant 6 for a non-decreasing price). The R1-01 refunds do not change the D1–D4 numbers except D3, whose amendment is R1-02. | D1–D4 tests unchanged except D3 |
| R1-28 | Info | **Acknowledged** | Deviation 9 (exit forfeits shared by the remaining members when nobody is compliant) is kept; with R1-10 the fee is now charged in that branch. | `test_settleMember_allDelinquent_uncappedFeeOnEarningsSharesExitForfeit` |
| R1-29 | Info | **Acknowledged** | Extension semantics to be written into the spec (reopened rounds, extension after maturity, no LATE strike in accumulation circles, Pending not extendable). Unchanged. | n/a |
| R1-30 | Info | **Acknowledged** | The $25k launch cap, the Trusted-tier σ and slot order stay backend-enforced (step-1 open question 3). An on-chain cap needs a registry value or new implementations and a founder decision. | n/a |
| R1-31 | Info | **Fixed** | Rotating handler: before every `cancelStalled` the defaulter set is predicted from public views only (unpaid, sec < c, recipient not nettable) and compared with the `Defaulted` events (`defaulterMismatches` must be 0); the σ = 100% bounds no longer use event values (a defaulter loses at most c plus its fee). Accumulation handler: `finalize` is checked independently (retained shares, forfeit pool and unchanged residual recomputed before the call); the treasury bound uses the circle's own fee. Re-running the auditor's mutants: mutant 1 (drop the `!_paid` check) now fails the rotating invariant in 200 runs ("DEFAULT strikes differ from the independent prediction"), and mutant 2 (half of the delinquents' excess to residual) fails the accumulation invariant in 256 runs ("finalize forfeit pool != independent sum"). | `invariant_rotating`, `invariant_accumulation` |
| R1-32 | Info | **Fixed** (test gap) / acknowledged (dead conditions) | New test kills mutant R47. `secTotal != 0` / `accTotal != 0` in `sweepResidual` stay as defence in depth (documented). The tool-based mutation campaign, Aderyn, Halmos and the TS-port diff remain open (§4.7 audit-gate items). | `test_R1_32_depositCollateral_revertsOnceEnded` |
| R1-33 | Info | **Fixed** (docs) | See "Corrections to earlier notes" below. | n/a |

### Spec amendments needed (founder sign-off; not edited, outside `contracts/`)
1. **§4.4 Stall (R1-01, R1-06).** "Only security that backs debt still owed joins the recovery pool. On a stall cancellation each non-defaulter's other security (all of it before its payout; above `ceil(σ·(n − paidRounds)·c)` after it), and its contributions to rounds after the stalled round, are refunded at par; a non-defaulter that has not paid the stalled round is covered for it first. A defaulter's security stays in the pool, and after the stalled round's grace a member that has not paid it cannot withdraw security below c."
2. **§4.4 D3 and §4.5 `flushFees` (R1-02).** Replace "fees waived" with "a paid-out member's fee is kept; escrowed fees return to the recovery pool only up to the creditors' shortfall". New D3 numbers (n = 6, c = $100, fee 2%, σ = 100%): pool $1,100; slots 1 and 2 end at −$12 (as on completion), slots 3, 4 and 6 at +$33.33, slot 5 at −$100; the treasury gets $24 + 1 micro-USDC of residual. D2 and D4 are unchanged (everything folds back there).
3. **§4.5 rotating `settleRound` (R1-07).** "The recipient's own unpaid part is taken from its payout when `gross − fee − holdback` covers it, with no strike."
4. **§4.3 `allowVault` and the Guardian SLA (R1-04).** List the extended checks; the Guardian's reaction window for exposure changes (caps, fees, adapter write-downs) is 3 days, matching Gauntlet; 7 days remains for allocators and the adapter set. Monitors alert on `Submit` for every checked selector.
5. **§4.3/§4.5 accumulation (R1-09, R1-10, R1-11).** Exit forfeits return to the exited members, less the fee, when nobody remains; the fee also applies when nobody is compliant; the delinquent cap applies once at maturity and later yield on the retained shares is the member's. Invariant 6 reads: "a delinquent member gets at most its principal valued at maturity, plus the yield on it after maturity; per dollar, a compliant member gets at least as many pool shares as a delinquent one when the share price never fell before maturity".
6. **§4.5 accumulation `guardianCancel` (R1-03).** "While Active or Matured; once Matured the finalize outcomes stand (no fee)."
7. **§4.5 `flagRound` (R1-03).** "Reverts while the vault cannot value shares."

### Corrections to earlier notes (R1-33)
- **Step-2 deviation 17 is stale.** Cancellations no longer loop over rounds to clear pots (step-4 fix 1): per-round `_pot` entries stay as they were and `pot(round)` reads 0 once Cancelled. Indexers must use `pot()` and events, never private storage.
- **§4.6 ledger mapping, events to add.** `SecurityWithdrawn` (`circle_sec → wallet`), `ExitedEarly` and `Forfeited` (`circle_pool → wallet`, and the forfeited yield between accounts), `MemberSettledInKind` / `ClaimedInKind` (USDC part plus vault shares as an in-kind position), `DonationsSwept` / `ResidualSwept` (to `fees`), and from this round `OwnContributionNetted` (payout → `circle_pool`, never the wallet), `SharesQueued` / `OwedSharesClaimed` (in-kind `owed`), `FeePaidInKind` (to `fees`). The rotating `ClaimAssigned.claim` now includes the at-par refund, and `CircleCancelled.assets` is refunds plus pool. Accumulation `cashOut` still counts USDC only, so the hourly reconciliation must add the in-kind events.

### Results
- **`forge build --sizes`: exit 0, every contract within EIP-170 / EIP-3860** (no negative margin anywhere in `--json`). The manifest-check harnesses are external functions on the test contracts, so no oversized helper contract enters the size table.

  | Contract | Runtime (B) | Initcode (B) | Runtime margin |
  |---|---|---|---|
  | MHAccumulationCircle | 21,901 (was 20,295) | 22,553 | 2,675 |
  | MHRotatingCircle | 18,380 (was 16,622) | 18,969 | 6,196 |
  | TimelockController (OZ) | 6,550 | 7,468 | 18,026 |
  | MHCircleRegistry | 4,635 (was 3,192) | 5,473 | 19,941 |
  | MHCircleFactory | 3,651 | 4,940 | 20,925 |
  | MHGuardianCanceller | 3,513 (was 3,348) | 3,930 | 21,063 |
  | MHReputation | 1,856 | 2,229 | 22,720 |

  **Batch 1 gas is now tight.** The rehearsal simulates batch 1 at **9,495,932** transaction gas (was 8,727,447) and batch 2 at 5,499,351; `BuildBaseBatch` refuses above 10M with its 1% margin, so about 0.4M (roughly 1.8 KB of initcode) is left. Any further growth of either implementation means splitting batch 1 into two Safe transactions (one per implementation).
- **`forge test` (default profile): 359 passed, 0 failed, 3 skipped** (the three fork suites skip without `BASE_RPC_URL`). New: `MHAuditRound1Rotating` (16), `MHAuditRound1Accumulation` (23), `MHAuditRound1Governance` (8 in three contracts), `test/script/MHManifestCheck.t.sol` (6), plus `test_settleRound_recipientsOwnPartIsNetted`; the existing tests changed only where a fixed behaviour changed (listed in the table).
- **Invariant suites, default profile (32 × 100): both pass** inside the run above. Also run at **1,000 runs × depth 200 (200,000 calls each): rotating passes (275 s), accumulation passes (209 s)**. The first 1,000-run accumulation attempt failed twice on the new oracles themselves (fees paid before a Matured cancel; a finalize fee valued at the vault's true price against a cap at the circle's discounted price); both oracles were corrected, and the persisted failing sequence replays clean. The CI profile (10,000 × 200) was not re-run here (about an hour per suite).
- **`FOUNDRY_PROFILE=ci` (1,000 fuzz runs), every non-invariant suite: 356 passed, 0 failed, 3 skipped** (before the last test-only additions), including `testFuzz_R1_01_jitMovesNoOtherClaim` and the updated rotating and accumulation path fuzzers.
- **Fork suites (`BASE_RPC_URL=https://mainnet.base.org`, block 52,933,005): 52 passed, 0 failed** (8 circle fork tests, 39 rehearsal tests including 4 new, 5 new `MHAuditRound1Fork` tests). `snapshots/circles-fork.json` was regenerated by that run (every entry moves by at most 1.8%; the largest is `settleMemberInKind`, +5.3k for the blacklist checks on the share legs).
- **Cold gas at n = 50 (isolated, `MHGasBounds`):** `cancelStalled` worst case 4,783,544 (was 4,719,320; about 216k headroom under 5M), `settleRound` 4,404,781 (48 covers + 1 netting; was 4,466,152 with 49 covers), accumulation `flagRound` 3,999,802, `finalize` 833,881, `guardianCancel` 564,236. Non-isolated: rotating `cancelStalled` 4,156,480, `settleRound` 3,990,517.
- **Mutation spot-check (R1-31):** the auditor's two surviving invariant mutants are now killed (see the R1-31 row).
- **Slither 0.11.6 on `src/circles` after `forge clean`:** `--fail-high` exits 0; **0 High, 26 Medium, 31 Low, 2 Informational (59)**. Against step 4 (44): the new ones are false positives or accepted by the same reasoning as the step-4 triage: `incorrect-equality` +2 (zero sentinels in `_returnForfeits` and `_sendShares`), `uninitialized-local` +2 (zero-initialised accumulators in `_weights`/`_returnForfeits`/`finalize`), `calls-loop` +12 (the registry's `_vaultCheck` reads a fixed list of eight selectors and at most 16 adapters; owner- or keeper-triggered views, no state change in the loop). The 2 `shadowing-local` Lows stay fixed, and `_unwind` is no longer flagged for complexity.
- **`forge fmt --check` and `forge lint`: clean.** No try/catch, `tx.origin` or low-level call was added to `src/`.

### Open questions (round 1)
1. **Founder sign-off on the seven spec amendments above**, in particular D3 (paid-out members now pay their fee on a cancellation) and the 3-day Guardian SLA for vault exposure changes (R1-04). If 7 days must be kept, no vault on Base qualifies today (Gauntlet's caps and fees are 3 days).
2. **R1-08 automatic pause relief** (notePause / FLAG_DELAY / reopening flagged rounds / per-incident budget) is a spec decision; until then the runbook's "extend every Active circle on a USDC `Pause`" is the control.
3. **R1-01 residual edge (σ < 100% only):** a paid-out member whose security was drawn below its requirement by covers can top it up before a cancel and, if nobody is short, gain a larger penalty share; it is bounded by its own unbacked requirement `ceil(σ·(n − paidRounds)·c) − sec`. Accept, or also block deposits by under-secured paid-out members after the stalled round's grace.
4. **R1-07 slot 1:** at σ = 100% with a fee and no collateral, slot 1 still cannot be netted (payout `c − fee`), so a blacklisted slot 1 still stalls round 1 (Guardian cancel is available then). Options: require slot 1 to post `fee` of collateral, or accept.
5. **R1-04 provenance:** add `VaultV2Factory.isVaultV2(vault)` once the factory address is verified on Base ([VERIFY]).
6. **R1-25** belongs to the CI owner (`.github/`, outside this scope).
7. **CI profile invariants (10,000 × 200)** should be re-run on the audit commit; this round ran 1,000 × 200.
8. **Batch 1 headroom** (about 0.4M gas): decide now whether to split the implementations into two Safe transactions before the next change to either circle.

## Round 1 fixes (audit 2, 2026-10-22)

Scope: the 29 confirmed findings of the second audit's first round (R1-01 to R1-29; in this section "R1-xx" means this audit, and earlier findings are written "A1 R1-xx" / "A1 R2-xx" for the first audit's rounds 1 and 2). Every finding with a verifier PoC has that PoC replayed in the real suite, asserting the fixed outcome, or, for an acknowledged finding, pinning the accepted behaviour. New suites: `test/circles/MHAudit2Accumulation.t.sol` (31 tests), `test/circles/MHAudit2Rotating.t.sol` (17, one fuzz), `test/circles/MHAudit2Governance.t.sol` (8), `test/fork/MHAudit2Fork.t.sol` (6, Base fork), `test/shell/check-manifest-bytecode.args.sh` (8 shell cases). Nothing is committed. Work stayed inside `contracts/`: the spec and `.github/` were not edited, so every spec change is recorded below as an amendment for founder sign-off, and the CI changes as recommendations for the CI owner.

### Status by finding

| ID | Sev. | Status | Change | Covered by |
|---|---|---|---|---|
| R1-01 | Medium | **Fixed** | New Guardian-only `MHAccumulationCircle.forceExit(adapter, data, assets)`: switches yield off, calls `vault.forceDeallocate(adapter, data, assets, circle)` (no allowance: `msg.sender == onBehalf`) and, in the same call, redeems at most `assets` of the circle's shares (every remaining share when they are worth no more, else `withdraw(assets)`), so the exit never goes through the vault's liquidity adapter and no allocator can re-allocate in between. `assets` must be non-zero, at most the position's value, and `adapter` one of the vault's adapters (`isAdapter`), else `BadForceExit`; so over any number of calls the vault's penalty (Vault V2 cap 2%, 0.001% on Gauntlet) costs at most that share of the position. New event `ForceExited`; `IVaultV2` gains `isAdapter`/`forceDeallocate` (signatures as in `test/vendor/vaultv2`). `MockVaultV2` models `forceDeallocate`, the penalty, freed idle and re-allocation. A1 R1-22's runbook (separate keeper transaction) is relabelled a loss path and replaced (README "Guardian runbook additions"); allocators are surfaced for sign-off (R1-23). | `MHAudit2Accumulation`: `test_A2R1_01_hostileLiquidityAdapter_forceExitSavesTheCircle`, `test_A2R1_01_separateTxRunbookDefeated_forceExitIsAtomic`, `test_A2R1_01_forceExit_penaltyBoundedBy2Percent`, `test_A2R1_01_forceExit_partialFreesAndRedeemsExactly`, `test_A2R1_01_forceExit_guards`; fork (real Gauntlet, junk-market rug of the PoC): `test_A2R1_01_fork_allocatorBlocksExits_forceExitSavesTheCircle`, `test_A2R1_01_fork_zeroLiquidityAdapter_forceExitStillWorks`, `test_A2R1_01_fork_reallocationBetweenTxs_forceExitIsAtomic`, `test_A2R1_01_fork_penaltyRaisedTo2Percent_circleLosesAtMost2Percent`, `test_A2R1_01_fork_control_noBlock`; `MHBoundaryGas::test_R8_boundary_forceExit`; invariant action `forceExit` (Guardian and others, 0–2% penalty, liquidity pulled; oracle: Guardian only, yield off, NAV loss ≤ 2% of `assets`) |
| R1-02 | Low | **Acknowledged** (mitigated) | The economic write-off stays: removing it needs a founder decision between the auditors' options (continue the schedule without the defaulter, or a wind-down in which debtors keep paying into the claim pool), both new state machines in the rotating circle, and an amendment of spec §4.4 D4 / §4.7 invariant 5. Mitigation now: every negative position a stall cancellation writes off emits `PositionWrittenOff(member, round, amount)` (what the member took out beyond what it paid in, fee included), so the Trusted-tier gate can catch repeat beneficiaries (an event, not a strike: an honest debtor whose creditor had a hardship default is not penalised, and the n = 50 stall stays far under 5M gas). Off-chain controls recommended: cap the aggregate unsecured exposure `Σ (1 − σ)(n − k)c` of a Trusted circle, and show each creditor the single-default loss (for example −37% at n = 20), not only the debtor-default case. | `MHAudit2Rotating`: `test_A2R1_02_n20Collusion_writeOffIsFlagged` (slot 1 +$900, no strike, flagged with exactly $900; pinned), `test_A2R1_02_midCircle_everyBeneficiaryFlagged` (slots 1–9 +$460 each, all flagged), `test_A2R1_02_completion_noWriteOff`; `test_D2_sigma50_slot1StopsAfterPayout` (flags slots 1–3) |
| R1-03 | Low | **Fixed** (spec D2/D3/D4 amended) | `_refundAt` treats the stalled round's recipient's own round-s contribution as circular, like `settleRound`'s netting (A1 R1-07): `_refund(…, paidS && !own, stall && !own)`. A payment of it is returned to its security and refunded at par, it is never covered at cancel time, and its E is always `(s − 1)·c`. Withholding, paying on time and a flash-funded JIT deposit now give identical outcomes; the A1 R1-01 property ("a JIT deposit changes nobody else's claim") holds for the recipient too. `amountDue` returns 0 for a recipient's own round when `settleRound` can net it (R1-19). | `MHAudit2Rotating`: `test_A2R1_03_sigma100_recipientsChoiceNoLongerMovesMoney`, `test_A2R1_03_recipientJitDeposit_movesNoOtherClaim`, `test_A2R1_03_sigma50_D4_D2_payOrSkipIdentical`, `testFuzz_A2R1_03_recipientActionsMoveNoOtherClaim` (recipient withholds or pays; actor may be the recipient; 2,000 runs locally); updated D2/D3/D4 and the A1 R1-01/R1-02/R1-06 regressions (numbers below) |
| R1-04 | Low | **Fixed** (tooling, docs) | README step 5 now reads `--signer <audited tag or SHA from the AUDIT REPORT> …manifest.json` and says the commit must never come from the manifest; step 1 has the audit report cite the tag and every `creationCodeHash`. `check-manifest-bytecode.sh` refuses a `--signer` value that is an existing path or ends in `.json` (the old README command now fails with a clear message instead of a usage error). `CheckManifest` prints `creationCodeHash` next to `initCodeHash` (the creation-code hash depends only on the audited source and compiler settings, so it exists at audit time). | `test/shell/check-manifest-bytecode.args.sh` (R1-04 cases: README-verbatim, manifest-as-commit, existing path, directory) |
| R1-05 | Low | **Fixed** (spec §4.5 amended) | `cancelExpired` requires USDC to be live (`_requireUsdcLive`, like `finalize`) and the vault to be unable to value the circle's shares: a static call of `previewRedeem(vaultShares)` with a fixed `NAV_PROBE_GAS` = 3M that must return a word (no try/catch; `InsufficientGas` unless at least `NAV_PROBE_MIN_GAS` = 3.1M is left, so a caller cannot make a healthy vault look broken; a real Gauntlet `previewRedeem` costs about 156k). Whenever the NAV is readable it reverts `NavReadable`: `finalize` and the settlements (cap, compliant-only forfeits, fee) are the only way out. A blacklisted circle is left to `guardianCancel`. | `test_A2R1_05_healthyVault_delinquentCannotCancel_finalizeCaps` (spec §4.5 example at expiry: A $1,234.50, D $1,000, treasury $11.50), `test_A2R1_05_usdcPaused_cancelExpiredReverts`, `test_A2R1_05_circleBlacklisted_onlyGuardianCancels`, `test_A2R1_05_probeCannotBeStarvedByTheCaller`; fork `test_A2R1_05_fork_previewRedeemFarBelowProbeGas` |
| R1-06 | Low | **Fixed** | The same probe rule closes the fee skip: a Matured circle whose vault can value its shares (liquid or not) cannot be cancelled; an illiquid member settles with `settleMemberInKind`, which charges the fee. The NAV-free, fee-free Matured cancel only exists for the broken-NAV case it was made for (A1 R1-03 / R2-09). | `test_A2R1_06_illiquidMatured_waitingCannotSkipTheFee` (fee ~$3.00 reaches the treasury), `test_A2R1_06_liquid_keeperOffline_feeKept` |
| R1-07 | Low | **Fixed** (spec §4.7 inv. 7 amended) | New `uint64 lastLive` (packed with `totalRounds`): set at activation and by every state-changing call that reads the NAV (`contribute`, `exitEarly`, `claim`, `deployIdle`, Active `flagRound`, `finalize`, `settleMember(InKind)`, through `_liveNav`). `cancelExpired` opens at `lastLive + EXPIRY_DELAY` (90 days), so the freeze follows the outage, not the schedule (12 monthly rounds: 90 days instead of 422; 520 × 92 days: 90 days instead of 130 years). Combined with the probe, a healthy circle is never cancellable this way. | `test_A2R1_07_midLifeBreak_exitOpens90DaysAfterTheOutageStarts`, `test_A2R1_07_gateIndependentOfSchedule`, `test_A2R1_07_healthyCircleNeverExpires`; invariant `cancelExpired` action and oracle (success only after a 90-day outage) |
| R1-08 | Low | **Fixed** (spec §4.5 amended) | Accumulation `flagRound(r)` waits for `_graceEnd(r) + cure` and `finalize` for `_graceEnd(totalRounds) + cure` (the stored, bounded cure was unused). `_payable` still closes at the grace end; an extension during the cure reopens any round not flagged yet. So after any outage spanning a grace end the Guardian has at least 72h. Runbook: pre-signed Guardian `extendDeadline` transactions submitted as L1 `OptimismPortal` deposits during a sequencer outage. | `test_A2R1_08_outageAcrossGraceEnd_guardianExtendsInTheCure` (the PoC: B stays compliant, keeps ~half the yield, no MISSED strike), `test_A2R1_08_finalizeWaitsForTheCure`, `test_A2R1_08_navOutageAcrossGraceEnd_flagWaitsForTheCure`, `test_A2R1_08_pinned_noGuardian_flagAfterTheCure`; A1 `test_R1_08_pinned_flagAtUnpauseWithoutGuardian` updated |
| R1-09 | Low | **Fixed** (spec §4.3 amended) | `deployIdle` checks `REGISTRY.vaultSafe(vault)` first; if the vault is delisted or no longer safe it switches yield off and deposits nothing (no revert, so the switch sticks). New permissionless `syncVault()` does only the switch (reverts `YieldOn` while the vault is safe), so a keeper protects every circle on a delisted vault without the Guardian; `pullFromVault` then brings the shares home. | `test_A2R1_09_deployIdleAfterDelist_switchesYieldOffInstead` (the PoC: NAV $600, not $400), `test_A2R1_09_deployIdleAfterGuardianDisallow_switchesYieldOff`, `test_A2R1_09_syncVault_isPermissionless`; `test_R8_boundary_syncVault`; invariant `syncVault` action |
| R1-10 | Low | **Fixed** | `vaultSafe` runs the full `_vaultCheck`, adapter walk included (the `adapters` flag is gone: every caller runs every check). The reads are the bounded, fail-closed A1 R2-07 reads; `vaultSafe` can only revert `InsufficientGas`. | `test_A2R1_10_adapterTimelockDrop_isCaughtLive` (the PoC's real adapter timelock machine: creation refused, a pending circle activates with yield off, an Active circle's `deployIdle` stops), `MHAudit2Governance::test_A2R1_10_vaultSafeWalksAdapters_andRevalidateDelists`; A1 `test_R1_04_vaultSafe_*` docs updated |
| R1-11 | Low | **Fixed** (spec §4.4/§4.5 amended) | Rounds are paid in order: `contribute(round)` requires the caller to have paid the previous round (its own round is skipped: `settleRound` nets it), or that round is settled; by induction every unsettled earlier round is paid. New error `OutOfOrder`; `amountDue` returns 0 for a round that would be out of order. A fully drawn round is satisfied with a zero-pull `contribute`. A defaulter therefore never has money in a later pot. | `MHAudit2Rotating`: `test_A2R1_11_laterRoundBeforeTheSettlingOne_isRefused`, `test_A2R1_11_latePaymentThenNextRound`, `test_A2R1_11_sigma50_defaulterHasNothingInLaterPots`, `test_A2R1_11_ownRoundSkipped_fullyDrawnZeroPull`; rotating invariant oracle `prepaidDefaulters == 0`; `MHGasBounds` worst cases rewritten (the step-4 "every pot full" stall can no longer happen) |
| R1-12 | Info | **Fixed** | Ported regressions for every surviving A1 round-2 mutant (A03/A04 cancelExpired gate, A05 R2-02, A23, R04 R2-13, R06 R2-05, R08 R2-08, A06 R2-11, G06 R2-14, G15/G16 R2-07), `cancelExpired` gate/status/outcome/event tests, invariant 7 as written (`AccumulationHandler.driveToEnd` now resolves a broken vault with time + the permissionless `cancelExpired`, never the Guardian; new `cancelExpired`, `syncVault`, `forceExit`, `vaultReallocate` actions and oracles), `cancelExpired`/`forceExit`/`syncVault` in `MHBoundaryGas`, and `RotatingHandler.toggleBlacklist` now blacklists the circle itself too (oracle `blacklistedStalls == 0`). Hand-mutant campaign below. | `test_A2R1_12_*` (accumulation 6, rotating 4, governance 2); `invariant_accumulation`, `invariant_rotating`; `test_R8_boundary_cancelExpired` |
| R1-13 | Low | **Fixed** (tooling, docs) | `BuildBaseBatch.run` validates, then runs the pending-submission scan (and requires `CIRCLE_VAULT_FROM_BLOCK`) before `build` writes anything. `SKIP_VAULT_SCAN` is honoured only inside `forge test` (`vm.isContext(TestGroup)`); any `forge script` run refuses it (`SkipScanOutsideTests`). README: `CIRCLE_VAULT_FROM_BLOCK`, `LOG_CHUNK`, `SKIP_VAULT_SCAN` in the Inputs table and the step 4 and step 8 commands. | fork `SafeDeployRehearsal::test_env_loadConfigAndRun` (missing input and a real scan abort both leave no file; with `SKIP_VAULT_SCAN` the run succeeds and `CheckManifest` accepts the output) |
| R1-14 | Info | **Fixed** (one part acknowledged) | The three red rehearsal tests are fixed: the env test covers a successful `run()` (R1-13); `test_verify_rejectsWrongCodehash` checks both the manifest value and on-chain code substituted with `vm.etch`; `test_R1_17_verify_rejectsContractOwnerAddedLater` swaps an owner so the Guardian stays 2-of-4 and the EOA check is what fires. `VerifyBase.run` is split into the RPC part and a new `verifyAll(path, eoas, events, scheduled, allowed)`, driven end to end on a real three-batch deployment. `run()` itself (logs from an RPC, the vault scan) cannot run in a fork test, whose locally executed transactions an RPC never serves; the anvil runbook covers it (acknowledged). | `test_env_loadConfigAndRun`, `test_verify_rejectsWrongCodehash`, `test_R1_17_verify_rejectsContractOwnerAddedLater`, `test_A2R1_14_verifyAll_endToEnd`; fork suites 61/61 |
| R1-15 | Low | **Fixed** (in `contracts/`) | `check-manifest-bytecode.sh` in CI mode (no `--signer`) skips a manifest path that does not exist with `SKIP` and exit 0 (signer mode still fails), so the CI step as written passes until the ceremonies are committed. Recommended for the CI owner (`.github/` is outside this scope): `for m in deployments/base-*/manifest.json` instead of the literal paths. | `test/shell/check-manifest-bytecode.args.sh` (R1-15 cases, including the CI step verbatim) |
| R1-16 | Info | **Fixed** | Canceller: a single `canceller.setGuardian(X)` is protected only when X is the registry's Guardian (completing a partial rotation); a single `registry.setGuardian(newG)` only when `newG` is not the sitting Guardian. A batch is rotation-only only if its last `registry.setGuardian(newG)` replaces the sitting Guardian (`newG != REGISTRY.guardian()` at cancel time), every `canceller.setGuardian` names `newG`, and every `setIsSentinel` is `(newG, true)` or `(currentGuardian, false)`; `isRotationCall` also requires a clean address word. Closes step-1 open question 5. | `MHAudit2Governance`: `test_A2R1_16_loneCancellerSetGuardian_cancellableUnlessCompleting`, `test_A2R1_16_mismatchedRotationBatch_isCancellable`, `test_A2R1_16_noOpRotation_protectsNothing`, `test_A2R1_12_G06_and_R1_28_sentinelWordsChecked`; `MHGuardianCanceller.t.sol` (22, two updated) |
| R1-17 | Info | **Fixed** | Both `initialize` functions require `REPUTATION.isReporter(address(this))` (`BadConfig` otherwise). The factory registers the clone before `initialize`, so only factory clones become circles. | `test_A2R1_17_nonFactoryClone_cannotInitialize` |
| R1-18 | Info | **Acknowledged** | The canceller's comment no longer claims "no operation can be too large to cancel": calldata above ~128 KB cannot be sent in one transaction. Runbook: a Guardian helper that rebuilds the calldata on chain from `CallScheduled` logs, rehearsed; alert on any `CallScheduled` with data larger than a few KB. Impact stays bounded by a full rotation (48h). | n/a (documentation and runbook) |
| R1-19 | Info | **Fixed** | `amountDue` returns 0 for a recipient's own round whenever `_nettable` holds, and `contribute` records no LATE strike for that circular payment (a non-nettable recipient is still asked and struck as before). | `test_A2R1_19_ownRound_nothingDue_noLateStrike`, `MHRotatingCircle.t.sol::test_amountDue_cases`, `test_settleRound_recipientsOwnPartIsNetted` |
| R1-20 | Info | **Acknowledged** | A round-1 stall costs the staller only a strike and freezes funds for round + grace + cure; a join deposit needs a product decision. Runbook: the Guardian calls `guardianCancel` as soon as round 1 is past grace with a gap nobody can cover. | `test_A2R1_20_pinned_round1Stall_freeExceptTheStrike` |
| R1-21 | Info | **Acknowledged** (founder decision, extends A1 R1-28) | Kept: with nobody compliant, the remaining members share the exiters' forfeits by acc, while with no remaining acc the forfeits return to the exiters (A1 R1-09/R2-02). | `test_A2R1_21_pinned_exitForfeitCliff` (member 2 +$130.00 with one $100 payment; with none, each exiter gets its $60 back) |
| R1-22 | Info | **Acknowledged** (mitigated) | The 30-day budget stays per circle. R1-08's cure gate means no flag or finalize fires in the first block after an outage whatever the budget; budget exhaustion is added to the Guardian-compromise playbook. | `test_A2R1_22_pinned_budgetExhausted_cureStillApplies` |
| R1-23 | Info | **Fixed** (tooling; on-chain pin acknowledged) | `CheckVaultPending` (mandatory for every allowVault proposal, README step 10) now requires, on Base, the pinned Vault V2 factory provenance and the pinned Morpho adapter registry for any vault, and prints every current allocator (from `SetIsAllocator` logs), whether the curator is one, the liquidity adapter, and every id with a non-zero absolute cap (from `IncreaseAbsoluteCap` logs) for explicit sign-off. An on-chain adapter-registry pin in `allowVault` (a Timelock-set value) is left as an option: it changes the registry ABI and the spec. | fork `test_A2R1_23_checkVaultPending_provenanceAndRoleReview` (Gauntlet passes; a foreign vault fails; Gauntlet's curator is listed as an allocator) |
| R1-24 | Info | **Fixed** | `MHReputation` packs a user's total and per-reason counts into one slot (`strikeCount`/`strikesByReason` keep their signatures), so a first strike writes two fresh slots instead of three (~22k gas less per strike). `MHGasBounds` asserts the minimum transaction gas limit (binary search + intrinsic), cold, for the worst cases that can still happen after R1-11. Figures below. | `test_gas_n50_cancelStalled_50Defaults_cold`, `test_gas_n50_cancelStalled_2Default48Covered_cold`, `test_gas_n50_cancelStalled_1Default49Prepaid_cold`, `test_gas_n50_settleRound_48CoversAndNetting_cold`, `MHReputation.t.sol` (17, unchanged) |
| R1-25 | Info | **Fixed** (tooling; spec §5 amended) | Batch 1 is split into batch 1a (rotating implementation, nonce N) and batch 1b (accumulation implementation, N+1), each a plain CALL to CreateX (how Safe{Wallet} sends a one-transaction file; `SafeBatch` now records the Safe transaction's own `to`/operation/data); batch 2 moves to N+2 and the allowVault proposal to N+3/N+4. Planner, JSON writer, `MHManifestCheck` (independent decoding and hashing of single-call batches), `BuildBaseBatch`, `CheckManifest` and README updated. Required anyway: this round's code would have pushed a single batch 1 over 10M. | `test/script/MHDeployPlan.t.sol::test_plan_batches`, `test/script/MHManifestCheck.t.sol` (6), fork `test_rehearsal_fullCeremony` (each batch ≤ 10M, simulation within 1%), `test_rehearsal_manifestAndFilesMatchPlan`, `test_build_futureNonce`, `test_build_rejectsUsedSalts` |
| R1-26 | Info | **Fixed** | The operator must have no code: `BuildBaseBatch.validate` (`OperatorNotEoa`, EIP-7702 delegations included), `VerifyBase._verifyLinks` ("operator is an EOA"), and offline `MHManifestCheck.policy` refuses known contracts (Multicall3, MultiSendCallOnly, CreateX, the Safe singleton, factory and fallback handler, USDC). | fork `test_A2R1_26_operatorMustBeAnEoa` |
| R1-27 | Info | **Fixed** (documentation) | The A1 round-2 behaviour changes are now listed as spec amendments (below), together with this round's. | n/a |
| R1-28 | Info | **Fixed** | The no-code adapter case asserts `VaultCheckFailed(burnShares)` exactly; new adapters with a short return and with `abdicated = 2` fail closed with the same check; malformed `setIsSentinel` words and dirty address bits make a batch cancellable; `deployIdle` is tested at exactly `MIN_DEPLOY`. | `MHAuditRound1Accumulation::test_R1_04_allowVault_checksEveryAdapter` (strengthened), `test_A2R1_28_adapterReadsFailClosed`, `test_A2R1_12_G06_and_R1_28_sentinelWordsChecked`, `test_A2R1_28_deployIdle_minDeployBoundary` |
| R1-29 | Info | **Fixed** (docs) / **acknowledged** (CI) | README: the Safe threshold text states the A1 R2-17 per-role policy; `forge verify-contract` for the OZ `TimelockController` path; nonces N..N+4 reserved, and the restart-with-a-new-seed path if one is consumed after batch 1a/1b; the allowVault execute transaction is confirmed only after the second `CheckVaultPending`. Step-5 deviation 5 is corrected below. The CI items (forge commit check in every job, Slither from a hashed requirements file, `BASE_RPC_URL` exposure to same-repo PRs) are in `.github/`, outside this scope; they stand as recommendations (A1 R1-25). | n/a |

### Numbers that changed (spec amendments, founder sign-off)

R1-03, rotating, n = 6, c = $100, fee 2%:
- **D3 (σ = 100%, slot 5 stops at round 3):** slots 1–2 −$12, slot 3 **+$25.00**, slots 4 and 6 **+$37.50**, slot 5 −$100 (claims 325 / 337.5 / 100 / 337.5; pool $1,100; no residual; treasury $24). Was +$33.33 for slots 3, 4 and 6.
- **D4 (σ = 50%):** slots 1–2 +$138, slot 3 **−$37.10**, slots 4 and 6 **−$55.65**, slot 5 **−$127.60** (E = 0, 0, 200, 300, 200, 300; recovered $824). Was −$50.30 / −$50.30 / −$125.09.
- **D2 (σ = 50%, slot 1 stops after payout):** slots 1–3 +$238/+$88/+$88 (unchanged), slot 4 **−$112.909091**, slots 5 and 6 **−$150.545455** (claims 287,090,909 / 249,454,545 ×2; $786 recovered, 1 micro-USDC residual). Was −$138 each.
- A1 R1-06 regressions: the round-1 recipient's own payment is no longer a credit, so with slot 6 (σ = 100%) defaulting on $90 the four other creditors get **+$22.50** each (was +$18 for five).

### Spec amendments needed (founder sign-off; not edited, outside `contracts/`)
1. **§4.5 accumulation `forceExit` (R1-01).** "Guardian: force-deallocate from one of the vault's adapters and redeem at most that much, in one call; the vault's penalty (≤ 2%) is borne by the circle; `assets` is bounded by the position's value." §5 playbook "Morpho impaired": use `forceExit` when redemptions revert; treat allocators as an instant, trusted role in the `allowVault` review.
2. **§4.4 D2/D3/D4 and §4.4 stall (R1-03, R1-19).** "The stalled round's recipient's own contribution never counts in its net position: a payment of it is refunded at par and it is never covered at cancellation. `amountDue` is 0 for a recipient's own round when `settleRound` can net it, and paying it anyway is never LATE." New D2/D3/D4 numbers above.
3. **§4.4 / §4.5 rotating `contribute` (R1-11).** "Rounds are paid in order; a member's own round is skipped; `amountDue` is 0 for a round that is not payable yet."
4. **§4.4 D4 / §4.7 invariant 5 (R1-02).** Document that a creditor's stall writes off the paid-out members' unsecured balances (flagged by `PositionWrittenOff`), and the founder's choice between keeping it, a continuation without the defaulter, or a wind-down.
5. **§4.5 accumulation `flagRound` / `finalize` (R1-08).** "After deadline + grace + cure."
6. **§4.5 / §4.7 invariant 7 `cancelExpired` (R1-05, R1-06, R1-07; also A1 R2-09, which was never written into the spec).** "Anyone, once the vault has not valued the circle's shares for `EXPIRY_DELAY` (90 days, from `lastLive`), only while it still cannot (bounded `previewRedeem` probe) and USDC is live; same outcomes as `guardianCancel`, reason `Expired` (new `CancelReason` value: the indexer must decode it)."
7. **§4.3 vault safety (R1-09, R1-10).** "`vaultSafe` walks the adapters; `deployIdle` and the new permissionless `syncVault` switch yield off on a vault the registry no longer allows; delisting therefore affects live circles' new deposits."
8. **§4.1 canceller (R1-16; A1 R2-14).** The rotation exception as now implemented (see the R1-16 row), replacing "`setIsSentinel` is a rotation call".
9. **§4.1 initialize (R1-17).** "Only a registered reporter (a factory clone) can be initialized."
10. **§5 ceremony (R1-25, R1-26, R1-13).** Batch 1 is two Safe transactions (1a, 1b), nonces N..N+4; the operator has no code; the vault scan precedes any output.
11. **A1 round 2, recorded now (R1-27):** A1 R2-06 (`_takeCash` withdraws the pro-rata vault part even when idle covers the amount, unlike §4.3 `_ensureIdle`; a cash exit reverts while any vault share is illiquid, and the in-kind path applies); A1 R2-11 (new `CircleBlacklisted` error, treated like a pause for every strike and stall gate); A1 R2-05 and R2-13 (stricter `withdrawSecurity`: a paid-out member that has not paid the open round keeps one more c; the post-grace lock ignores the Guardian's extension); A1 R2-08 (COVERED strikes at a stall cancellation); A1 R2-07 (`adapterSetHash`, permissionless `revalidateVault` delisting, which §4.1 gives only to the Guardian); A1 R2-22 (`amountDue` semantics; `netPosition` in `ClaimAssigned` is informational); A1 R2-01/R2-03/R2-04/R2-16/R2-17/R2-18 (mandatory pending-submission scan, pinned ceremony vault, runtime derivation, 7702 owners count as code, per-role thresholds, the audited commit as a signer argument).

### Corrections to earlier notes
- **Step-5 deviation 5 is stale:** the allowVault proposal transactions do have precomputed hashes (A1 R2-03): the manifest records their nonces (now N+3 and N+4) and `safeTxHash` values, and `CheckManifest` recomputes them.
- **A1 R1-24 row:** `check-manifest-bytecode.sh --signer` takes the audited commit from the audit report (A1 R2-18), not the manifest's commit; the README and this note now say so (R1-04).
- **A1 R1-22 row:** the separate-transaction force-deallocation runbook is a loss path under a hostile allocator (R1-01); `forceExit` replaces it.
- **Round-1 gas figures** (`cancelStalled` 4,783,544, batch 1 9,495,932) are superseded by the figures below.

### Results
- **`forge build --sizes`: exit 0, every contract within EIP-170 / EIP-3860** (no negative margin in `--json`).

  | Contract | Runtime (B) | Initcode (B) | Runtime margin |
  |---|---|---|---|
  | MHAccumulationCircle | 24,266 (was 22,354) | 24,932 | **310** |
  | MHRotatingCircle | 19,377 (was 18,784) | 19,980 | 5,199 |
  | TimelockController (OZ) | 6,550 | 7,468 | 18,026 |
  | MHCircleRegistry | 5,413 (was 5,442) | 6,251 | 19,163 |
  | MHGuardianCanceller | 4,746 (was 4,107) | 5,198 | 19,830 |
  | MHCircleFactory | 3,651 | 4,940 | 20,925 |
  | MHReputation | 2,027 (was 1,856) | 2,400 | 22,549 |

  The accumulation implementation has 310 bytes of runtime left: the guard checks were folded into `_onlyGuardian`, `forceExit` is compact, and the probe builds its calldata in scratch space. Any further feature in that contract needs size work first (open question 5).
- **Ceremony gas (fork rehearsal, Base block 52,933,005):** batch 1a 4,605,662 simulated / 4,585,662 executed, batch 1b 5,703,419 / 5,680,619, batch 2 5,996,070 / 5,973,270 transaction gas; each under the 10M budget with the 1% margin (a single batch 1 would have been about 10.3M).
- **`forge test` (default profile, 256 fuzz runs, invariants 32 × 100): 420 passed, 0 failed, 4 skipped** (the four fork suites skip without `BASE_RPC_URL`). Was 359 / 3 skipped.
- **Fork suites (`BASE_RPC_URL=https://mainnet.base.org`, block 52,933,005): 61 passed, 0 failed** (`SafeDeployRehearsal` 42 including the three repaired tests and 4 new, `MHCirclesFork` 8, `MHAuditRound1Fork` 5, `MHAudit2Fork` 6). `test_env_loadConfigAndRun` accepts either `VaultCreationNotFound` or the `eth_getLogs` rate-limit error of a public RPC for the scan abort: both happen before any write, which is what it asserts. `snapshots/circles-fork.json` was regenerated by that run (`deployIdle` on Gauntlet +128k gas for the full `vaultSafe` walk of Gauntlet's adapters; `rotating.settleRound` +8.5k for the netted own round).
- **Invariant suites at 1,000 runs × depth 200 (200,000 calls each): accumulation passes (940 s), rotating passes (1,027 s)**, with the new actions and oracles (accumulation: `cancelExpired` only after a 90-day outage, `forceExit` Guardian-only and ≤ 2% penalty, `syncVault`, `vaultReallocate`; `driveToEnd` reaches an end state through the permissionless `cancelExpired`; rotating: the circle itself blacklisted, no stall while it is, no defaulter with a later-round payment, voluntary own-round payments). The CI profile (10,000 × 200) was not re-run here (about an hour per suite).
- **`testFuzz_A2R1_03_recipientActionsMoveNoOtherClaim`: 2,000 runs, pass.**
- **Shell regression `test/shell/check-manifest-bytecode.args.sh`: 8 / 8 pass.**
- **Cold gas at n = 50 (isolated, `MHGasBounds`):** `cancelStalled` minimum transaction gas limit 3,804,739 with 50 DEFAULT strikes, 3,799,620 with 2 DEFAULT + 48 COVERED, 1,103,550 with 1 DEFAULT and 49 members that prepaid every round (was 4,934,463 / about 4.9M, R1-24: ~1.2M of headroom now, from the packed reputation counters); `settleRound` 48 covers + 1 netting 3,338,912 execution gas (was 4,404,781); accumulation `flagRound` with 50 MISSED strikes 2,896,817 (was 3,999,802), `finalize` 842,279, `guardianCancel` 564,374. R8 boundary minima: `cancelExpired` 3,152,469 (above `NAV_PROBE_MIN_GAS` by design; every lower limit reverts with no state change), `forceExit` 98,169, `syncVault` 4,626 (warm harness).
- **Hand-mutant campaign (R1-12; runner `mut.py` and per-mutant results `mutants.jsonl` kept outside the repo, in the build scratchpad's `a2-artifacts/`): 31 / 31 killed** by the non-fork suite. The ten A1 round-2 mutants R1-12 listed (A03, A04, A05, A06, A23, R04, R06, R08, G06, G15, re-expressed on the current code) and 21 on this round's fixes (`forceExit` bound and yield switch, the probe and its gas guard, the USDC-live check, `lastLive` refresh, the cure gates, the `deployIdle` safety check, the full `vaultSafe`, the circular own round, `amountDue` zero, in-order payment, the LATE skip, the write-off flag, the canceller's no-op and pairing rules, the `isReporter` checks, the packed counters). One mutant (N11, the canceller's no-op-rotation rule) first survived; `test_A2R1_16_noOpRotation_protectsNothing` was extended with a no-op rotation that strips the sitting Guardian's own sentinel role, which kills it. A tool-based campaign (slither-mutate or gambit) remains an audit-gate item.
- **Slither 0.11.6 on `src/circles`** (with `slither.config.json`, and again with every detector: identical): **0 High, 29 Medium, 31 Low, 4 Informational (64)**; was 59. New or changed, all triaged as in step 4:
  - `reentrancy-no-eth` (1, new): `forceExit` writes `vaultShares`/`idleAssets` after the vault calls. Accepted: the writes need the calls' results (penalty shares, burned shares, assets), the function is `nonReentrant` like every state-changing entry point, and the vault and its adapters are allowlisted; a reentrant read-only view could only see the pre-exit position.
  - `incorrect-equality` (11, +2 since round 1: `_navReadable`'s `held == 0` and `_cancel`'s A1 R2-02 `base == 0`): zero sentinels on tracked counters, false positives as before. `uninitialized-local` (16) and `reentrancy-benign` (9) are unchanged in count and triage.
  - `calls-loop` (15, unchanged count): the registry's adapter walk now also runs in `vaultSafe` (bounded: at most 16 adapters, fixed selector lists, fail-closed reads with a gas floor).
  - `assembly` (2, Informational, new to the table): the registry's bounded `_read` (A1 R2-07) and the new `_navReadable` probe; both only `staticcall` into scratch space and check `returndatasize`.
  - `cyclomatic-complexity` (1): `finalize` (13), unchanged in substance.
- **`forge fmt --check` and `forge lint`: clean** outside `test/vendor` (vendored verbatim, never formatted). No try/catch was added to `src/` (the probe is a bounded low-level static call, like the registry's); no `tx.origin`, no code-size check.

### Open questions (audit 2, round 1)
1. **Founder sign-off on the amendments above**, in particular the new D2/D3/D4 numbers (R1-03), the cure gate in accumulation circles (R1-08), the outage-based `cancelExpired` rule (R1-05/06/07), in-order payment (R1-11), and the three-batch ceremony (R1-25).
2. **R1-02:** keep the stall write-off with the `PositionWrittenOff` flag, or build a continuation-without-the-defaulter or a wind-down (both new rotating state machines, and a re-audit). Until then: cap a Trusted circle's aggregate unsecured exposure and show creditors the single-default loss.
3. **R1-21 / A1 R1-28:** exit forfeits when nobody is compliant (return to the exiters, or weight by rounds paid).
4. **R1-20:** a small join deposit to give a round-1 stall a cost.
5. **Accumulation implementation size:** 310 bytes of EIP-170 margin left. The next change to it needs a size plan (move views to a lens contract, or another optimizer setting, which changes every initcode hash and must be decided before the audit tag).
6. **R1-23:** pin the allowed Morpho adapter registry on chain (a Timelock-set registry value) instead of in `CheckVaultPending` only.
7. **`NAV_PROBE_GAS` = 3M** is about 19× a real Gauntlet `previewRedeem`. A future vault whose valuation needs more would be treated as broken by `cancelExpired` (only after 90 days without any successful NAV read); `allowVault` reviews should measure it.
8. **CI owner (`.github/`, outside this scope):** the R1-15 glob, the forge commit check in every job, Slither from a hashed requirements file, and not exposing `BASE_RPC_URL` to same-repo PR code (R1-29); re-run the CI-profile invariants (10,000 × 200) and a tool-based mutation campaign on the audit commit.

## Closeout fixes (internal audit closeout, 2026-10-22)

Scope: the outstanding findings of the internal audit. **List A** (`A-R2-xx`) is the first audit's round 2 (22 confirmed findings whose fix was interrupted midway; the code of most of them landed with the second audit's round 1, but no section recorded them and several had no regression). **List B** (`B-R2-xx`) is the second audit's round 2, whose verification was cut short (1 medium, 7 low, 10 informational). For list A each finding was checked against the current code and either pointed to the test that proves it or finished; for list B every medium/low finding was first reproduced on the unfixed code with a test (`test/closeout-repro/*`, kept out of the suite after use; all seven on-chain ones reproduced: B-R2-01..07, and B-R2-08 is reproduced inside its regression), then fixed with that test kept as a regression, or (B-R2-04) acknowledged with the test pinning it. New suites: `test/circles/MHCloseoutAccumulation.t.sol` (17), `test/circles/MHCloseoutRotating.t.sol` (11, one fuzz), `test/circles/MHCloseoutGovernance.t.sol` (4), `test/script/MHCloseoutScripts.t.sol` (4), `test/shell/check-manifest-bytecode.signer-layout.sh` (4 shell cases, with `test/shell/GenSignerCeremony.s.sol`), plus additions to existing suites (named below). Nothing is committed; work stayed inside `contracts/` (the spec and `.github/` were not edited: spec changes are listed as amendments for founder sign-off).

### Status by finding

| ID | Sev. | Status | Change / reason | Covered by |
|---|---|---|---|---|
| A-R2-01 | Medium | **already-fixed** (test added) | Sleeper submissions cannot be seen on chain (`executableAt` is keyed by the full calldata), so the check is the off-chain pending-submission scan `MHVaultPending`, mandatory in `BuildBaseBatch.run` (before anything is written), `VerifyBase.run` and `CheckVaultPending` (runbook step 10, every allowVault proposal); the registry and `IVaultV2` NatSpec say what a duration does not cover. No regression proved the scan finds a sleeper: added on the real Vault V2 code (`test/vendor/vaultv2`): two sleepers pass `allowVault`, one executes at once despite the 7-day timelock, the scan reports both and refuses, and passes once they are revoked. | `MHCloseoutGovernance::test_A1R2_01_sleeperSubmissions_foundByTheScan`; fork `SafeDeployRehearsal::test_env_loadConfigAndRun`, `test_A2R1_23_checkVaultPending_provenanceAndRoleReview` |
| A-R2-02 | Low | **already-fixed** (test added) | `_cancel`: with no remaining pool shares in an Active circle, each exited member gets its own forfeit back (`_returnForfeits(n, 0)`), nothing to residual. The `guardianCancel` path had no test (only `cancelExpired`'s). | `MHCloseoutAccumulation::test_A1R2_02_guardianCancel_allExited_returnsForfeits`; `MHAudit2Accumulation::test_A2R1_12_R2_02_cancelExpired_allExited_returnsForfeits` |
| A-R2-03 | Low | **already-fixed** (test added) | The ceremony vault is pinned in reviewed source (`BaseChain.circleVaultOf`), enforced by `BuildBaseBatch` (`VaultNotPinned`) and offline by `MHManifestCheck.policy`; the allowVault proposal transactions have nonces and `safeTxHash` values in the manifest, recomputed and printed by `CheckManifest`. | `MHCloseoutScripts::test_A1R2_03_foreignVaultRefused`; `MHManifestCheck.t.sol::test_R1_05_honestCeremonyPasses` |
| A-R2-04 | Low | **already-fixed** (test added) | Runtime codehashes are derived from the local build (`MHManifestCheck.deriveRuntime`/`runtimeOf`), never copied; `check-sourcify.sh` requires on-chain codehash = derived runtime = the bytecode Sourcify verified. | `MHCloseoutScripts::test_A1R2_04_runtimeCodehashIsDerived`; `MHManifestCheck.t.sol::test_R1_05_tamperB_implementationSubstitution`; fork `test_verify_rejectsWrongCodehash` |
| A-R2-05 | Low | **already-fixed** (test added) | `_required`: a paid-out member that has not paid round `nextSettle` keeps `ceil(σ·(n − paidRounds − 1)·c) + c`, so withdrawing first takes out no more than a cancellation refunds; `_refund` covers it at a stall. New regression: at σ = 50%, doing nothing, withdrawing the maximum first, or satisfying the round give every member the same final position. | `MHCloseoutRotating::test_A1R2_05_sigma50_paidOutMember_withdrawOrSkipMovesNothing` (kills the R2-05 mutant); `MHAudit2Rotating::test_A2R1_12_R2_05_paidOutRequirementIncludesOpenRound` |
| A-R2-06 | Low | **already-fixed** (test added) | `_takeCash` takes the pro-rata idle part and withdraws the rest, so the idle/vault mix left is unchanged and a later loss hits every remaining member alike. | `MHCloseoutAccumulation::test_A1R2_06_cashSettlementKeepsTheMix_laterLossShared`; `MHAccumulationScenarios::test_R3_illiquidity_chunkedExit_inKindSettlement` |
| A-R2-07 | Low | **already-fixed** (test added) | Adapter views are read with bounded static calls that fail closed (`_read`), with a gas floor; `vaultSafe` and `revalidateVault` run the full walk (audit 2 R1-10). New: an allowlisted vault whose adapter stops answering is delisted by anyone, without a revert. | `MHCloseoutGovernance::test_A1R2_07_adapterLosesItsViews_revalidateDelists`; `MHAudit2Governance::test_A2R1_10_vaultSafeWalksAdapters_andRevalidateDelists`, `test_A2R1_28_adapterReadsFailClosed`, `test_A2R1_12_G16_gasLimitedCallsNeverDelistAnHonestVault` |
| A-R2-08 | Info | **already-fixed** | `cancelStalled` records COVERED for a non-defaulter it covers (not for a full draw, never for the recipient). | `MHAudit2Rotating::test_A2R1_12_R2_08_cancelStalledStrikesCoveredMember` |
| A-R2-09 | Info | **already-fixed** | Permissionless, NAV-free `cancelExpired` (audit R2-09; audit 2 R1-05..R1-07); the invariant handler's `driveToEnd` reaches an end state without the Guardian. | `MHAudit2Accumulation::test_A2R1_12_inv7_activeAndMaturedBrokenVault_noGuardian`, `test_A2R1_07_midLifeBreak_exitOpens90DaysAfterTheOutageStarts`; `invariant_accumulation` |
| A-R2-10 | Info | **acknowledged** (mitigated) | Audit 2 R1-08 made `flagRound` wait grace + cure, and `extendDeadline` needs no NAV, so the Guardian reopens rounds during a vault outage. An outage that outlasts grace + cure with no Guardian action still lets strikes land when the vault recovers: the same founder decision as audit 1 R1-08 (automatic outage relief). | `MHAudit2Accumulation::test_A2R1_08_navOutageAcrossGraceEnd_flagWaitsForTheCure`; `MHAuditRound1Accumulation::test_R1_03_activeBrokenVault_noStrikesWhileNobodyCanPay` |
| A-R2-11 | Info | **already-fixed** | `_requireUsdcLive` also reverts `CircleBlacklisted`, so every strike, penalty and stall gate treats a blacklisted circle like a pause. | `MHAudit2Rotating::test_A2R1_12_R2_11_blacklistedCircle_noStall`; `MHAudit2Accumulation::test_A2R1_05_circleBlacklisted_onlyGuardianCancels`; rotating invariant oracle `blacklistedStalls == 0` |
| A-R2-12 | Info | **acknowledged** (runbook) | The forced-inclusion race is answered by the cure gate in accumulation circles and the pre-signed L1 `OptimismPortal` deposits in the README Guardian runbook; the rotating half is B-R2-04 (acknowledged, same decision). | `MHAudit2Accumulation::test_A2R1_08_outageAcrossGraceEnd_guardianExtendsInTheCure`; `MHCloseoutRotating::test_A2R2_04_guardianExtendsDuringPause_noStrike` |
| A-R2-13 | Info | **already-fixed** | The R1-06 withdrawal lock uses the grace end without the Guardian's extension. | `MHAudit2Rotating::test_A2R1_12_R2_13_extensionDoesNotLiftWithdrawLock`; `MHCloseoutRotating::test_A2R2_14_R04_withdrawLockBoundary` |
| A-R2-14 | Info | **already-fixed** | The canceller protects a sentinel change only when paired with a real replacement of the sitting Guardian (audit 2 R1-16). | `MHGuardianCanceller.t.sol::test_singleWrapperSetIsSentinel_isCancellable_R2_14`; `MHAudit2Governance::test_A2R1_16_noOpRotation_protectsNothing`; `MHCloseoutGovernance::test_A2R2_14_C02_sentinelWordAboveOne_isCancellable` |
| A-R2-15 | Info | **acknowledged** (founder decision) | σ < 100% Trusted-tier economics (extends audit 1 R1-26a/R1-30): kept, with the `PositionWrittenOff` flag (audit 2 R1-02) and backend-enforced exposure caps. | `MHAudit2Rotating::test_A2R1_02_n20Collusion_writeOffIsFlagged`; `MHRotatingScenarios::test_D2_sigma50_slot1StopsAfterPayout` |
| A-R2-16 | Info | **already-fixed** (test added) | An EIP-7702 designator counts as code in `BuildBaseBatch._checkOwnersAreKeys` and `VerifyBase._isEoa`. No test covered a delegated owner: added (build and live Safes). | fork `SafeDeployRehearsal::test_A1R2_16_eip7702DelegatedOwner_isNotAKey` |
| A-R2-17 | Info | **already-fixed** (test added) | Per-role threshold policy `BaseChain.safePolicyOk` (Gov majority and ≥ 3 or 2-of-3; Guardian and Treasury ≥ half), in the build, offline and on chain. | `MHCloseoutScripts::test_A1R2_17_perRoleThresholdPolicy`; fork `test_build_rejectsSafeThresholdPolicy` |
| A-R2-18 | Info | **already-fixed** (test added) | `--signer` compares the tree with the audited commit with `deployments/` excluded and allows untracked files only in `deployments/<network>/`; this was only "exercised by hand". New shell regression on a throwaway git repository: the runbook layout passes, a tracked change, an untracked source and another inputs hash are refused. | `test/shell/check-manifest-bytecode.signer-layout.sh` (4/4); `test/shell/check-manifest-bytecode.args.sh` |
| A-R2-19 | Info | **fixed** | The invariant-6 per-dollar oracle allowed 2 pool shares; one unit of NAV rounding moves a cap by about `ρ = (T + 1e6)/(NAV + 1)` ≈ 1e6 shares. The bound is now derived: `v_i·P_j + (R + 2)·P_j + 4e6·P_i ≥ v_j·P_i` (R rounds of mint floors, two units of NAV rounding at ρ ≤ 2e6): a few USDC base units per member. | `invariant_accumulation` (2,000 × 150, below) |
| A-R2-20 | Info | **fixed** | Invariant 3 is also asserted against the holdings valued at the vault's own `convertToAssets` (balances less queued payouts and unswept donations), independently of the circle's counters: `Σ toAssets(bucket) ≤ held value` and `nav ≤ held value`; the same check in `AccumulationFixture._assertBuckets`, so every accumulation test runs it. | `invariant_accumulation`; every test calling `_assertBuckets` |
| A-R2-21 | Info | **fixed** (tests) | Killers for the six survivors, each verified by re-running the mutant (`closeout/mutate.py` in the build scratchpad, results below): A07 (`MHAudit2Accumulation::test_A2R1_12_A23_maturedCancel_allDelinquent_sharesForfeits`, already present), A04, A45, A39, G13 (= audit 2 G15, `test_A2R1_10_vaultSafeWalksAdapters_andRevalidateDelists`), R17 (= B-R2-14 R04). | `MHCloseoutAccumulation::test_A1R2_21_A04_returnedForfeitFeeRoundsDown`, `test_A1R2_21_A45_deployIdleOnlyWhileActive`, `test_A1R2_21_A39_flagWhileMatured_needsNoNav`; `MHCloseoutRotating::test_A2R2_14_R04_withdrawLockBoundary` |
| A-R2-22 | Info | **already-fixed** (test extended) | `amountDue` is 0 for a round not open yet; `_refund`'s NatSpec says the stall flag only moves the emitted E; `MHReputation` NatSpec corrected. `test_amountDue_cases` now checks the unopened round. | `MHRotatingCircle.t.sol::test_amountDue_cases` |
| B-R2-01 | Medium | **fixed** | Reproduced: a benign adapter-set change (or a precautionary `disallowVault`) let anyone latch `yieldOff` for good. Now nothing in the circle latches on the registry: `deployIdle` deposits only while `REGISTRY.vaultSafe(vault)` holds (else reverts `VaultUnsafe`), `pullFromVault` is open to anyone once the Guardian switched yield off **or** while the vault is not safe, the activating `join` no longer latches, and `syncVault` is removed. Only the Guardian's `emergencyExit`/`forceExit` set `yieldOff` (permanent). Trade-off below. | `MHCloseoutAccumulation::test_A2R2_01_adapterSetChange_noLatch_yieldResumes`, `test_A2R2_01_precautionaryDisallow_thenReallow_yieldResumes`, `test_A2R2_01_guardianSwitchOff_isPermanent`, `test_A2R2_01_sustainedUnsafe_noExposure`; updated `MHAudit2Accumulation::test_A2R1_09_*`/`test_A2R1_10_adapterTimelockDrop_isCaughtLive`, `MHAccumulationCircle.t.sol::test_join_lastJoinWithDelistedVault_pausesDepositsWithoutLatch`, `MHAuditRound1Accumulation` R1-04/R1-12 tests, `MHBoundaryGas::test_R8_boundary_pullFromVault_whileUnsafe`; invariant actions `reallowVault`, oracles "no deposit into an unsafe vault" and "no pull while yield on and the vault safe" |
| B-R2-02 | Low | **fixed** | Reproduced: a recipient `settleRound` cannot net (slot 1 at σ = 100% with a fee and no collateral) could prepay round 2, default round 1 and lose the prepayment as its penalty. `contribute` (new `_catchUp`) skips the caller's own unsettled round only when it is nettable; `amountDue` agrees. | `MHCloseoutRotating::test_A2R2_02_nonNettableRecipient_mustPayItsOwnRoundFirst`; rotating invariant oracle `prepaidDefaulters == 0` |
| B-R2-03 | Low | **fixed** | Reproduced: a member drawn in full for round s could not pay round s + 1 (both `amountDue` 0) and was struck LATE when s settled after s + 1's grace. `contribute(round)` now first satisfies every earlier unsettled round drawn in full from the caller's security (a zero-pull `contribute(r, 0)`, with its event), and `amountDue` simulates the same walk, so the app is asked for round s + 1 in its window. Found by the new overlapping-round fuzzer: a variant where the recipient's own round, settled late, drew the security that later rounds were shown as drawing (`amountDue` 0, then $50 due past grace); `_collect` now nets the recipient's whole own contribution from its payout and draws nothing from its security for it (same total for the recipient: cash + security). The walk is O(1) when the previous round is paid and at most `round − s` iterations; worst case n = 50, 49 rounds: 2,649,355 gas (cold, min tx gas). | `MHCloseoutRotating::test_A2R2_03_fullyDrawnRound_doesNotBlockTheNext`, `test_A2R2_03_ownRoundSettlement_keepsLaterRoundsDrawn`, `testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck` (10,000 runs); `MHAudit2Rotating::test_A2R1_11_ownRoundSkipped_fullyDrawnZeroPull` (updated); `MHGasBounds::test_gas_n50_contribute_catchUp49Rounds_cold` |
| B-R2-04 | Low | **acknowledged** | Reproduced: after a USDC pause (or a sequencer outage) that spans a rotating round's grace end, the first block can cover with a COVERED strike, a payment is LATE, and after a long pause a stall applies the DEFAULT penalty. Same root cause and decision as audit 1 R1-08 / R2-12 (automatic pause relief changes the timer semantics of both circles and the registry; founder decision). Mitigation, tested: `extendDeadline` works while USDC is paused and moves every rotating gate, so the Guardian runbook (now also for rotating circles, README) prevents it; a cure before covers would delay every honest recipient's payout. | `MHCloseoutRotating::test_A2R2_04_pinned_strikeInFirstBlockAfterPause_withoutGuardian`, `test_A2R2_04_guardianExtendsDuringPause_noStrike`; `MHAuditRound1Governance::test_R1_08_*` |
| B-R2-05 | Low | **fixed** | Reproduced: paying a round late through `depositCollateral` (the deposit makes the draw full) was never struck. A deposit after the settling round's grace that turns the caller's unpaid, short draw into a full one records LATE (not for a recipient `settleRound` can net, as in `contribute`; a smaller top-up is not a payment, `settleRound` still covers it, so a round is never struck twice). | `MHCloseoutRotating::test_A2R2_05_lateCollateral_isStruckLate`, `test_A2R2_05_otherDeposits_notStruck` |
| B-R2-06 | Low | **fixed** | Reproduced: once every member had exited, their forfeited yield waited for the end of the schedule (up to ~131 years). `finalize` now also runs as soon as `settledCount == n` while Active (everyone exited: nothing left to pay), returning each exiter its forfeit less the fee, exactly as at maturity. | `MHCloseoutAccumulation::test_A2R2_06_allExited_finalizeAtOnce`; invariant `finalize` oracle (window extended) |
| B-R2-07 | Low | **fixed** | Reproduced: `exitRound = currentRound()` stops at `totalRounds`, so skipping the last round and exiting after its deadline dodged its MISSED strike. After the last deadline `exitRound = totalRounds + 1`. The fuzz oracle no longer reads the contract's own `exitRound`: it recomputes it from the exit time, and members now also exit after the last deadline. | `MHCloseoutAccumulation::test_A2R2_07_lastRoundExit_afterDeadline_stillOwed`; `MHAccumulationFuzz::testFuzz_accumulation_paths` (kills the mutant) |
| B-R2-08 | Low | **fixed** (tooling, docs) | Reproduced inside the regression: a coordinator-substituted, policy-compliant Guardian Safe, Treasury Safe and operator pass the shape-only checks. New anchor: `MHManifestCheck.checkInputs(dir, inputsHash)`, `CheckManifest.run(string,bytes32)` and `check-manifest-bytecode.sh --signer <commit> --inputs-hash <hash>` (required in signer mode); README step 1 adds the signed ceremony record, step 5 has each signer rebuild from it. | `MHCloseoutScripts::test_A2R2_08_substitutedRoles_passShapeCheck_failInputsAnchor`; `test/shell/check-manifest-bytecode.signer-layout.sh`, `check-manifest-bytecode.args.sh` |
| B-R2-09 | Info | **acknowledged** | Guardian replacement takes the Timelock delay (48h, 7 days planned) while the vault exposure window is 3 days; no cheap code fix (a faster Guardian rotation weakens the Gov/Guardian separation). README Guardian runbook: on-call 2-of-4 quorum that survives two lost keys, and do not raise the Timelock delay above the vault's shortest exposure timelock without a founder decision. Spec amendment 6 below. | n/a (operations) |
| B-R2-10 | Info | **fixed** (docs) | `MHAccumulationCircle` NatSpec lists every Guardian power (forceExit choices and the 2% penalty, both cancel shapes, the extension budget, delisting); README "What a compromised Guardian can do"; the spec §5 playbook needs the same (amendment 7). | n/a |
| B-R2-11 | Info | **fixed** (docs) | `IMHAccumulationCircle` NatSpec: `CancelReason.Expired`, `claimShares`, `exitRound`, `feeBps`, `cure`, `forfeitSnap`, `yieldOff`, `YieldDisabled`, `ClaimAssigned`, `initialize`, `join`, `deployIdle`, `pullFromVault`, `finalize`. | n/a |
| B-R2-12 | Info | **acknowledged** | `cancelExpired` opens on one failed probe once `lastLive` is 90 days old, which a dormant circle can reach while healthy. A robust fix (arm on the first observed failure, fire only `EXPIRY_DELAY` later with no NAV read in between) changes the permissionless exit's state machine and every invariant-7 oracle: not a docs/script-level change, so recorded for founder sign-off. Exposure: needs a real valuation failure of the vault (the probe has a fixed 3M gas and cannot be starved, `test_A2R2_14_A63_probeGasGuard_expensiveHealthyVault`), and it ends in a no-fee NAV-free cancel with no loss of principal. README runbook: rounds ≤ 31 days, alert when `lastLive` is older than 60 days, finalize and settle promptly. | `MHAudit2Accumulation::test_A2R1_07_*` (current gate pinned) |
| B-R2-13 | Info | **acknowledged** | `forceExit` fixes adapter and market data at signing; an allocator that sees the pending Safe transaction can move funds first. A helper that reads the allocation at execution time is new code; runbook instead: one pre-built `forceExit` per funded market, signatures collected off the Safe Transaction Service, executed back to back. | n/a (runbook) |
| B-R2-14 | Info | **fixed** (tests) | Every listed survivor now has a killer, verified by re-running the mutant: R04, R09, A47, A20, A63, A55, A68 (both directions), G05, C02; `FeePaidInKind`, `SharesQueued` and `OwedSharesClaimed` asserted with their exact arguments; new overlapping-round fuzzer (random round length 7–30 days, cure up to 30 days, σ, fee, collateral, out-of-sequence payments, random keeper; property: a member that pays every non-zero `amountDue` when it sees it is never struck). | `MHCloseoutAccumulation::test_A2R2_14_*` (6), `MHCloseoutRotating::test_A2R2_14_*` (2 + the fuzzer), `MHCloseoutGovernance::test_A2R2_14_*` (2) |
| B-R2-15 | Info | **fixed** (script) | `VerifyBase` reads `LOG_CHUNK` (default 5,000, non-zero) for every log read: role events, `CallScheduled`, `VaultAllowed` and the vault scan. `run()` itself needs an RPC's logs and cannot run in a fork test (audit 2 R1-14); compiled and covered by `verifyAll` in the rehearsal. | fork `SafeDeployRehearsal::test_A2R1_14_verifyAll_endToEnd` |
| B-R2-16 | Info | **fixed** (script) | `CheckManifest` prints the Gov Safe domain hash and, per transaction (three batches, both allowVault transactions), the message hash and `safeTxHash`. Run by hand on a closeout ceremony (output kept in the build scratchpad, `closeout/checkmanifest-run.log`). | manual run; `MHCloseoutScripts` (the same plan) |
| B-R2-17 | Info | **fixed** (script) / acknowledged | `--signer` accepts only a full 40-character SHA or a tag (refs/tags), never a branch or an abbreviated SHA. The comparison of `creationCodeHash` values with the audit report stays manual by design (the report is the trust root); README says so. | `test/shell/check-manifest-bytecode.args.sh` (R2-17 cases) |
| B-R2-18 | Info | **acknowledged** (runbook) | Batch 2 leaves creation open; only the operator can create circles, so README step 7: the operator key is not given to the backend until steps 8 and 9 pass, and the Guardian pauses creation if either fails. Starting paused would change the registry and the ceremony (a Timelock unpause, 48h). | fork rehearsal logs `registry.creationPaused: false` |

### B-R2-01: the design and its trade-off

The yield switch had one bit, `yieldOff`, set by the Guardian and by anyone who saw `vaultSafe == false` (`syncVault`, `deployIdle`, the activating `join`), and never cleared. Any brief or routine unsafe reading therefore disabled yield for the rest of the circle's life (up to 131 years), and re-allowing the vault could not undo it.

Chosen design: **the registry is the live gate, and only the Guardian latches.**
- `deployIdle` deposits only while `REGISTRY.vaultSafe(vault)` holds; otherwise it reverts `VaultUnsafe` and stores nothing.
- `pullFromVault` is permissionless whenever the Guardian switched yield off, or while the registry does not consider the vault safe, so keepers still protect every circle on a delisted or weakened vault without the Guardian (audit 2 R1-09 kept).
- `yieldOff` is set only by `emergencyExit`/`forceExit`: the Guardian's decision is permanent.
- `syncVault` and the activation latch are removed.

Why it cannot be griefed: a third party cannot make `vaultSafe` false. It reads only the allowlist and the vault's governance state, with bounded, fail-closed adapter reads that revert `InsufficientGas` instead of answering false when starved (`test_A2R1_12_G16_gasLimitedCallsNeverDelistAnHonestVault`). During a genuine unsafe window, the most a griefer can do is pull the circle's shares to idle USDC, which is protective. The circle deposits again as soon as the registry says the vault is safe. The cost is the yield forgone during the window, plus gas and a few base units of vault rounding per round trip.

A sustained unsafe state still disables yield, without the Guardian: no deposit and anyone may pull, for as long as it lasts. A vault that is never allowed again means no yield for the rest of the circle's life.

Trade-off against a time-based latch ("latch after X days unsafe"):
- A time-based latch makes permanence depend on how fast Gov re-approves (at least 48h of Timelock plus the mandatory `CheckVaultPending` review). That recreates B-R2-01 for every re-approval slower than X.
- The live gate makes Gov's `allowVault` the single source of truth instead. The price is twofold:
  1. Once Gov re-allows a vault, every live circle on it deposits again. Gov must therefore re-allow only after the full review, which the runbook already requires for every allowVault. If the Guardian wants a circle out for good, it uses `emergencyExit`.
  2. A vault whose status flips repeatedly costs repeated pulls and re-deposits. That is bounded: each flip back needs a Timelock operation.

The accumulation runtime shrank by 228 bytes (EIP-170 margin 538 B, was 310 B).

### Spec amendments needed (founder sign-off; not edited, outside `contracts/`)
1. **§4.3 vault safety (B-R2-01; replaces audit 2 amendment 7).** "`deployIdle` deposits only while `REGISTRY.vaultSafe(vault)` holds (reverting `VaultUnsafe` otherwise); `pullFromVault` is permissionless once the Guardian switched yield off or while the vault is not safe; nothing is latched by the registry state; `yieldOff` is the Guardian's permanent switch. `disallowVault`/`revalidateVault` pause live circles' deposits until the vault is allowed again." `syncVault` is removed from the ABI (no TypeScript caller exists).
2. **§4.4/§4.5 rotating `contribute` (B-R2-02, B-R2-03; amends audit 2 amendment 3).** "Every earlier unsettled round must be paid, be the caller's own round when `settleRound` can net it, or be drawn in full from the caller's security, in which case the call satisfies it first with a zero pull; `amountDue` reports the pull after that walk."
3. **§4.5 rotating `settleRound` (B-R2-03; amends audit 1 amendment 3).** "The recipient's own unpaid contribution is netted from its payout in full when the payout can absorb it; nothing is drawn from its security for it."
4. **§4.4 strikes (B-R2-05).** "A collateral deposit after the settling round's grace that completes the member's unpaid draw for that round is a late payment (LATE)."
5. **§4.5 accumulation (B-R2-06, B-R2-07).** "`finalize` also runs once every member has exited." "After the last round's deadline an early exit still owes the last round."
6. **§5 Guardian (B-R2-09).** The Guardian's replacement (Timelock delay) is slower than the 3-day exposure window: keep the Timelock delay at or below the vault's shortest exposure timelock, or accept the gap explicitly.
7. **§5 Guardian-compromise playbook (B-R2-10).** List `forceExit` (adapter, data and amount chosen by the Guardian; ≤ 2% penalty of what is freed), both cancel shapes (no fee; Active without the delinquent cap), the extension budget, vault delisting (deposits pause) and Timelock cancellations.
8. **§5 ceremony (B-R2-08, B-R2-17, B-R2-18).** The signed ceremony record and its inputs hash; `--signer` takes a tag or a full SHA; the operator key is provisioned only after VerifyBase and Sourcify.
9. **Founder decisions still open:** B-R2-04 / A-R2-10 / A-R2-12 (automatic pause and outage relief), B-R2-12 (arm/fire `cancelExpired`), A-R2-15 (σ < 100% economics).

### Corrections to earlier notes
- **Audit 2 round-1 row R1-09** ("the switch sticks", `syncVault`) and **amendment 7** are superseded by B-R2-01 above.
- **Audit 1 R1-24 row and step-5 runbook text:** signers now also pass `--inputs-hash` (B-R2-08), and `--signer` must be a tag or a full SHA (B-R2-17).
- **Audit 2 R1-07 row (R1-07 / A1 R1-07 netting):** the recipient's own round is netted in full (B-R2-03); `OwnContributionNetted.amount` is always the contribution, and the accompanying `Contributed` event has zero amounts.

### Results
- **Reproduction first (list B):** on the unfixed code, B-R2-01, -02, -03, -04, -05, -06 and -07 each reproduced with a test asserting the reported behaviour (7/7 passed, i.e. reproduced; log and tests kept in the build scratchpad, `closeout/repro-before-fix.log`, `closeout/repro-tests/`). B-R2-08 is reproduced inside its regression (the plain check passes the substituted ceremony).
- **`forge build --sizes`: exit 0, every contract within EIP-170 / EIP-3860** (no negative margin in `--json`).

  | Contract | Runtime (B) | Initcode (B) | Runtime margin |
  |---|---|---|---|
  | MHAccumulationCircle | 24,038 (was 24,266) | 24,697 | **538** (was 310) |
  | MHRotatingCircle | 20,189 (was 19,377) | 20,792 | 4,387 |
  | TimelockController (OZ) | 6,550 | 7,468 | 18,026 |
  | MHCircleRegistry | 5,413 | 6,251 | 19,163 |
  | MHGuardianCanceller | 4,746 | 5,198 | 19,830 |
  | MHCircleFactory | 3,651 | 4,940 | 20,925 |
  | MHReputation | 2,027 | 2,400 | 22,549 |

  Ceremony gas on the fork rehearsal (Base block 52,933,005): batch 1a 4,790,809 simulated / 4,770,809 executed, batch 1b 5,651,221 / 5,628,421, batch 2 5,996,090 / 5,973,290; each under the 10M budget.
- **`forge test` (default profile): 457 passed, 0 failed, 4 skipped** (the four fork suites skip without `BASE_RPC_URL`); was 420. **`FOUNDRY_PROFILE=ci` (1,000 fuzz runs), every non-invariant suite: 455 passed, 0 failed, 4 skipped.** `testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck` also at 10,000 runs: pass.
- **Invariant suites at `FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=150` (300,000 calls each): `invariant_accumulation` passes (0 reverts, 647 s), `invariant_rotating` passes (1,171 handler-level reverts, the same rate as audit 2's 731 per 200,000; 681 s)**, with the A-R2-19 tolerance, the A-R2-20 holdings check, the B-R2-01 actions and oracles (`reallowVault`, no deposit into an unsafe vault, no pull while yield is on and the vault safe), the B-R2-06 finalize window and `prepaidDefaulters == 0` (B-R2-02). The CI profile (10,000 × 200) was not run (about an hour per suite).
- **Fork suites (`BASE_RPC_URL=https://mainnet.base.org`, block 52,933,005): 62 passed, 0 failed** (`SafeDeployRehearsal` 43 including the new A-R2-16 test, `MHCirclesFork` 8, `MHAuditRound1Fork` 5, `MHAudit2Fork` 6). `snapshots/circles-fork.json` was regenerated by that run; every entry moved by at most 0.1%.
- **Cold gas:** the new `contribute` catch-up at its bound (n = 50, 49 earlier rounds drawn in one call): 2,649,355 minimum transaction gas; the existing n = 50 worst cases are unchanged (the suite asserts them under 5M).
- **Mutation check of the closeout (`closeout/mutate.py`, `closeout/mutate2.py` and `closeout/mutants*.jsonl` in the build scratchpad, run on a scratch copy):** 32 mutants: each closeout fix reverted, and every survivor named in A-R2-21 and B-R2-14 re-expressed. **32/32 killed by the final suite.** One mutant (A68 with `<` instead of `<=`) first survived because the boundary case had `toShares(principal) == acc`; the test now moves the price first, which kills it. The B-R2-03 and B-R2-07 mutants are also killed by the fuzzers (`testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck`, `testFuzz_accumulation_paths`), not only by unit tests.
- **Shell:** `test/shell/check-manifest-bytecode.args.sh` 12/12 (4 new), `test/shell/check-manifest-bytecode.signer-layout.sh` 4/4 (new).
- **Slither 0.11.6 on `src/circles`** (`slither src/circles --config-file slither.config.json --fail-high`): exit 0, **0 High, 31 Medium, 31 Low, 4 Informational (66)**, was 64. The two new findings are false positives, triaged as in step 4: `incorrect-equality` in `pullFromVault` (the `shares == 0` zero sentinel, now flagged because the function first calls the registry) and `uninitialized-local` for `depositCollateral`'s `late` (a zero-initialised bool by design).
- **`forge fmt --check` and `forge lint`: clean** on `src`, `script` and every test directory except `test/vendor`. No try/catch, `tx.origin` or code-size check was added to `src/`. Every loop added is bounded: `_catchUp`/`amountDue` walk at most `round − nextSettle` rounds (≤ 49), nothing else loops.

### Open questions (closeout)
1. **Founder sign-off on amendments 1–8**, in particular the live yield gate (re-allowing a vault re-enables deposits in every live circle on it), the recipient's own round netted in full, `finalize` once everyone has exited, and LATE on late collateral.
2. **Automatic pause and outage relief** (B-R2-04, A-R2-10, A-R2-12; audit 1 R1-08): still a founder decision; the Guardian extension runbook is the control.
3. **B-R2-12:** arm/fire `cancelExpired` (the clock starting at the first observed failure) for founder sign-off; it changes invariant 7's permissionless path.
4. **B-R2-13:** a Guardian helper that force-exits from wherever the allocation is at execution time would need new code and an audit.
5. **B-R2-18:** start the registry with creation paused (a Timelock unpause after verification, +48h), or keep the runbook control.
6. **CI owner (`.github/`, outside this scope):** add `test/shell/check-manifest-bytecode.signer-layout.sh` and the `--inputs-hash` signer form to CI and the signer checklist; run the CI-profile invariants (10,000 × 200) on the audit commit.

## Closing-review fixes (closing review of the closeout, 2026-10-22)

Scope: the findings of the two closing reviewers of the closeout (rotating; accumulation and ceremony). **No medium-or-higher finding was reproduced.** The other five (one low, four informational) were each reproduced first: the four on-chain reviewer PoCs were replayed on the unfixed code and all passed, i.e. reproduced (`closing-review/repro-before-fix.log` in the build scratchpad); finding 3 had no PoC, so its regression was written first and run with the fix disabled (both tests fail, `closing-review/repro-cr03-unfixed.log`). Findings 1, 3 and 4 are fixed, with the reproduction kept as a regression that fails on the unfixed code (`repro-cr01-unfixed.log`, `repro-cr04-unfixed.log`). Findings 2 and 5 are acknowledged, with the PoC kept as a pinned test. New suites: `test/circles/MHClosingReviewRotating.t.sol` (10, one fuzz), `test/circles/MHClosingReviewAccumulation.t.sol` (5) and `test/script/MHClosingReviewScripts.t.sol` (2). Additions: `MHGasBounds` (1), `MHBoundaryGas` (2, and the accumulation probe now covers `registry.isAllowedVault`), and the accumulation invariant handler (a `curatorTimelock` action and two oracles). Three earlier tests were updated to the stricter behaviour (below). Nothing is committed. Work stayed inside `contracts/` (the spec, the app and `.github/` were not edited).

### Status by finding

| # | Finding | Sev. | Status | Change / reason | Covered by |
|---|---|---|---|---|---|
| CR-1 | A late collateral deposit was struck LATE only for the settling round, so one deposit could pay several overlapping overdue rounds with one strike, and whether round s + 1 was struck depended on keeper timing | Info | **fixed** | `depositCollateral` strikes every round the deposit pays (`_latePaid`). It walks the unsettled rounds from `nextSettle` in order, as `settleRound` would draw them, while they are past their grace end. Rounds the caller paid are skipped. Before the deposit, rounds drawn in full are consumed and the caller's own nettable round is skipped, until the first round it owes. From there, every round the deposit makes a full draw is LATE (its own round only if it cannot be netted). The walk stops at the first round still short. The result is the strikes of the `contribute` path, whatever the keeper's timing. The walk is bounded by `currentRound − nextSettle` (≤ 49); worst case at n = 50 (49 rounds paid late, 49 strikes): 1,744,300 gas cold. Runtime +235 B. | `MHClosingReviewRotating::test_CR_01_*` (9, including `testFuzz_CR_01_lateCollateral_matchesTheContributePath`, a differential fuzz against the `contribute` path); `MHGasBounds::test_gas_n50_depositCollateral_49LateRounds_cold`; `MHCloseoutRotating::test_A2R2_05_*` unchanged |
| CR-2 | A partially drawn paid-out member at σ < 100% keeps `c − draw` by skipping a stalled round; the creditors absorb it (the A-R2-05 equality holds only for a member drawn in full) | Info | **acknowledged** (founder decision) | No code fix short of the σ < 100% decision (audit 2 R1-02 / A-R2-15: continuation or wind-down). The A-R2-05 test docstring and the closeout note are narrowed to members drawn in full (correction below). README adds a Trusted-tier risk disclosure (the member skips its wallet part once a stall is visible, at the cost of one COVERED strike and a `PositionWrittenOff`), and step 12 indexes COVERED strikes together with `PositionWrittenOff` for the tier gate. | `MHClosingReviewRotating::test_CR_02_partiallyDrawnDebtor_skipKeepsTheWalletPart_pinned` (the reviewer PoC, pinned) |
| CR-3 | The ceremony inputs hash depended on the order of the Safe owners, while the README said "any order" | Info | **fixed** (tooling) | `MHDeployPlan.plan` sorts every Safe's owners ascending (`sortAddresses`, in place), so the manifest records and `inputsHash` hashes canonical lists, and a signer's re-run gives the same hash whatever order its ceremony record lists. `MHManifestCheck.policy` requires the recorded lists to be strictly ascending ("Safe owners sorted ascending"), so no non-canonical manifest passes. `BuildBaseBatch.approveAndSign` reuses the helper (its private `_sorted` copy was removed). Owner checks stay set-based everywhere (build, `VerifyBase`). README Inputs table says so. | `MHClosingReviewScripts::test_CR_03_ownerOrder_doesNotChangeTheInputsHash`, `test_CR_03_unsortedRecordedOwners_refused`; shell `check-manifest-bytecode.signer-layout.sh` 4/4, `.args.sh` 12/12; fork `SafeDeployRehearsal` (43) |
| CR-4 | B-R2-01 live gate: the vault's curator could make `vaultSafe` true again by itself (`increaseTimelock` is instant), so a keeper's pull was undone and anyone's `deployIdle` re-deposited with no Gov operation and no pending-submission scan, while data submitted in the weak window stayed executable | Low | **fixed** | A failing live check is now sticky at the registry level, which is Gov-reversible. `deployIdle` and `pullFromVault` call `REGISTRY.revalidateVault` (helper `_recheck`) instead of the view `vaultSafe`. In the weak window, `deployIdle` delists the vault and returns without depositing (so the delisting persists); on a vault already delisted it reverts `VaultUnsafe` as before. With yield on, `pullFromVault` delists and pulls in the same call. Deposits resume only after Gov's reviewed `allowVault`, whose mandatory `CheckVaultPending` scan finds what was submitted in the weak window. README keeper runbook: call `revalidateVault` first (a reverting pull also rolls the delisting back). README step 12: the Guardian monitor alerts on every `decreaseTimelock` Submit on the vault or its adapters that targets a checked selector, because the atomic variant is invisible to keepers. Runtime +68 B. | `MHClosingReviewAccumulation::test_CR_04_*` (4: the reviewer PoC asserting the fixed outcome on the real Vault V2, `deployIdle` in the window, the adapter `burnShares` variant, an honest vault never delisted); `MHBoundaryGas::test_R8_boundary_pullFromVault_weakWindowDelists`, `test_R8_boundary_deployIdle_weakWindowDelists`; invariant action `curatorTimelock` with the oracles "a `deployIdle` that finds an unsafe vault deposits nothing and leaves it delisted" and "a pull with yield on leaves no unsafe vault allowlisted"; updated `MHAudit2Accumulation::test_A2R1_10_adapterTimelockDrop_isCaughtLive`, `MHAuditRound1Accumulation::test_R1_12_weakenedVault_refusedLiveAndDelistable`, `test_R1_04_vaultSafe_neverCallsAdapters_butAdapterChangeIsUnsafe` (each now asserts the delisting and no deposit) |
| CR-5 | `exitEarly` has no in-kind fallback and, after A-R2-06, reverts whenever the vault is illiquid, even when idle USDC covers the exit | Info | **acknowledged** (docs) | Reproduced. Taking the exit from idle first would undo A-R2-06 (the order of exits would again shift a later loss), and an `exitEarlyInKind` is new member-facing code needing audit, with 470 B of EIP-170 margin left in `MHAccumulationCircle`. No funds are at risk: the maturity paths and claims keep their in-kind twins. `exitEarly` NatSpec and README now say early exits wait for vault liquidity; audit 2 amendment 11 and the exit-page copy need the same (amendment 3 below; the app is outside `contracts/`). | `MHClosingReviewAccumulation::test_CR_05_exitEarly_waitsForVaultLiquidity_pinned` (the reviewer PoC, plus the exit once liquidity returns, with the idle/vault mix kept) |

### CR-4: why registry-level stickiness keeps the B-R2-01 fix

B-R2-01 removed a per-circle latch that anyone could trigger and nobody could undo. That fix still holds:
- Nothing is latched in the circle. `yieldOff` stays the Guardian's switch.
- A delisting is undone by Gov's `allowVault`, which records the current adapter set and runs after the review and the scan.

The griefing surface is unchanged:
- `revalidateVault` was already permissionless.
- A third party still cannot make `vaultSafe` false.
- Starved adapter reads revert `InsufficientGas` instead of delisting. The two new boundary-gas tests show that every gas limit gives the full delisting, or nothing.

What changes is who can end the pause. In a weak window, any circle call (the backend's routine `deployIdle`, a keeper's pull) now ends the curator's ability to resume deposits on its own.

Residual:
- A curator that runs the matured `decreaseTimelock`, submits the sleeper and restores the timelock in one transaction defeats any live check. The control is the Guardian reacting to the 3-day-visible `decreaseTimelock` Submit (README step 12, B-R2-09).
- A `pullFromVault` that reverts (an illiquid vault, nothing to pull) also rolls back its delisting. Keepers therefore call `revalidateVault` first.

Gas: the Gauntlet `deployIdle` fork snapshot moved by +1,130 (+0.22%, one extra warm registry read).

### Spec amendments needed (founder sign-off; not edited, outside `contracts/`)
1. **§4.3 vault safety (CR-4; replaces closeout amendment 1).** "`deployIdle` and `pullFromVault` call `REGISTRY.revalidateVault`. A vault that fails the live check is delisted, and stays delisted until Gov's reviewed `allowVault`. `deployIdle` then returns without depositing; on a vault already delisted it reverts `VaultUnsafe`. `pullFromVault` is permissionless once the Guardian switched yield off, or while the vault is not safe. Nothing is latched in the circle; `yieldOff` is the Guardian's permanent switch."
2. **§4.4 strikes (CR-1; amends closeout amendment 4).** "A collateral deposit that completes the member's unpaid draw for one or more unsettled rounds past their grace is a late payment of each of them (one LATE per round). The rounds are walked in order, as `settleRound` would draw them. The member's own round that `settleRound` can net is never struck."
3. **Exit liveness (CR-5; corrects audit 2 amendment 11).** "A cash exit reverts while the vault is illiquid. Post-cancellation claims and maturity settlements have in-kind paths. An early exit has none and waits for liquidity." The app's exit page needs the same copy.
4. **§5 ceremony (CR-3).** Safe owners are given in any order. The planner records them sorted ascending, and the inputs hash is over the sorted lists.
5. **Trusted tier (CR-2).** Disclose the σ < 100% skip incentive (keep the wallet part, take one COVERED strike), and gate on COVERED strikes together with `PositionWrittenOff`. Still part of the open A-R2-15 decision.

### Corrections to earlier notes
- **Closeout row A-R2-05** ("doing nothing, withdrawing the maximum first, or satisfying the round give every member the same final position"): this holds for a paid-out member drawn in full for the stalled round. A member drawn only in part at σ < 100% keeps its wallet part by skipping (CR-2).
- **Closeout "B-R2-01: the design and its trade-off".** Two statements were true only if someone delisted the vault during the weak window: "each flip back needs a Timelock operation" and "keepers still protect every circle on a delisted or weakened vault without the Guardian". "The circle deposits again as soon as the registry says the vault is safe" now reads "once Gov allows the vault again". Since this round, any `deployIdle` or `pullFromVault` in the window delists the vault, so all three statements hold.
- **Closeout row B-R2-05 and amendment 4** ("the settling round"): now every unsettled round the deposit pays (CR-1).
- **Audit 2 amendment 11** ("a cash exit reverts while any vault share is illiquid, and the in-kind path applies"): no in-kind path exists for `exitEarly` (CR-5).

### Results
- **Reproduction first.** On the unfixed code, the reviewer PoCs all passed, i.e. reproduced: 6/6 tests (CR-1 2, CR-2 1, CR-4 2, CR-5 1; `closing-review/repro-before-fix.log`). CR-3's regressions fail 2/2 with the fix disabled. The new regressions fail on the unfixed code: rotating 5 of 8 (`repro-cr01-unfixed.log`; the other 3 are the in-window and partial-deposit controls and the pinned CR-2) and accumulation 3 of 5 (`repro-cr04-unfixed.log`; the honest-vault control and the pinned CR-5 pass on both). After the fixes, the reviewer PoCs that assert the old behaviour fail as intended (`reviewer-pocs-after-fix.log`). They were removed from `test/`; copies are in `closing-review/repro/`.
- **`forge build --sizes`: exit 0. Every contract is within EIP-170 / EIP-3860** (no negative margin in `--json`).

  | Contract | Runtime (B) | Initcode (B) | Runtime margin |
  |---|---|---|---|
  | MHAccumulationCircle | 24,106 (was 24,038) | 24,765 | **470** (was 538) |
  | MHRotatingCircle | 20,424 (was 20,189) | 21,027 | 4,152 |
  | TimelockController (OZ) | 6,550 | 7,468 | 18,026 |
  | MHCircleRegistry | 5,413 | 6,251 | 19,163 |
  | MHGuardianCanceller | 4,746 | 5,198 | 19,830 |
  | MHCircleFactory | 3,651 | 4,940 | 20,925 |
  | MHReputation | 2,027 | 2,400 | 22,549 |
- **`forge test` (default profile): 477 passed, 0 failed, 4 skipped.** That was 457 before: +17 in the three new suites, +1 gas bound, +2 boundary-gas. The four fork suites skip without `BASE_RPC_URL`. **`FOUNDRY_PROFILE=ci` (1,000 fuzz runs), every non-invariant suite: 475 passed, 0 failed, 4 skipped.** At 10,000 runs, `testFuzz_CR_01_lateCollateral_matchesTheContributePath` and `testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck` (the closeout's overlapping-round fuzzer, rerun because `depositCollateral` changed) both pass.
- **Invariant suites at `FOUNDRY_INVARIANT_RUNS=2000 FOUNDRY_INVARIANT_DEPTH=150` (300,000 calls each).**
  - **`invariant_accumulation` passes** (0 reverts, 656 s). It now includes the `curatorTimelock` action (7,508 calls) and the two CR-4 oracles. A 200-run check on a scratch copy confirms that the pull oracle catches the pre-fix `pullFromVault` ("pullFromVault left an unsafe vault allowlisted").
  - **`invariant_rotating` passes** (1,085 handler-level reverts, was 1,171; 486 s). That run compiled before two edits that do not change code: renaming `owed` to `owing` (slither `shadowing-local`) and a docstring. The runtime bytecode is identical apart from the CBOR metadata hash (compared).
  - The CI profile (10,000 × 200) was not run (about an hour per suite).
- **Fork suites (`BASE_RPC_URL=https://mainnet.base.org`, pinned block 52,933,005): 62 passed, 0 failed** (`SafeDeployRehearsal` 43, `MHCirclesFork` 8, `MHAuditRound1Fork` 5, `MHAudit2Fork` 6). The run regenerated `snapshots/circles-fork.json`. Against the values before the closeout (`closeout/circles-fork.before.json`), every entry is within 0.1%, except `accumulation.deployIdle (Gauntlet deposit)`: +1,130 gas (+0.22%), the extra registry read of CR-4.
- **Gas.**
  - `depositCollateral` worst case (n = 50, 49 rounds paid late, 49 LATE strikes): 1,744,300 minimum transaction gas, cold. The walk is bounded at 50 iterations.
  - The `contribute` catch-up is unchanged at 2,649,355.
  - Boundary-gas minima in the weak window: `pullFromVault` 88,659 and `deployIdle` 30,272 (warm harness). Every gas limit is atomic: full delisting or nothing.
- **Mutation check** (`closing-review/mutate_cr.py`, `mutate_cr04.py`, on a scratch copy):
  - CR-1: 8/8 killed (each step of `_latePaid` dropped or inverted, and the pre-fix "settling round only").
  - CR-4: 4/4 killed (revert instead of return, the view in `deployIdle` or in `pullFromVault`, ignoring the allowlist).
  - CR-3: with both checks disabled, both tests fail.
- **Shell:** `test/shell/check-manifest-bytecode.args.sh` 12/12, `test/shell/check-manifest-bytecode.signer-layout.sh` 4/4 (the generated ceremony now records sorted owners).
- **Slither 0.11.6 on `src/circles`** (`slither src/circles --config-file slither.config.json --fail-high`): exit 0, **0 High, 30 Medium, 33 Low, 4 Informational (67)**, was 66 (31/31/4). The new findings are false positives, triaged as in step 4:
  - `uninitialized-local` for `_latePaid`'s `owing`: a bool zero-initialised by design. It replaces the removed one for `depositCollateral`'s `late`.
  - `calls-loop` for the LATE strikes in `depositCollateral`: Reputation is trusted and never reverts for a registered reporter, as in `_strikeAll`.
  - Two `reentrancy-benign` in `deployIdle`: the trusted, immutable registry is called before the state writes, under `nonReentrant`. They replace the one previous finding.

  Removed: `incorrect-equality` in `pullFromVault`, the old `uninitialized-local` and the old `reentrancy-benign`. A `shadowing-local` on a first draft (`owed`) was fixed by the rename.
- **`forge fmt --check` and `forge lint`: clean** on `src`, `script` and every test directory except `test/vendor`. No try/catch, `tx.origin` or code-size check was added to `src/`. The only new loop (`_latePaid`, plus its strike loop over the same bitmap) is bounded by the rounds (≤ 50).

### Open questions (closing review)
1. **Founder sign-off on amendments 1–5,** in particular registry-level stickiness: a live-check failure seen by any circle call pauses deposits until Gov re-allows the vault.
2. **CR-5:** whether to add `exitEarlyInKind` (new code and audit; it would use much of the 470 B EIP-170 margin left in `MHAccumulationCircle`), or keep "early exits wait for liquidity".
3. **CR-2** is part of the σ < 100% decision (A-R2-15 / audit 2 R1-02), which is still open.
4. **Operations and backend:** the Guardian monitor rule for `decreaseTimelock` Submits that target a checked selector (vault and adapters), and the keeper's order (`revalidateVault`, then pull). The backend's `deployIdle` keeper must read `IdleDeployed`, not the transaction's success: a successful call without that event means the call delisted the vault (`VaultDisallowed` from the registry).
