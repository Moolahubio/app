// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { IUSDC } from "../src/circles/interfaces/IUSDC.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "../src/circles/interfaces/IVaultV2.sol";
import { IMHCircleRegistry } from "../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../src/circles/interfaces/IMHReputation.sol";
import { MHCircleConstants } from "../src/circles/MHCircleConstants.sol";

import { BaseChain } from "./ceremony/BaseChain.sol";
import { ISafe, ICreateX, IVaultV2FactoryView } from "./ceremony/DeployInterfaces.sol";
import {
    MHDeployPlan,
    DeployConfig,
    SafeSpec,
    Plan,
    Deployment,
    SafeBatch
} from "./ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "./ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "./ceremony/MHManifestCheck.sol";
import { MHVaultPending } from "./ceremony/MHVaultPending.sol";

/// @notice Foundry cheatcode (forge >= 1.0) not declared in forge-std v1.9.4: marks `target` and all of its storage
///         slots as cold.
interface IVmCool {
    /// @notice Marks `target` and its storage cold.
    function cool(address target) external;
}

/// @title BuildBaseBatch
/// @notice Builds the spec §5 deployment ceremony for the Gov Safe. It NEVER broadcasts: it has no
///         `vm.broadcast`, and it refuses to run under `forge script --broadcast` or `--resume`.
///
///         Inputs (environment, all required, no defaults):
///           USDC, OPERATOR, CIRCLE_VAULT (0x0 = none), EARN_WRAPPER (0x0 = none), TIMELOCK_DELAY (seconds),
///           ROTATING_FEE_BPS, ACCUMULATION_FEE_BPS, CREATE3_SALT_SEED (bytes32), GOV_SAFE_NONCE, AUDITED_COMMIT,
///           and for each of GOV, GUARDIAN, TREASURY: <X>_SAFE, <X>_SAFE_OWNERS (comma-separated),
///           <X>_SAFE_THRESHOLD.
///         Optional: DEPLOY_OUT_DIR (default `deployments/<network>`).
///         With a vault, also CIRCLE_VAULT_FROM_BLOCK (the vault's creation block) and optionally LOG_CHUNK: `run`
///         scans every `Submit` of the vault and its adapters and refuses any pending submission (audit R2-01),
///         before writing anything (audit 2 R1-13). `SKIP_VAULT_SCAN=true` skips it only inside `forge test` (fork
///         rehearsals); a `forge script` run refuses it. `CheckVaultPending` stays mandatory at runbook step 10.
///
///         It validates every input against the live chain (fork), plans the CreateX `deployCreate3` deployments
///         with guarded salts `GovSafe ‖ 0x01 ‖ 11 bytes`, simulates the three batches through the real Gov Safe
///         (pranked `approveHash`, then `execTransaction`, all reverted afterwards), and writes under the out dir:
///           - `manifest.json`: salts, initcode hashes, predicted addresses, runtime codehashes, Safe tx hashes;
///           - `batch1a-rotating-implementation.safe.json`, `batch1b-accumulation-implementation.safe.json`,
///             `batch2-governance.safe.json`: Safe Transaction Builder files (audit 2 R1-25: three batches);
///           - `proposal-allow-vault.{schedule,execute}.safe.json` when CIRCLE_VAULT is set.
///         The manifest depends only on the inputs and the compiled bytecode, so every signer reproduces it.
///
///         Run: `forge script script/BuildBaseBatch.s.sol --rpc-url base` (or `base_sepolia` for the rehearsal).
contract BuildBaseBatch is Script {
    // ---------------------------------------------------------------- Errors

    /// @notice Run under `--broadcast`/`--resume`; this script must never broadcast.
    error NeverBroadcast();
    /// @notice The chain is neither Base (8453) nor Base Sepolia (84532).
    error UnsupportedChain(uint256 chainId);
    /// @notice The USDC input is not the canonical USDC of this chain.
    error WrongUsdc(address expected, address given);
    /// @notice An external contract's runtime codehash differs from the pinned value.
    error CodehashMismatch(string what, address at, bytes32 expected, bytes32 actual);
    /// @notice A role is address(0).
    error ZeroRole(string role);
    /// @notice Two roles (or a role and the vault/wrapper) share an address.
    error DuplicateRole(string a, string b);
    /// @notice A role equals the script's sender (a deployment EOA).
    error RoleIsSender(string role, address sender);
    /// @notice An address that must be a contract has no code.
    error NotAContract(string what, address at);
    /// @notice The Safe's singleton is not SafeL2 v1.4.1.
    error SafeSingletonMismatch(string safe, address singleton);
    /// @notice The Safe's threshold differs from the expected one.
    error SafeThresholdMismatch(string safe, uint256 expected, uint256 actual);
    /// @notice The Safe's owners differ from the expected set.
    error SafeOwnersMismatch(string safe);
    /// @notice The expected owner list contains address(0), the sentinel or a duplicate.
    error SafeOwnerInvalid(string safe, address owner);
    /// @notice Threshold below 2, or not below the owner count (no spare key).
    error SafeThresholdPolicy(string safe, uint256 threshold, uint256 owners);
    /// @notice The Safe has at least one module enabled.
    error SafeHasModules(string safe);
    /// @notice The Safe has a guard set.
    error SafeHasGuard(string safe, address guard);
    /// @notice The Safe's fallback handler is not CompatibilityFallbackHandler v1.4.1.
    error SafeFallbackHandlerMismatch(string safe, address handler);
    /// @notice A key is an owner of both the Gov and the Guardian Safe (spec: Guardian on separate keys).
    error SafeKeysShared(address owner);
    /// @notice The operator hot key is an owner of one of the Safes.
    error OperatorIsSafeOwner(address operator);
    /// @notice A Safe owner has code: a contract (another Safe, a module) or an EIP-7702-delegated account (audit
    ///         R1-17, R2-16).
    error SafeOwnerNotEoa(string safe, address owner);
    /// @notice A Safe owner is a role address: another Safe, the operator, the vault or the wrapper (R1-17).
    error SafeOwnerIsRole(string safe, address owner);
    /// @notice The circle vault's `asset()` is not USDC.
    error VaultNotUsdc(address vault, address asset);
    /// @notice The circle vault fails a `registry.allowVault` check (it would revert when executed).
    error VaultCheckFailed(address vault, bytes4 check);
    /// @notice CIRCLE_VAULT is not the vault pinned for this chain in `BaseChain` (audit R2-03).
    error VaultNotPinned(address expected, address given);
    /// @notice The circle vault was not created by the pinned Vault V2 factory (provenance).
    error VaultNotFromFactory(address vault, address factory);
    /// @notice The circle vault's adapter registry is not the pinned Morpho registry (audit R2-01 (d)).
    error AdapterRegistryNotPinned(address expected, address actual);
    /// @notice A vault is set but CIRCLE_VAULT_FROM_BLOCK is not (the pending-submission scan is mandatory).
    error VaultScanInputMissing();
    /// @notice SKIP_VAULT_SCAN outside `forge test` (audit 2 R1-13: a real ceremony always scans).
    error SkipScanOutsideTests();
    /// @notice The operator has code: a contract that makes itself `msg.sender` for anyone (a call forwarder such as
    ///         Multicall3 or MultiSendCallOnly) would let anyone create circles (audit 2 R1-26).
    error OperatorNotEoa(address operator);
    /// @notice The simulated runtime code differs from the one derived offline from the local build (audit R2-04).
    error RuntimeDerivationMismatch(string key);
    /// @notice The Earn wrapper's `asset()` is not USDC.
    error WrapperNotUsdc(address wrapper, address asset);
    /// @notice A fee is above its on-chain cap.
    error FeeAboveCap(string fee, uint256 bps, uint256 cap);
    /// @notice The Timelock delay is outside [48h, 7 days].
    error DelayOutOfRange(uint256 delay);
    /// @notice CREATE3_SALT_SEED is zero.
    error ZeroSaltSeed();
    /// @notice AUDITED_COMMIT is not 40 lowercase hex characters.
    error BadCommit(string commit);
    /// @notice GOV_SAFE_NONCE is below the Safe's current nonce (already used).
    error NonceAlreadyUsed(uint256 safeNonce, uint256 given);
    /// @notice A predicted address already has code (salt already used).
    error AddressInUse(string key, address at);
    /// @notice The local CREATE3 address differs from CreateX's own computation, or from the deployed one.
    error AddressMismatch(string key, address predicted, address actual);
    /// @notice The local Safe transaction hash differs from the Safe's own `getTransactionHash`.
    error SafeTxHashMismatch(string batch, bytes32 local, bytes32 onchain);
    /// @notice An initcode is above 49,152 bytes.
    error InitCodeTooLarge(string key, uint256 size);
    /// @notice A runtime code is above 24,576 bytes.
    error RuntimeTooLarge(string key, uint256 size);
    /// @notice A batch's simulated transaction gas plus a 1% margin exceeds 10M.
    error BatchGasTooHigh(string batch, uint256 gas);
    /// @notice The simulated deployment does not have the expected state.
    error SimulationStateMismatch(string what);

    /// @notice Address used to submit `execTransaction` in the simulation (a stand-in for a signer EOA).
    address internal constant SIM_EXECUTOR =
        address(uint160(uint256(keccak256("moolahub.ceremony.executor"))));

    // ================================================================ Entry points

    /// @notice Reads the environment, validates it, runs the vault's pending-submission scan (audit R2-01), then
    ///         builds, simulates and writes the batch files and the manifest. Audit 2 R1-13: the scan and its inputs
    ///         come first, so a refused vault (or a missing scan input) leaves nothing on disk.
    function run() external {
        _neverBroadcast();
        DeployConfig memory cfg = loadConfig();
        string memory outDir =
            vm.envOr("DEPLOY_OUT_DIR", string.concat("deployments/", BaseChain.networkOf(block.chainid)));
        validate(cfg);
        if (cfg.circleVault != address(0)) _scanVault(cfg.circleVault);
        build(cfg, outDir);
    }

    /// @dev The mandatory pending-submission scan of the vault and its adapters (audit R2-01). `SKIP_VAULT_SCAN=true`
    ///      is honoured only inside `forge test` (the fork rehearsals), never in a `forge script` run (audit 2 R1-13).
    function _scanVault(address vault) private {
        if (vm.envOr("SKIP_VAULT_SCAN", false)) {
            if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) revert SkipScanOutsideTests();
            console2.log("  WARNING: SKIP_VAULT_SCAN set (test only); run script/CheckVaultPending.s.sol");
            return;
        }
        if (!vm.envExists("CIRCLE_VAULT_FROM_BLOCK")) revert VaultScanInputMissing();
        uint256 scanned = MHVaultPending.scan(
            vault,
            BaseChain.VAULT_V2_FACTORY_BASE,
            vm.envUint("CIRCLE_VAULT_FROM_BLOCK"),
            block.number,
            vm.envOr("LOG_CHUNK", uint256(5_000))
        );
        console2.log("  vault pending-submission scan: none pending; Submit logs read:", scanned);
    }

    /// @notice Reads every input from the environment. A missing variable reverts (no defaults).
    /// @return cfg The configuration (not yet validated).
    function loadConfig() public view returns (DeployConfig memory cfg) {
        cfg.usdc = vm.envAddress("USDC");
        cfg.gov = _loadSafe("GOV");
        cfg.guardian = _loadSafe("GUARDIAN");
        cfg.treasury = _loadSafe("TREASURY");
        cfg.operator = vm.envAddress("OPERATOR");
        cfg.circleVault = vm.envAddress("CIRCLE_VAULT");
        cfg.earnWrapper = vm.envAddress("EARN_WRAPPER");
        cfg.timelockDelay = vm.envUint("TIMELOCK_DELAY");
        cfg.rotatingFeeBps = vm.envUint("ROTATING_FEE_BPS");
        cfg.accumulationFeeBps = vm.envUint("ACCUMULATION_FEE_BPS");
        cfg.saltSeed = vm.envBytes32("CREATE3_SALT_SEED");
        cfg.govNonce = vm.envUint("GOV_SAFE_NONCE");
        cfg.commit = vm.envString("AUDITED_COMMIT");
    }

    /// @notice Validates `cfg` against the chain, plans, simulates and writes the files to `outDir`.
    /// @param cfg The configuration.
    /// @param outDir Output directory (must be under `deployments/`, the only writable path).
    /// @return p The plan, with runtime codehashes and simulated gas.
    function build(DeployConfig memory cfg, string memory outDir) public returns (Plan memory p) {
        _neverBroadcast();
        validate(cfg);
        p = MHDeployPlan.plan(cfg, block.chainid);
        checkPlan(p);
        simulate(p);
        _checkRuntimeDerivation(p);
        _write(p, outDir);
        _log(p, outDir);
    }

    // ================================================================ Validation (read-only)

    /// @notice Every spec §5 input check, against the live chain. Reverts with a specific error on the first failure.
    /// @param cfg The configuration.
    function validate(DeployConfig memory cfg) public view {
        // Chain and pinned external contracts.
        (address usdc, bytes32 usdcHash) = BaseChain.usdcOf(block.chainid);
        if (usdc == address(0)) revert UnsupportedChain(block.chainid);
        if (cfg.usdc != usdc) revert WrongUsdc(usdc, cfg.usdc);
        _codehash("USDC", usdc, usdcHash);
        _codehash("CreateX", BaseChain.CREATEX, BaseChain.CREATEX_CODEHASH);
        _codehash("MultiSendCallOnly", BaseChain.MULTISEND_CALL_ONLY, BaseChain.MULTISEND_CALL_ONLY_CODEHASH);
        _codehash("SafeL2", BaseChain.SAFE_L2, BaseChain.SAFE_L2_CODEHASH);
        _codehash("SafeProxyFactory", BaseChain.SAFE_PROXY_FACTORY, BaseChain.SAFE_PROXY_FACTORY_CODEHASH);
        _codehash(
            "CompatibilityFallbackHandler", BaseChain.FALLBACK_HANDLER, BaseChain.FALLBACK_HANDLER_CODEHASH
        );
        // Both views the circles rely on must respond; decimals pins the unit.
        IUSDC(usdc).isBlacklisted(address(0));
        IUSDC(usdc).paused();
        if (IERC20Metadata(usdc).decimals() != 6) revert WrongUsdc(usdc, cfg.usdc);

        _checkRoles(cfg);

        _checkSafe("gov", BaseChain.ROLE_GOV, cfg.gov);
        _checkSafe("guardian", BaseChain.ROLE_GUARDIAN, cfg.guardian);
        _checkSafe("treasury", BaseChain.ROLE_TREASURY, cfg.treasury);
        _checkKeySeparation(cfg);
        _checkOwnersAreKeys(cfg);

        if (cfg.circleVault != address(0)) {
            _checkVault(cfg.circleVault, usdc);
            // Audit R2-03: the vault no initcode or batch hash commits to must be the one pinned in reviewed source.
            address pinned = BaseChain.circleVaultOf(block.chainid);
            if (cfg.circleVault != pinned) revert VaultNotPinned(pinned, cfg.circleVault);
        }
        if (cfg.earnWrapper != address(0)) {
            if (cfg.earnWrapper.code.length == 0) revert NotAContract("EARN_WRAPPER", cfg.earnWrapper);
            address asset = IVaultV2(cfg.earnWrapper).asset();
            if (asset != usdc) revert WrapperNotUsdc(cfg.earnWrapper, asset);
        }

        if (cfg.rotatingFeeBps > MHCircleConstants.MAX_ROTATING_FEE_BPS) {
            revert FeeAboveCap("ROTATING_FEE_BPS", cfg.rotatingFeeBps, MHCircleConstants.MAX_ROTATING_FEE_BPS);
        }
        if (cfg.accumulationFeeBps > MHCircleConstants.MAX_ACCUMULATION_FEE_BPS) {
            revert FeeAboveCap(
                "ACCUMULATION_FEE_BPS", cfg.accumulationFeeBps, MHCircleConstants.MAX_ACCUMULATION_FEE_BPS
            );
        }
        if (
            cfg.timelockDelay < BaseChain.MIN_TIMELOCK_DELAY
                || cfg.timelockDelay > BaseChain.MAX_TIMELOCK_DELAY
        ) {
            revert DelayOutOfRange(cfg.timelockDelay);
        }
        if (cfg.saltSeed == bytes32(0)) revert ZeroSaltSeed();
        _checkCommit(cfg.commit);
        uint256 current = ISafe(cfg.gov.safe).nonce();
        if (cfg.govNonce < current) revert NonceAlreadyUsed(current, cfg.govNonce);
    }

    /// @notice Plan-level checks against the chain: CreateX agrees on every address, no address is taken, every
    ///         initcode fits EIP-3860, and the Gov Safe agrees on every Safe transaction hash.
    /// @param p The plan.
    function checkPlan(Plan memory p) public view {
        for (uint256 i; i < p.deployments.length; ++i) {
            Deployment memory d = p.deployments[i];
            address onchain =
                ICreateX(BaseChain.CREATEX).computeCreate3Address(d.guardedSalt, BaseChain.CREATEX);
            if (onchain != d.addr) revert AddressMismatch(d.key, d.addr, onchain);
            if (d.addr.code.length != 0) revert AddressInUse(d.key, d.addr);
            if (d.initCode.length > 49_152) revert InitCodeTooLarge(d.key, d.initCode.length);
        }
        _checkSafeTxHash(p, p.batch1a);
        _checkSafeTxHash(p, p.batch1b);
        _checkSafeTxHash(p, p.batch2);
        if (p.hasProposal) {
            _checkPlainTxHash(
                p,
                "allowVault schedule",
                p.allowVault.schedule.data,
                p.allowVault.scheduleTx.nonce,
                p.allowVault.scheduleTx.safeTxHash
            );
            _checkPlainTxHash(
                p,
                "allowVault execute",
                p.allowVault.execute.data,
                p.allowVault.executeTx.nonce,
                p.allowVault.executeTx.safeTxHash
            );
        }
    }

    // ================================================================ Simulation (state reverted)

    /// @notice Executes the three batches through the real Gov Safe on the fork (pranked `approveHash` by `threshold`
    ///         owners, then `execTransaction` from a non-owner), checks the result, records runtime codehashes and
    ///         gas, simulates the allowVault proposal through the Timelock, then reverts all state.
    /// @param p The plan; `runtimeCodeHash`, `runtimeSize`, `gasUsed` and `txGas` are filled in.
    function simulate(Plan memory p) public {
        uint256 snap = vm.snapshotState();
        ISafe gov = ISafe(p.cfg.gov.safe);
        if (gov.nonce() != p.cfg.govNonce) {
            vm.store(address(gov), BaseChain.SAFE_NONCE_SLOT, bytes32(p.cfg.govNonce));
        }

        _exec(p, p.batch1a);
        _exec(p, p.batch1b);
        _exec(p, p.batch2);

        for (uint256 i; i < p.deployments.length; ++i) {
            Deployment memory d = p.deployments[i];
            if (d.addr.code.length == 0) revert AddressMismatch(d.key, d.addr, address(0));
            if (d.addr.code.length > 24_576) revert RuntimeTooLarge(d.key, d.addr.code.length);
            d.runtimeCodeHash = d.addr.codehash;
            d.runtimeSize = d.addr.code.length;
        }
        _checkSimulatedState(p);

        if (p.hasProposal) {
            TimelockController tl = TimelockController(payable(MHDeployPlan.at(p, MHDeployPlan.TIMELOCK)));
            vm.prank(address(gov));
            tl.schedule(
                p.allowVault.target,
                0,
                p.allowVault.data,
                p.allowVault.predecessor,
                p.allowVault.salt,
                p.allowVault.delay
            );
            if (
                tl.hashOperation(p.allowVault.target, 0, p.allowVault.data, bytes32(0), p.allowVault.salt)
                    != p.allowVault.operationId
            ) revert SimulationStateMismatch("allowVault operation id");
            vm.warp(block.timestamp + p.allowVault.delay);
            vm.prank(address(gov));
            tl.execute(p.allowVault.target, 0, p.allowVault.data, p.allowVault.predecessor, p.allowVault.salt);
            if (!IMHCircleRegistry(p.allowVault.target).isAllowedVault(p.cfg.circleVault)) {
                revert SimulationStateMismatch("allowVault");
            }
        }
        vm.revertToState(snap);
    }

    // ================================================================ Internal: config

    function _loadSafe(string memory prefix) private view returns (SafeSpec memory s) {
        s.safe = vm.envAddress(string.concat(prefix, "_SAFE"));
        s.owners = vm.envAddress(string.concat(prefix, "_SAFE_OWNERS"), ",");
        s.threshold = vm.envUint(string.concat(prefix, "_SAFE_THRESHOLD"));
    }

    function _neverBroadcast() private view {
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            revert NeverBroadcast();
        }
    }

    // ================================================================ Internal: checks

    function _codehash(string memory what, address at, bytes32 expected) private view {
        if (at.codehash != expected) revert CodehashMismatch(what, at, expected, at.codehash);
    }

    function _checkRoles(DeployConfig memory cfg) private view {
        address[6] memory a = [
            cfg.gov.safe, cfg.guardian.safe, cfg.treasury.safe, cfg.operator, cfg.circleVault, cfg.earnWrapper
        ];
        string[6] memory n =
            ["GOV_SAFE", "GUARDIAN_SAFE", "TREASURY_SAFE", "OPERATOR", "CIRCLE_VAULT", "EARN_WRAPPER"];
        for (uint256 i; i < 6; ++i) {
            // The vault and the wrapper may be explicitly "none"; every role must be set.
            if (a[i] == address(0)) {
                if (i < 4) revert ZeroRole(n[i]);
                continue;
            }
            if (a[i] == msg.sender) revert RoleIsSender(n[i], msg.sender);
            for (uint256 j = i + 1; j < 6; ++j) {
                if (a[i] == a[j]) revert DuplicateRole(n[i], n[j]);
            }
        }
        // Audit 2 R1-26: the operator is a key, never a contract (a public forwarder would let anyone create
        // circles that pass `isCircle`). An EIP-7702-delegated account counts as code too.
        if (cfg.operator.code.length != 0) revert OperatorNotEoa(cfg.operator);
    }

    function _checkSafe(string memory name, uint8 role, SafeSpec memory s) private view {
        address safe = s.safe;
        if (safe.code.length == 0) revert NotAContract(name, safe);
        _codehash(string.concat(name, " Safe proxy"), safe, BaseChain.SAFE_PROXY_CODEHASH);
        address singleton = address(uint160(uint256(vm.load(safe, BaseChain.SAFE_SINGLETON_SLOT))));
        if (singleton != BaseChain.SAFE_L2) revert SafeSingletonMismatch(name, singleton);

        uint256 threshold = ISafe(safe).getThreshold();
        if (threshold != s.threshold) revert SafeThresholdMismatch(name, s.threshold, threshold);
        address[] memory owners = ISafe(safe).getOwners();
        if (owners.length != s.owners.length) revert SafeOwnersMismatch(name);
        for (uint256 i; i < s.owners.length; ++i) {
            address o = s.owners[i];
            if (o == address(0) || o == BaseChain.SAFE_SENTINEL) revert SafeOwnerInvalid(name, o);
            for (uint256 j = i + 1; j < s.owners.length; ++j) {
                if (s.owners[j] == o) revert SafeOwnerInvalid(name, o);
            }
            if (!ISafe(safe).isOwner(o)) revert SafeOwnersMismatch(name);
        }
        // Audit R2-17: the spec §5 threshold per role (Gov 3-of-5, minimum 2-of-3; Guardian 2-of-4; Treasury 2-of-3).
        if (!BaseChain.safePolicyOk(role, threshold, owners.length)) {
            revert SafeThresholdPolicy(name, threshold, owners.length);
        }

        (address[] memory modules,) = ISafe(safe).getModulesPaginated(BaseChain.SAFE_SENTINEL, 1);
        if (modules.length != 0) revert SafeHasModules(name);
        address guard = address(uint160(uint256(vm.load(safe, BaseChain.SAFE_GUARD_SLOT))));
        if (guard != address(0)) revert SafeHasGuard(name, guard);
        address handler = address(uint160(uint256(vm.load(safe, BaseChain.SAFE_FALLBACK_HANDLER_SLOT))));
        if (handler != BaseChain.FALLBACK_HANDLER) revert SafeFallbackHandlerMismatch(name, handler);
    }

    function _checkKeySeparation(DeployConfig memory cfg) private pure {
        for (uint256 i; i < cfg.gov.owners.length; ++i) {
            for (uint256 j; j < cfg.guardian.owners.length; ++j) {
                if (cfg.gov.owners[i] == cfg.guardian.owners[j]) revert SafeKeysShared(cfg.gov.owners[i]);
            }
        }
        _notOwner(cfg.operator, cfg.gov.owners);
        _notOwner(cfg.operator, cfg.guardian.owners);
        _notOwner(cfg.operator, cfg.treasury.owners);
    }

    /// @dev Audit R1-17: every owner of the three Safes is an EOA and none is a role address. Comparing owner lists
    ///      alone let a nested Safe (the Gov Safe as a Guardian owner) or a contract controlled by the other side
    ///      defeat the Gov/Guardian separation. Audit R2-16: an EIP-7702-delegated account counts as code too (no
    ///      exception for the designator): its delegate can act for it under any authority it implements (another
    ///      key, a passkey, session keys) and Safe accepts EIP-1271 signatures from owners, so address disjointness
    ///      no longer proves the keys are separate. VerifyBase re-checks this on the live owners.
    function _checkOwnersAreKeys(DeployConfig memory cfg) private view {
        address[6] memory roles = [
            cfg.gov.safe, cfg.guardian.safe, cfg.treasury.safe, cfg.operator, cfg.circleVault, cfg.earnWrapper
        ];
        SafeSpec[3] memory safes = [cfg.gov, cfg.guardian, cfg.treasury];
        string[3] memory names = ["gov", "guardian", "treasury"];
        for (uint256 s; s < 3; ++s) {
            for (uint256 i; i < safes[s].owners.length; ++i) {
                address o = safes[s].owners[i];
                for (uint256 r; r < 6; ++r) {
                    if (roles[r] != address(0) && o == roles[r]) revert SafeOwnerIsRole(names[s], o);
                }
                if (o.code.length != 0) revert SafeOwnerNotEoa(names[s], o);
            }
        }
    }

    function _notOwner(address operator, address[] memory owners) private pure {
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] == operator) revert OperatorIsSafeOwner(operator);
        }
    }

    /// @dev The same checks `MHCircleRegistry.allowVault` runs (audit R1-04: every curator power that can expose or
    ///      write down depositor assets), in the same order, so the proposal cannot fail 48h later.
    ///      Plus, on Base mainnet, provenance from the pinned Vault V2 factory and the pinned Morpho adapter registry
    ///      (audit R2-01 (d)). What no view can show, pending submissions, is `MHVaultPending.scan` in `run`.
    function _checkVault(address vault, address usdc) private view {
        if (vault.code.length == 0) revert NotAContract("CIRCLE_VAULT", vault);
        IVaultV2 v = IVaultV2(vault);
        address asset = v.asset();
        if (asset != usdc) revert VaultNotUsdc(vault, asset);
        if (block.chainid == BaseChain.BASE) {
            if (!IVaultV2FactoryView(BaseChain.VAULT_V2_FACTORY_BASE).isVaultV2(vault)) {
                revert VaultNotFromFactory(vault, BaseChain.VAULT_V2_FACTORY_BASE);
            }
            address registry = v.adapterRegistry();
            if (registry != BaseChain.MORPHO_ADAPTER_REGISTRY_BASE) {
                revert AdapterRegistryNotPinned(BaseChain.MORPHO_ADAPTER_REGISTRY_BASE, registry);
            }
        }
        _gate(v, v.receiveAssetsGate(), IVaultV2.setReceiveAssetsGate.selector);
        _gate(v, v.receiveSharesGate(), IVaultV2.setReceiveSharesGate.selector);
        _gate(v, v.sendSharesGate(), IVaultV2.setSendSharesGate.selector);
        _vaultTimelock(v, IVaultV2.setIsAllocator.selector, MHCircleConstants.MIN_VAULT_TIMELOCK);
        _vaultTimelock(v, IVaultV2.addAdapter.selector, MHCircleConstants.MIN_VAULT_TIMELOCK);
        _vaultTimelock(v, IVaultV2.removeAdapter.selector, MHCircleConstants.MIN_VAULT_TIMELOCK);
        _vaultTimelock(v, IVaultV2.setAdapterRegistry.selector, MHCircleConstants.MIN_VAULT_TIMELOCK);
        if (v.adapterRegistry() == address(0)) {
            revert VaultCheckFailed(vault, IVaultV2.adapterRegistry.selector);
        }
        uint256 exposure = MHCircleConstants.MIN_VAULT_EXPOSURE_TIMELOCK;
        _vaultTimelock(v, IVaultV2.increaseAbsoluteCap.selector, exposure);
        _vaultTimelock(v, IVaultV2.increaseRelativeCap.selector, exposure);
        _vaultTimelock(v, IVaultV2.setPerformanceFee.selector, exposure);
        _vaultTimelock(v, IVaultV2.setManagementFee.selector, exposure);
        uint256 n = v.adaptersLength();
        if (n > MHCircleConstants.MAX_VAULT_ADAPTERS) {
            revert VaultCheckFailed(vault, IVaultV2.adaptersLength.selector);
        }
        bytes4 burn = IMorphoMarketV1AdapterV2.burnShares.selector;
        for (uint256 i; i < n; ++i) {
            IMorphoMarketV1AdapterV2 a = IMorphoMarketV1AdapterV2(v.adapters(i));
            if (!a.abdicated(burn) && a.timelock(burn) < exposure) revert VaultCheckFailed(vault, burn);
        }
    }

    function _gate(IVaultV2 v, address gate, bytes4 setter) private view {
        if (gate != address(0) || !v.abdicated(setter)) revert VaultCheckFailed(address(v), setter);
    }

    function _vaultTimelock(IVaultV2 v, bytes4 selector, uint256 minimum) private view {
        if (!v.abdicated(selector) && v.timelock(selector) < minimum) {
            revert VaultCheckFailed(address(v), selector);
        }
    }

    function _checkCommit(string memory commit) private pure {
        bytes memory b = bytes(commit);
        if (b.length != 40) revert BadCommit(commit);
        for (uint256 i; i < 40; ++i) {
            bytes1 c = b[i];
            if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "f"))) revert BadCommit(commit);
        }
    }

    /// @dev Audit R2-03: a plain proposal transaction (CALL to the Timelock), hashed by the Gov Safe itself.
    function _checkPlainTxHash(
        Plan memory p,
        string memory what,
        bytes memory data,
        uint256 nonce,
        bytes32 local
    ) private view {
        address tl = MHDeployPlan.at(p, MHDeployPlan.TIMELOCK);
        bytes32 onchain = ISafe(p.cfg.gov.safe)
            .getTransactionHash(tl, 0, data, BaseChain.OP_CALL, 0, 0, 0, address(0), address(0), nonce);
        if (onchain != local) revert SafeTxHashMismatch(what, local, onchain);
    }

    /// @dev Audit R2-04: the runtime code the CreateX simulation produced must equal the runtime derived offline by
    ///      `MHManifestCheck.runtimeOf` (what every signer's `CheckManifest` and `VerifyBase` rely on).
    function _checkRuntimeDerivation(Plan memory p) private {
        bytes32[7] memory simulated;
        for (uint256 i; i < 7; ++i) {
            simulated[i] = p.deployments[i].runtimeCodeHash;
        }
        MHManifestCheck.deriveRuntime(p);
        for (uint256 i; i < 7; ++i) {
            if (p.deployments[i].runtimeCodeHash != simulated[i]) {
                revert RuntimeDerivationMismatch(p.deployments[i].key);
            }
        }
    }

    function _checkSafeTxHash(Plan memory p, SafeBatch memory b) private view {
        bytes32 onchain = ISafe(p.cfg.gov.safe)
            .getTransactionHash(b.to, 0, b.txData, b.operation, 0, 0, 0, address(0), address(0), b.nonce);
        if (onchain != b.safeTxHash) revert SafeTxHashMismatch(b.key, b.safeTxHash, onchain);
        bytes32 domain = ISafe(p.cfg.gov.safe).domainSeparator();
        if (domain != b.domainSeparator) revert SafeTxHashMismatch(b.key, b.domainSeparator, domain);
    }

    function _checkSimulatedState(Plan memory p) private view {
        TimelockController tl = TimelockController(payable(MHDeployPlan.at(p, MHDeployPlan.TIMELOCK)));
        address gov = p.cfg.gov.safe;
        address canceller = MHDeployPlan.at(p, MHDeployPlan.CANCELLER);
        if (tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), gov)) {
            revert SimulationStateMismatch("Gov still Timelock admin");
        }
        if (!tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl))) {
            revert SimulationStateMismatch("Timelock self-admin");
        }
        if (!tl.hasRole(tl.CANCELLER_ROLE(), canceller)) revert SimulationStateMismatch("canceller role");
        if (tl.getMinDelay() != p.cfg.timelockDelay) revert SimulationStateMismatch("Timelock delay");
        IMHCircleRegistry registry = IMHCircleRegistry(MHDeployPlan.at(p, MHDeployPlan.REGISTRY));
        if (registry.operator() != p.cfg.operator) revert SimulationStateMismatch("registry operator");
        address factory = MHDeployPlan.at(p, MHDeployPlan.FACTORY);
        if (IMHReputation(MHDeployPlan.at(p, MHDeployPlan.REPUTATION)).FACTORY() != factory) {
            revert SimulationStateMismatch("reputation factory");
        }
    }

    // ================================================================ Internal: Safe execution

    /// @dev `threshold` owners in ascending order approve the hash on chain (Safe signature type 1: r = owner,
    ///      s = 0, v = 1), then a non-owner executes. Measures execution gas and adds the intrinsic cost.
    function _exec(Plan memory p, SafeBatch memory b) private {
        ISafe safe = ISafe(p.cfg.gov.safe);
        bytes32 h = safe.getTransactionHash(
            b.to, 0, b.txData, b.operation, 0, 0, 0, address(0), address(0), b.nonce
        );
        if (h != b.safeTxHash) revert SafeTxHashMismatch(b.key, b.safeTxHash, h);
        bytes memory signatures = approveAndSign(safe, h);
        bytes memory callData = abi.encodeCall(
            ISafe.execTransaction,
            (b.to, 0, b.txData, b.operation, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
        _coolAll(p);
        vm.prank(SIM_EXECUTOR, SIM_EXECUTOR);
        safe.execTransaction(
            b.to, 0, b.txData, b.operation, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        // Gas spent inside the Safe's frame only (before refunds): the caller's ABI encoding is not counted.
        b.gasUsed = vm.lastCallGas().gasTotalUsed;
        b.txGas = txGas(b.gasUsed, callData);
        // 1% margin: on an anvil fork the executed receipts were within ±0.15% of this simulation.
        if (b.txGas * 101 / 100 > BaseChain.MAX_BATCH_GAS) revert BatchGasTooHigh(b.key, b.txGas);
    }

    /// @dev Marks every account the batch touches (and its storage) cold, as at the start of a real transaction,
    ///      so the measured gas is not flattered by the validation reads made earlier in this script run.
    function _coolAll(Plan memory p) private {
        IVmCool c = IVmCool(address(vm));
        c.cool(p.cfg.gov.safe);
        c.cool(BaseChain.SAFE_L2);
        c.cool(BaseChain.MULTISEND_CALL_ONLY);
        c.cool(BaseChain.CREATEX);
        c.cool(p.cfg.usdc);
        for (uint256 i; i < p.deployments.length; ++i) {
            c.cool(p.deployments[i].addr);
            c.cool(_create3Proxy(p.deployments[i].guardedSalt));
        }
    }

    function _create3Proxy(bytes32 guarded) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), BaseChain.CREATEX, guarded, MHDeployPlan.CREATE3_PROXY_INITCODE_HASH
                        )
                    )
                )
            )
        );
    }

    /// @notice Pranks `threshold` owners (ascending) into `approveHash(h)` and returns the packed type-1 signatures.
    /// @param safe The Safe.
    /// @param h The safeTxHash.
    /// @return signatures Sorted `{bytes32 r = owner}{bytes32 s = 0}{uint8 v = 1}` entries.
    function approveAndSign(ISafe safe, bytes32 h) public returns (bytes memory signatures) {
        address[] memory owners = safe.getOwners();
        MHDeployPlan.sortAddresses(owners);
        uint256 threshold = safe.getThreshold();
        for (uint256 i; i < threshold; ++i) {
            vm.prank(owners[i]);
            safe.approveHash(h);
            signatures =
                abi.encodePacked(signatures, bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1));
        }
    }

    /// @notice Transaction gas: max(21,000 + calldata + execution, EIP-7623 floor 21,000 + 10 * tokens), where a
    ///         token is a zero byte or a quarter of a non-zero byte.
    /// @param execution Measured execution gas.
    /// @param callData The transaction calldata.
    /// @return The gas the transaction needs.
    function txGas(uint256 execution, bytes memory callData) public pure returns (uint256) {
        uint256 zeros;
        for (uint256 i; i < callData.length; ++i) {
            if (callData[i] == 0) ++zeros;
        }
        uint256 nonZeros = callData.length - zeros;
        uint256 standard = 21_000 + 4 * zeros + 16 * nonZeros + execution;
        uint256 floor = 21_000 + 10 * (zeros + 4 * nonZeros);
        return standard > floor ? standard : floor;
    }

    // ================================================================ Internal: output

    function _write(Plan memory p, string memory outDir) private {
        vm.createDir(outDir, true);
        vm.writeFile(string.concat(outDir, "/manifest.json"), MHDeployJson.manifest(p));
        vm.writeFile(string.concat(outDir, "/", p.batch1a.fileName), MHDeployJson.batchFile(p, p.batch1a));
        vm.writeFile(string.concat(outDir, "/", p.batch1b.fileName), MHDeployJson.batchFile(p, p.batch1b));
        vm.writeFile(string.concat(outDir, "/", p.batch2.fileName), MHDeployJson.batchFile(p, p.batch2));
        if (p.hasProposal) {
            vm.writeFile(
                string.concat(outDir, "/proposal-allow-vault.schedule.safe.json"),
                MHDeployJson.proposalFile(p, p.allowVault.schedule, "schedule")
            );
            vm.writeFile(
                string.concat(outDir, "/proposal-allow-vault.execute.safe.json"),
                MHDeployJson.proposalFile(p, p.allowVault.execute, "execute")
            );
        }
    }

    function _log(Plan memory p, string memory outDir) private pure {
        console2.log("Moolahub circles deployment plan (never broadcast)");
        console2.log("  network      ", p.network);
        console2.log("  Gov Safe     ", p.cfg.gov.safe);
        for (uint256 i; i < p.deployments.length; ++i) {
            console2.log(
                string.concat("  ", p.deployments[i].key, " -> ", vm.toString(p.deployments[i].addr))
            );
        }
        console2.log("  batch 1a nonce / safeTxHash", p.batch1a.nonce, vm.toString(p.batch1a.safeTxHash));
        console2.log("  batch 1a simulated tx gas  ", p.batch1a.txGas);
        console2.log("  batch 1b nonce / safeTxHash", p.batch1b.nonce, vm.toString(p.batch1b.safeTxHash));
        console2.log("  batch 1b simulated tx gas  ", p.batch1b.txGas);
        console2.log("  batch 2 nonce / safeTxHash", p.batch2.nonce, vm.toString(p.batch2.safeTxHash));
        console2.log("  batch 2 simulated tx gas  ", p.batch2.txGas);
        console2.log("  inputsHash                ", vm.toString(MHDeployPlan.inputsHash(p)));
        if (p.hasProposal) {
            console2.log(
                "  allowVault schedule nonce / safeTxHash",
                p.allowVault.scheduleTx.nonce,
                vm.toString(p.allowVault.scheduleTx.safeTxHash)
            );
            console2.log(
                "  allowVault execute nonce / safeTxHash ",
                p.allowVault.executeTx.nonce,
                vm.toString(p.allowVault.executeTx.safeTxHash)
            );
        }
        if (p.cfg.rotatingFeeBps != 0 || p.cfg.accumulationFeeBps != 0) {
            console2.log(
                "  WARNING: non-zero launch fee policy (spec decision 13: 0 until counsel clears it)"
            );
        }
        console2.log("  written to   ", outDir);
    }
}
