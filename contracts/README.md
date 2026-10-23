# Moolahub circle contracts

Rotating and accumulation savings circles for Base (chain 8453), built to `docs/base-build-spec-v2.md` (build spec v3) §4 and §5. Foundry, Solidity 0.8.28 (EVM `cancun`), OpenZeppelin Contracts v5.1.0, forge-std v1.9.4.

> **Status: pre-audit. Nothing is deployed.** Circles ship in v1.1, behind the audit gate in spec §9: frozen commit, two audits, the §4.7 suites green on that commit, both rehearsals and `VerifyBase` passing, and a guarded launch. Design decisions, deviations from the spec and open questions are recorded step by step in [`IMPLEMENTATION_NOTES.md`](IMPLEMENTATION_NOTES.md).

Non-negotiables that every change has to keep:
- No admin, owner, guardian, operator or treasury path to member principal.
- No try/catch, no `tx.origin`, no code-size checks, no `receive`/`fallback` and no signature-based membership. EIP-7702 wallets must work.
- Every loop is bounded (at most 50 members).
- Every contract stays within 24,576 bytes of runtime code and 49,152 bytes of initcode.

## Layout

```
src/circles/                 the contracts (all deployed through the ceremony below)
  MHRotatingCircle.sol         rotating circle (EIP-1167 clone implementation; idle USDC only)
  MHAccumulationCircle.sol     accumulation circle (clone implementation; optional Morpho Vault V2)
  MHCircleBase.sol             shared base: immutables, _pay/owed/claimOwed, strikes, terms hash
  MHCircleFactory.sol          ownerless; operator-only, pausable, deterministic clones
  MHCircleRegistry.sol         Ownable2Step (Timelock): operator, guardian, treasury, pause, vault allowlist
  MHReputation.sol             Ownable2Step (Timelock): strike register; factory-registered reporters
  MHGuardianCanceller.sol      holds CANCELLER_ROLE; Guardian cancels anything except its own rotation
  MHCircleConstants.sol, MHCircleTypes.sol, MHCircleTerms.sol, interfaces/
script/
  BuildBaseBatch.s.sol         builds the Gov Safe batches + manifest (never broadcasts)
  VerifyBase.s.sol             read-only post-deployment assertions (re-derives the manifest first)
  CheckManifest.s.sol          offline: re-derives a ceremony directory from the manifest inputs (audit R1-05)
  check-manifest-bytecode.sh   offline: CheckManifest + local creation code (+ with --signer <audited tag or full
                               SHA from the AUDIT REPORT, never from the manifest> --inputs-hash <hash from the
                               independent ceremony record>: inputs anchor, git tree, deps and env checks)
  check-sourcify.sh            Sourcify exact-match check for every deployed contract
  ceremony/                    pinned Base addresses/codehashes, Safe/CreateX interfaces, planner, JSON writer,
                               MHManifestCheck (policy, re-derivation, independent decoding)
test/
  circles/                     unit, scenario, fuzz, boundary-gas, cold-gas, EIP-7702 suites
  circles/invariant/           invariant handlers and suites (spec §4.7)
  fork/                        Base mainnet fork suites, including the Safe deployment rehearsal
  script/                      offline tests of the ceremony planner, JSON writer and manifest checker
  mocks/                       MockUSDC (FiatToken-style blacklist/pause), MockVaultV2, mock circles, 7702 helper
deployments/                   ceremony output, one folder per chain (base-mainnet/, base-sepolia/);
                               the legacy *.json files at the top level are records of retired contracts
snapshots/circles-fork.json    gas snapshots written by the fork suite
```

## Setup

`lib/` is gitignored. Install the dependencies at the exact commits CI uses (`.github/workflows/contracts-ci.yml`):

```bash
cd contracts
fetch() { git init -q "$3" && git -C "$3" remote add origin "$1" &&
  git -C "$3" fetch -q --depth 1 origin "$2" && git -C "$3" checkout -q FETCH_HEAD; }
fetch https://github.com/OpenZeppelin/openzeppelin-contracts 69c8def5f222ff96f2b5beff05dfba996368aa79 lib/openzeppelin-contracts  # v5.1.0
fetch https://github.com/foundry-rs/forge-std 1eea5bae12ae557d589f9f0f0edae2faa47cb262 lib/forge-std                          # v1.9.4
foundryup --install v1.7.1   # forge 1.7.1 (4072e487)
```

Remapping auto-detection is off (`foundry.toml`): remappings are part of the solc metadata, so they are part of every initcode hash. If you change `foundry.toml` or `remappings.txt`, run `forge clean`, because forge's cache does not always notice the change. Source files are checked out with LF line endings (`.gitattributes`) for the same reason.

## Build and test

```bash
forge build --sizes                # fails if any runtime exceeds 24,576 B; CI also gates initcode at 49,152 B
forge test                         # default profile: 256 fuzz runs, invariants at 32 runs x depth 100
FOUNDRY_PROFILE=ci forge test      # spec §4.7 depth: 1,000 fuzz runs, invariants 10,000 x 200 (~1 h per suite)
forge fmt --check && forge lint
slither . --config-file slither.config.json   # 0.11.6; triage of every finding in IMPLEMENTATION_NOTES.md
bash test/shell/check-manifest-bytecode.args.sh   # argument handling of check-manifest-bytecode.sh (audit 2 R1-04, R1-15)
```

### Fork tests

The suites under `test/fork/` skip unless `BASE_RPC_URL` is set. They fork a pinned block, `BASE_FORK_BLOCK`, which defaults to 52,933,005 (the Appendix A check block), so the RPC must serve historical state.

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-path "test/fork/*"
```

- **`MHAudit2Fork.t.sol`** replays audit 2 R1-01 on Gauntlet: the curator (an allocator) points the liquidity adapter at a junk market and rugs it 3 days later; the Guardian's `forceExit` gets the circle out on day 1 (also with a 2% penalty, a zero liquidity adapter and an allocator re-allocating between transactions).
- **`MHCirclesFork.t.sol`** runs the circles against real USDC (including blacklist and pause through Circle's roles) and the Gauntlet USDC Prime Vault V2: real `allowVault` checks, NAV drift, illiquidity, `emergencyExit`. It runs isolated (`isolate = true`), because Vault V2 accrues interest once per transaction.
- **`SafeDeployRehearsal.t.sol`** is the spec §5 fork rehearsal:
  1. Deploys three real Safes (SafeL2 v1.4.1 from the canonical SafeProxyFactory): Gov 3-of-5, Guardian 2-of-4, Treasury 2-of-3.
  2. Runs `BuildBaseBatch` and reads the Transaction Builder files back.
  3. Executes the three batches (1a, 1b, 2) through the Gov Safe with pranked `approveHash` signatures.
  4. Runs every `VerifyBase` assertion.
  5. Smoke-tests the result:
     - the allowVault proposal through the Timelock;
     - a Guardian cancel, and the rotation the Guardian cannot cancel;
     - a Guardian pause;
     - a rotating circle to completion on real USDC;
     - an accumulation circle deposited into Gauntlet.
  6. Checks every refusal of the build script and the main `VerifyBase` tamper cases.

  Rehearsal output goes to `deployments/rehearsal/`, which is gitignored.

## Deployment ceremony (spec §5)

Nothing in this repo holds a key or broadcasts. The **Gov Safe deploys everything** through CreateX `deployCreate3` (batch 2 through Safe's `MultiSendCallOnly`; batches 1a and 1b call CreateX directly). Every salt is `GovSafe ‖ 0x01 ‖ 11 bytes`, so only the Gov Safe can deploy there, and only on this chain. Every address is therefore known before any code exists, and constructors take final addresses. No post-deployment wiring is needed except the timelocked `allowVault`.

| Role | Holder | Power |
|---|---|---|
| Gov Safe (3-of-5, at minimum 2-of-3) | SafeL2 v1.4.1 | Deploys; the only Timelock proposer and executor; also a canceller |
| Timelock | OZ `TimelockController`, 48h, admin renounced | Owns Registry and Reputation |
| Guardian Safe (2-of-4, keys separate from Gov) | SafeL2 v1.4.1 | `pauseCreation`, `disallowVault`, bounded circle actions, cancel via `MHGuardianCanceller` |
| Treasury Safe (2-of-3) | SafeL2 v1.4.1 | Receives fees |
| Operator | backend hot key | `createRotating` / `createAccumulation` only |
| Deployer EOA | none | Holds nothing (asserted) |

**Batch 1** (inert) deploys the circle implementations as two Safe transactions (audit 2 R1-25: together they no longer fit the 10M batch budget): **batch 1a** the rotating implementation, **batch 1b** the accumulation implementation. Each is a plain CALL to CreateX (operation 0), which is how Safe{Wallet}'s Transaction Builder sends a one-transaction file. **Batch 2** (atomic, a MultiSendCallOnly DELEGATECALL) runs, in order:
1. deploy the Timelock (Gov Safe as temporary admin);
2. deploy `MHGuardianCanceller`;
3. `grantRole(CANCELLER_ROLE, canceller)`;
4. deploy the Registry;
5. deploy Reputation (authorizer = the predicted Factory);
6. deploy the Factory (its constructor checks all the wiring);
7. `renounceRole(DEFAULT_ADMIN_ROLE, GovSafe)`.

Measured on the fork rehearsal (audit 2 round 1 code), batch 1a needs about 4.59M gas, batch 1b about 5.68M and batch 2 about 5.97M, each under the 10M budget; the script refuses to build a batch over 10M (with a 1% margin). The Gov Safe nonces are N (1a), N+1 (1b), N+2 (batch 2), then N+3 and N+4 for the allowVault schedule and execute transactions: reserve all five. If another transaction consumes one of them after batch 1a or 1b executed, the tooling cannot rebuild the later batches alone (the implementation addresses are taken, `AddressInUse`): restart the ceremony with a new `CREATE3_SALT_SEED` (the orphaned implementations hold nothing and are never wired).

### Inputs

`BuildBaseBatch` reads its inputs from the environment. **Every variable is required; there are no defaults.**

| Variable | Meaning / check |
|---|---|
| `USDC` | Must equal the chain's canonical USDC (8453: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`; 84532: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`); its proxy codehash is pinned |
| `GOV_SAFE`, `GOV_SAFE_OWNERS`, `GOV_SAFE_THRESHOLD` | The Safe must match owners (comma-separated, any order: the planner sorts them, and the manifest and `inputsHash` record them sorted ascending, so every signer's re-run gives the same hash whatever order its ceremony record lists them in) and threshold exactly. It must be a canonical SafeL2 v1.4.1 proxy, with no modules, no guard and the 1.4.1 fallback handler. Every owner is an EOA (no code, no EIP-7702 delegation) and no owner is a role. The threshold follows the spec §5 per-role policy (audit R2-17): at least 2 and below the owner count; Gov a strict majority and at least 3 (2-of-3 allowed); Guardian and Treasury at least half |
| `GUARDIAN_SAFE`, `GUARDIAN_SAFE_OWNERS`, `GUARDIAN_SAFE_THRESHOLD` | Same checks; no owner may also be a Gov owner |
| `TREASURY_SAFE`, `TREASURY_SAFE_OWNERS`, `TREASURY_SAFE_THRESHOLD` | Same checks |
| `OPERATOR` | Registry operator: a key with **no code** (audit 2 R1-26: a public call forwarder such as Multicall3 would let anyone create circles). Non-zero, distinct from every other role, and not an owner of any Safe |
| `CIRCLE_VAULT` | Vault V2 to allowlist after deployment, or `0x0000000000000000000000000000000000000000` for none. It must pass the same checks `allowVault` runs |
| `EARN_WRAPPER` | Timelock-owned Earn wrapper whose `setIsSentinel` the Guardian cannot cancel, or the zero address. Its `asset()` must be USDC |
| `TIMELOCK_DELAY` | Seconds, from 48h to 7 days |
| `ROTATING_FEE_BPS`, `ACCUMULATION_FEE_BPS` | Launch fee policy, at most 200 and 1,500. 0 at launch (decision 13) |
| `CREATE3_SALT_SEED` | 32 random bytes (`openssl rand -hex 32`), fixed for the ceremony so the manifest is reproducible |
| `GOV_SAFE_NONCE` | Gov Safe nonce for batch 1a (1b uses +1, batch 2 +2, the allowVault proposal +3 and +4). Must not be below the Safe's current nonce |
| `AUDITED_COMMIT` | The tagged audited commit (40 lowercase hex characters) |
| `DEPLOY_OUT_DIR` | Optional output directory (default `deployments/<network>`) |
| `CIRCLE_VAULT_FROM_BLOCK` | Required with a vault: the vault's creation block (Gauntlet USDC Prime: 37,179,342), checked against the factory's `CreateVaultV2` log. The pending-submission scan (audit R2-01) runs **before anything is written** (audit 2 R1-13), so a refused vault leaves no ceremony files |
| `LOG_CHUNK` | Optional `eth_getLogs` range for the scan (default 5,000; the RPC must serve archive logs) |
| `SKIP_VAULT_SCAN` | Test-only: honoured inside `forge test` (fork rehearsals), refused (`SkipScanOutsideTests`) in any `forge script` run |

The script also fails on:
- a chain other than 8453 or 84532;
- any external codehash that differs from `script/ceremony/BaseChain.sol` (CreateX, the Safe singleton, factory, MultiSendCallOnly and fallback handler);
- a zero, duplicate or sender-equal role;
- an address already in use;
- a Safe transaction hash that the Safe itself computes differently.

### Output (`deployments/<network>/`)

| File | Contents |
|---|---|
| `manifest.json` | Inputs, compiler settings, and for each contract its salt, guarded salt, address, creation-code hash, constructor args, initcode hash and size, and runtime codehash and size. For each batch: the exact Safe transaction (`to` = MultiSendCallOnly, `operation` 1, zero gas fields, nonce), plus the domain, message and `safeTxHash`. Also the allowVault Timelock operation |
| `batch1a-rotating-implementation.safe.json`, `batch1b-accumulation-implementation.safe.json`, `batch2-governance.safe.json` | Safe Transaction Builder files (format 1.0, valid `meta.checksum`), with the expected Safe transaction (`to`, operation) and `safeTxHash` in the description |
| `proposal-allow-vault.schedule.safe.json`, `.execute.safe.json` | Gov Safe calls to schedule `registry.allowVault(CIRCLE_VAULT)` on the Timelock and, after the delay, execute it |

The manifest depends only on the inputs and the compiled bytecode. Nothing in it depends on chain state, a timestamp or gas, so every signer can reproduce it byte for byte.

### Runbook

1. **Freeze.** Tag the audited commit. The audit report cites the tag (or full SHA) and every contract's `creationCodeHash` (`CheckManifest` prints them): they depend only on the audited source and the compiler settings, so they exist at audit time (audit 2 R1-04). The `initCodeHash` values also commit to the ceremony inputs, so a report written before the final manifest cannot cite them.
   **Ceremony record (audit 2 R2-08).** Before the build, the Gov signers agree on, and sign, the complete input list: every variable of the Inputs table (the Guardian and Treasury Safes with their owners and thresholds, `OPERATOR`, `CIRCLE_VAULT`, `EARN_WRAPPER`, `TIMELOCK_DELAY`, the fees, `CREATE3_SALT_SEED`, `GOV_SAFE_NONCE`, `AUDITED_COMMIT`). Each signer keeps it independently of the coordinator: it is the only thing that ties the non-Gov inputs to a decision (the ceremony policy checks only their shape).
2. **Rehearse on a fork.** Run `forge test --match-path test/fork/SafeDeployRehearsal.t.sol` with `BASE_RPC_URL` set.
3. **Rehearse on Base Sepolia.** Use real Sepolia Safes with the production shape. Set `CIRCLE_VAULT` to the zero address, since there is no Vault V2 on Sepolia USDC. Run the steps below with `--rpc-url base_sepolia`.
4. **Build** on a fork of the live chain. This dry run never broadcasts, and refuses `--broadcast`:
   ```bash
   forge clean && forge build
   CIRCLE_VAULT_FROM_BLOCK=37179342 forge script script/BuildBaseBatch.s.sol --rpc-url base --sender <your EOA>
   ```
   Pass `--sender`, so the "no role equals the sender" check covers the address you are running from.
   The script validates every input against the chain, scans the vault for pending submissions (and stops before writing anything if one exists), simulates the three batches through the real Gov Safe, and prints the addresses, every `safeTxHash` and the gas of each batch.
5. **Every signer reproduces** the build on their own machine with the inputs of the **ceremony record** (never the coordinator's environment file):
   - check out the audited commit, then run `forge clean && forge build`, re-run step 4 into a separate directory (below), and
     `script/check-manifest-bytecode.sh --signer <audited tag or full SHA from the AUDIT REPORT> --inputs-hash <inputsHash your own re-run printed> deployments/base-mainnet/manifest.json`.
     The `--signer` value must be a tag or the full 40-character SHA (audit 2 R2-17: never a branch or an abbreviated SHA), and signer mode fails without `--inputs-hash` (audit 2 R2-08: the manifest's inputs must hash to the record's; compare every input `CheckManifest` prints with the record as well).
     **Take the commit from the audit report, never from the manifest, the coordinator or the ceremony files**
     (audit 2 R1-04): the manifest records whatever commit the coordinator built, so anchoring to it accepts a
     backdoored build. The script refuses a path or a `.json` file as the commit. It needs no RPC. It
     re-applies the ceremony policy to the manifest's inputs, re-derives the manifest and every batch file from
     those inputs and requires byte equality, decodes every transaction the Gov Safe signs, recomputes every
     address, constructor argument list and `safeTxHash` independently of the planner, compares the local creation
     code, and checks that the audited commit is the manifest's `commit`, that every tracked file equals it with
     no untracked sources, and that `lib/` holds the pinned dependency commits (audit R1-05, R2-18);
   - re-run step 4 into a **separate** directory and diff it against the committed files (the default
     `DEPLOY_OUT_DIR` is the committed directory itself, so a plain re-run would overwrite what it should be
     compared with):
     ```bash
     DEPLOY_OUT_DIR=deployments/rehearsal/signer-check forge script script/BuildBaseBatch.s.sol --rpc-url base --sender <your EOA>
     diff -r deployments/base-mainnet deployments/rehearsal/signer-check
     ```
   - compare the `creationCodeHash` values `CheckManifest` prints with the ones the audit report cites (a manual comparison by design: the report is the trust root, audit 2 R2-17).
6. **Sign batches 1a and 1b.** Import `batch1a-rotating-implementation.safe.json`, then `batch1b-accumulation-implementation.safe.json`, into the Safe{Wallet} Transaction Builder. Before signing each, check against the manifest (`batches.batch1a`, `batches.batch1b`):
   - `to` is CreateX `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` and `operation` is 0 (a one-transaction file is sent as a plain CALL);
   - the nonce;
   - the `safeTxHash` / domain / message hashes, computed with `safe-tx-hashes-util` and compared with the hardware wallet's screen and with the values `CheckManifest` prints (it prints all three since audit 2 R2-16).

   Never copy calldata from a UI, and keep `safe-cli` as a second interface. Then execute.
7. **Sign batch 2** the same way, except that `to` is MultiSendCallOnly `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` and `operation` is 1 (DELEGATECALL); then note the block it executed in. Batch 2 leaves circle creation open (`creationPaused == false`, audit 2 R2-18): the operator key is not given to the backend, so no circle is created, until steps 8 and 9 pass; if either fails, the Guardian calls `registry.pauseCreation()` at once.
8. **Verify on chain.** This is read-only:
   ```bash
   MANIFEST_PATH=deployments/base-mainnet/manifest.json \
   DEPLOY_EOAS=<script sender>,<every Safe-tx executor> \
   BATCH2_BLOCK=<block of batch 2> \
   CIRCLE_VAULT_FROM_BLOCK=37179342 \
   forge script script/VerifyBase.s.sol --rpc-url base
   ```
   (`LOG_CHUNK` optional, as in step 4; it applies to every log read, audit 2 R2-15.)
   It asserts:
   - pinned external codehashes and the manifest's runtime codehashes;
   - `owner() == Timelock` and `pendingOwner() == 0`;
   - the exact Timelock roles, replayed from every `RoleGranted`/`RoleRevoked` since batch 2 and cross-checked with `hasRole`, plus the delay;
   - every registry, reputation, factory and canceller link and the implementation immutables;
   - `initialize` reverts on both implementations;
   - no role belongs to a deployment EOA, and the operator has no code (audit 2 R1-26);
   - canonical Safes with the manifest's owners and threshold, no modules and no guard;
   - nothing pending on the Timelock except the manifest's allowVault proposal, and the vault scan.
9. **Publish sources.** Verify on Sourcify first, then on Basescan, for each contract:
   ```bash
   forge verify-contract <address> src/circles/<File>.sol:<Name> --chain base --verifier sourcify
   # the Timelock is OpenZeppelin's, not under src/circles:
   forge verify-contract <timelock> lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController --chain base --verifier sourcify
   ```
   For Basescan add `--verifier etherscan --constructor-args <manifest constructorArgs>`. Then run `script/check-sourcify.sh deployments/base-mainnet/manifest.json`, which requires `exact_match` on every runtime.
10. **Allowlist the vault.** Run `script/CheckVaultPending.s.sol` (mandatory for **every** allowVault proposal, not just this one: it also pins the factory provenance and the Morpho adapter registry, and prints every allocator, whether the curator is one, the liquidity adapter and every capped id for explicit sign-off, audit 2 R1-23), then execute `proposal-allow-vault.schedule.safe.json`. Wait the Timelock delay, run `CheckVaultPending` again, and only then confirm and execute `proposal-allow-vault.execute.safe.json` (never confirm it together with the schedule transaction: anyone could relay a fully signed execute from the Safe Transaction Service the moment the delay ends, skipping the second scan).
11. **Hard-code the addresses** in app config.
12. **Alert** on `CallScheduled` (and on any whose data is larger than a few KB, audit 2 R1-18), `Cancelled`, `RoleGranted`, `OwnershipTransferStarted`, `GuardianSet`, `TreasurySet`, `VaultAllowed`, on wrapper and Gauntlet `Submit` events, and on the allocator powers no timelock bounds (audit 2 R1-01): `SetLiquidityAdapterAndData`, `Allocate`/`Deallocate` into a new market, `SetMaxRate`, `SetForceDeallocatePenalty` submissions. Alert on every `Submit` of `decreaseTimelock` on the vault or on any of its adapters whose target is a selector `allowVault` checks (closing review): a curator that executes the matured decrease, submits data and restores the timelock in one transaction is invisible to keepers, so such a Submit is a `disallowVault` trigger within its 3-day window. Index `PositionWrittenOff` (rotating, audit 2 R1-02) together with COVERED strikes for the Trusted-tier gate.

### Guardian runbook additions (audit 2 round 1)

- **Hostile allocator (R1-01).** If redemptions revert because the vault's liquidity adapter points at an empty market, use `circle.forceExit(adapter, marketParams, assets)` on every yield circle: it force-deallocates from a market that still holds the circle's funds and redeems in the same call (the vault's penalty, at most 2%, 0.001% on Gauntlet, comes from the circle's shares). `assets` = the position's value (`previewRedeem(vaultShares)`), or less if the market is short; repeat per market. A separate force-deallocation followed by `emergencyExit` does not work: the allocator re-allocates in between.
- **Delisted vault (R1-09, R2-01, closing review).** While the registry does not consider the vault safe (`disallowVault`, a `revalidateVault` delisting, or a live check failing, such as a lowered curator timelock or an adapter-set change awaiting re-approval), no circle deposits and anyone may call `pullFromVault` in chunks. A circle call that finds an allowlisted vault failing the live check delists it in the registry: `deployIdle` then returns without depositing, and `pullFromVault` delists and pulls in the same call. So a curator that restores the checked state on its own (`increaseTimelock` is instant) cannot re-enable deposits: they resume only once Gov allows the vault again, after the mandatory `CheckVaultPending` scan (which finds anything submitted in the weak window). Keeper: on every live-check failure call `revalidateVault(vault)` first (it delists even when a circle has nothing to pull or the pull reverts while the vault is illiquid), then `pullFromVault` in chunks on every circle using the vault. Nothing is latched in the circle (`syncVault` is gone); only the Guardian's `emergencyExit`/`forceExit` switch a circle's yield off for good.
- **Outage across a grace end (R1-08, R1-22).** Accumulation `flagRound`/`finalize` now wait grace + cure (at least 72h), so the Guardian extends within the cure. For a sequencer outage, keep pre-signed Guardian `extendDeadline` Safe transactions ready to submit as L1 `OptimismPortal` deposits (ordered before L2 user transactions). The 30-day extension budget is per circle for its whole life; a compromised Guardian can exhaust it (add to the Guardian-compromise playbook).
- **Vault that cannot value its shares (R1-05..R1-07).** Members get `cancelExpired` 90 days after the vault last valued the circle's shares (`lastLive`), only while it still cannot and USDC is live. The member exit page calls `finalize` / `settleMember(InKind)` first; `cancelExpired` reverts `NavReadable` whenever those work.
- **Oversized Timelock operation (R1-18).** An operation with more than ~128 KB of calldata cannot be cancelled with a normal Safe transaction; keep a Guardian helper that rebuilds the calldata on chain from the `CallScheduled` logs (staged across transactions) ready, and alert on large `CallScheduled` data.
- **Round-1 stall (R1-20).** When round 1 is past grace with a gap nobody can cover, the Guardian calls `guardianCancel` right away instead of letting the members wait for the cure.

### Guardian runbook additions (audit 2 round 2, closeout)

- **USDC pause or sequencer outage, rotating circles (R2-04).** As for accumulation circles: on a USDC `Pause` the Guardian extends every Active rotating circle while paused (`extendDeadline` works then, and the extension moves the cover, LATE and stall gates); otherwise covers with COVERED strikes, LATE strikes and, after a long pause, DEFAULT penalties can land in the first block after the unpause. For a sequencer outage, the pre-signed L1 `OptimismPortal` deposits of the round-1 runbook.
- **Guardian replacement is slower than the exposure window (R2-09).** Replacing the Guardian takes the Timelock delay (48h; 7 days planned), while a harmful curator change on the vault (caps, fees, an adapter's `burnShares`) needs only 3 days and only the Guardian can exit before it (keepers act on the registry's live checks, which pending submissions do not change). Keep the Guardian on call with a 2-of-4 quorum that survives the loss of two keys, and do not raise the Timelock delay above the vault's shortest exposure timelock unless the founder accepts that gap.
- **What a compromised Guardian can do (R2-10).** Never touch principal, but: switch yield off for good (`emergencyExit`, `forceExit`, choosing the adapter, the market data and the amount; the vault's force-deallocation penalty, at most 2% of what is freed, comes out of the circle), cancel an Active circle (claims by shares, no delinquent cap, no fee) or a Matured one (finalize outcomes, no fee), spend the 30-day extension budget of every circle, delist the vault (deposits pause), pause creation, and cancel Timelock operations other than its own replacement. The Guardian-compromise playbook (spec §5) must list these.
- **Stale `lastLive` (R2-12, acknowledged).** `cancelExpired` opens 90 days after the last state-changing NAV read if the probe fails at that moment; a dormant circle (a Matured circle nobody settles, or rounds close to 92 days) can reach that point while healthy. Keep product rounds at or below 31 days, alert when a yield circle's `lastLive` is older than 60 days, and have the keeper settle or finalize promptly.
- **`forceExit` needs the funds where the Guardian signed for them (R2-13, acknowledged).** An allocator that sees the pending Safe transaction can move the allocation to another market first. Prepare one `forceExit` per market that holds the vault's funds (the capped ids `CheckVaultPending` prints), collect signatures off the Safe Transaction Service, and execute them back to back; repeat with the new market if one reverts.

### Runbook and disclosure additions (closing review)

- **Trusted-tier risk disclosure (σ < 100%).** A paid-out member at σ < 100% whose security covers only part of a round (it owes `c − draw` from its wallet) can keep that wallet part by skipping once another member's default makes a stall visible: the stall cover leaves its security below its backing, and the shortfall is written off against the creditors. Its cost is one COVERED strike and a `PositionWrittenOff` event; the Trusted-tier gate reads both. A member drawn in full for the round has no such choice. Same founder decision as audit 2 R1-02 / A-R2-15 (σ < 100% economics).
- **Early exits wait for vault liquidity.** `exitEarly` takes the exit's pro-rata share of idle USDC and withdraws the rest from the vault (audit R2-06), and it has no in-kind path, so while the vault is illiquid (a Morpho market at 100% utilisation) every early exit reverts, even when the circle's idle USDC would cover it. The exit page says so and offers a retry; settlements at maturity and claims after a cancellation keep their in-kind paths.
- **Late collateral.** A collateral deposit that completes a member's draw for several overlapping unsettled rounds past their grace is struck LATE once per round it pays, as paying them through `contribute` would be.

Incident playbooks (pause, Morpho impaired, Gov signer compromised, Guardian compromised) are in spec §5.
