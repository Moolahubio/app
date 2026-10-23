// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IMHCircle } from "../src/circles/interfaces/IMHCircle.sol";
import { IMHCircleRegistry } from "../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../src/circles/interfaces/IMHReputation.sol";
import { IMHCircleFactory } from "../src/circles/interfaces/IMHCircleFactory.sol";
import { IMHRotatingCircle } from "../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHAccumulationCircle } from "../src/circles/interfaces/IMHAccumulationCircle.sol";
import { MHGuardianCanceller } from "../src/circles/MHGuardianCanceller.sol";
import { CircleMode, RotatingParams, AccumulationParams } from "../src/circles/MHCircleTypes.sol";

import { BaseChain } from "./ceremony/BaseChain.sol";
import { ISafe } from "./ceremony/DeployInterfaces.sol";
import { MHManifestCheck } from "./ceremony/MHManifestCheck.sol";
import { MHVaultPending } from "./ceremony/MHVaultPending.sol";

import { MHRotatingCircle } from "../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../src/circles/MHAccumulationCircle.sol";
import { MHCircleRegistry } from "../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../src/circles/MHReputation.sol";
import { MHCircleFactory } from "../src/circles/MHCircleFactory.sol";

/// @notice Ownable2Step surface read by the verifier.
interface IOwnable2Step {
    /// @notice Current owner.
    function owner() external view returns (address);
    /// @notice Pending owner of a two-step transfer (0 if none).
    function pendingOwner() external view returns (address);
}

/// @title VerifyBase
/// @notice Read-only post-deployment verification (spec §5 "VerifyBase"). Never writes chain state and never
///         broadcasts. Asserts, against the manifest written by `BuildBaseBatch`:
///         - pinned codehashes of every external contract (USDC proxy, CreateX, Safe v1.4.1 singleton, factory,
///           MultiSendCallOnly, fallback handler), and the runtime code of all seven deployments against the runtime
///           derived from the local build (audit R2-04: each initcode, rebuilt from the manifest's roles and
///           addresses, is run in the local EVM; the manifest's runtime codehash is never trusted on its own, so a
///           substituted contract at a CREATE3 address fails);
///         - `owner() == Timelock` and `pendingOwner() == 0` on Registry and Reputation;
///         - the exact Timelock roles: from every `RoleGranted`/`RoleRevoked` since batch 2 the final holders are
///           exactly {admin: Timelock; proposer: Gov; executor: Gov; canceller: Gov, canceller}, confirmed by
///           `hasRole` for every known address, plus the delay;
///         - registry roles, reputation authorizer, factory and canceller links, implementation immutables;
///         - `initialize` reverts (`InvalidInitialization`) on both implementations;
///         - no role belongs to an EOA used during deployment (`DEPLOY_EOAS`);
///         - canonical Safes (proxy codehash, SafeL2 v1.4.1, fallback handler) with the manifest's owners and
///           threshold, no modules and no guard;
///         - audit round 1: the ceremony policy re-applied to the live state, not just equality with the manifest
///           (R1-05: Timelock delay in [48h, 7 days], Gov and Guardian keys disjoint, the operator owning no Safe;
///           R2-17: the per-role Safe threshold policy; R1-17 and R2-16: every Safe owner an account without code,
///           an EIP-7702 delegation included, and never a role address);
///         - `run()` also re-derives the whole manifest from its inputs with `MHManifestCheck` (R1-05: a manifest
///           that wires other addresses or roles fails), and requires that no Timelock operation scheduled since
///           batch 2 is still pending except the manifest's allowVault proposal, and that no vault other than the
///           manifest's is allowlisted (R1-23); and, with a vault, that no submission is pending on the vault or
///           its adapters (R2-01, `MHVaultPending.scan`; needs CIRCLE_VAULT_FROM_BLOCK and an archive `eth_getLogs`
///           RPC).
///         The exact Sourcify match is checked by `script/check-sourcify.sh` (HTTP, outside the EVM).
///
///         Environment: MANIFEST_PATH (`<dir>/manifest.json`), DEPLOY_EOAS (comma-separated: script sender, every
///         Safe-tx executor), BATCH2_BLOCK (block of the batch-2 transaction; logs are read from there to the head).
///         Run: `forge script script/VerifyBase.s.sol --rpc-url base`.
contract VerifyBase is Script {
    /// @notice A check failed; `check` names it.
    error VerifyFailed(string check);
    /// @notice Run under `--broadcast`/`--resume`.
    error NeverBroadcast();

    /// @notice A Timelock role change, in log order.
    struct RoleEvent {
        bytes32 role;
        address account;
        bool granted;
    }

    /// @notice The manifest fields the verifier needs.
    struct Manifest {
        uint256 chainId;
        address usdc;
        address govSafe;
        address guardianSafe;
        address treasurySafe;
        address operator;
        address circleVault;
        address earnWrapper;
        uint256 timelockDelay;
        address[] govOwners;
        uint256 govThreshold;
        address[] guardianOwners;
        uint256 guardianThreshold;
        address[] treasuryOwners;
        uint256 treasuryThreshold;
        address rotatingImpl;
        address accumulationImpl;
        address timelock;
        address canceller;
        address registry;
        address reputation;
        address factory;
        bytes32[7] runtimeCodeHash;
        bytes32 allowVaultOperationId;
    }

    /// @notice Default block range per `eth_getLogs` request (override with `LOG_CHUNK`).
    uint256 internal constant LOG_CHUNK = 5_000;
    /// @notice OZ v5 `Initializable` ERC-7201 storage slot.
    bytes32 internal constant INITIALIZABLE_SLOT =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    bytes32 internal constant ADMIN = 0x00;
    bytes32 internal constant PROPOSER = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER = keccak256("CANCELLER_ROLE");

    string[7] internal KEYS =
        ["rotatingImpl", "accumulationImpl", "timelock", "canceller", "registry", "reputation", "factory"];

    // ================================================================ Entry points

    /// @notice Loads the manifest, reads the Timelock's role logs from BATCH2_BLOCK to the head, and verifies.
    function run() external {
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            revert NeverBroadcast();
        }
        string memory path = vm.envString("MANIFEST_PATH");
        Manifest memory m = load(path);
        uint256 from = vm.envUint("BATCH2_BLOCK");
        verifyAll(
            path,
            vm.envAddress("DEPLOY_EOAS", ","),
            fetchRoleEvents(m.timelock, from, block.number),
            fetchScheduledIds(m.timelock, from, block.number),
            fetchAllowedVaults(m.registry, from, block.number)
        );
        if (m.circleVault != address(0)) {
            MHVaultPending.scan(
                m.circleVault,
                BaseChain.VAULT_V2_FACTORY_BASE,
                vm.envUint("CIRCLE_VAULT_FROM_BLOCK"),
                block.number,
                _logChunk()
            );
        }
        console2.log("VerifyBase: all on-chain checks passed. Now run script/check-sourcify.sh for Sourcify.");
    }

    /// @notice Everything `run` checks except reading the logs and the vault scan (which need an RPC): the offline
    ///         manifest re-derivation, every on-chain assertion and the governance queue. Audit 2 R1-14: the fork
    ///         rehearsal drives it end to end with logs recorded in the test.
    /// @param path The manifest path.
    /// @param eoas Every deployment EOA.
    /// @param events The Timelock's role changes since batch 2.
    /// @param scheduled Every operation id scheduled since batch 2.
    /// @param allowed Every vault allowlisted since batch 2.
    function verifyAll(
        string memory path,
        address[] memory eoas,
        RoleEvent[] memory events,
        bytes32[] memory scheduled,
        address[] memory allowed
    ) public {
        MHManifestCheck.check(_dirOf(path));
        Manifest memory m = load(path);
        verify(m, eoas, events);
        verifyGovernanceQueue(m, scheduled, allowed);
    }

    /// @dev The `eth_getLogs` block range for every log read here: `LOG_CHUNK` from the environment (default 5,000),
    ///      as the README says (audit 2 R2-15: the role, `CallScheduled` and `VaultAllowed` reads used the constant).
    function _logChunk() internal view returns (uint256 chunk) {
        chunk = vm.envOr("LOG_CHUNK", LOG_CHUNK);
        if (chunk == 0) revert VerifyFailed("LOG_CHUNK must be non-zero");
    }

    /// @notice Every operation id the Timelock scheduled in [fromBlock, toBlock] (`CallScheduled` topic 1).
    /// @param timelock The Timelock.
    /// @param fromBlock First block.
    /// @param toBlock Last block.
    /// @return ids The ids, possibly repeated (one log per call of a batch).
    function fetchScheduledIds(address timelock, uint256 fromBlock, uint256 toBlock)
        public
        returns (bytes32[] memory ids)
    {
        bytes32[] memory topic = new bytes32[](1);
        topic[0] = TimelockController.CallScheduled.selector;
        uint256 chunk = _logChunk();
        for (uint256 from = fromBlock; from <= toBlock; from += chunk) {
            uint256 to = from + chunk - 1 > toBlock ? toBlock : from + chunk - 1;
            Vm.EthGetLogs[] memory l = vm.eth_getLogs(from, to, timelock, topic);
            bytes32[] memory next = new bytes32[](ids.length + l.length);
            for (uint256 i; i < ids.length; ++i) {
                next[i] = ids[i];
            }
            for (uint256 i; i < l.length; ++i) {
                next[ids.length + i] = l[i].topics[1];
            }
            ids = next;
        }
    }

    /// @notice Every vault the registry allowlisted in [fromBlock, toBlock] (`VaultAllowed` topic 1).
    /// @param registry The registry.
    /// @param fromBlock First block.
    /// @param toBlock Last block.
    /// @return vaults The vaults.
    function fetchAllowedVaults(address registry, uint256 fromBlock, uint256 toBlock)
        public
        returns (address[] memory vaults)
    {
        bytes32[] memory topic = new bytes32[](1);
        topic[0] = IMHCircleRegistry.VaultAllowed.selector;
        uint256 chunk = _logChunk();
        for (uint256 from = fromBlock; from <= toBlock; from += chunk) {
            uint256 to = from + chunk - 1 > toBlock ? toBlock : from + chunk - 1;
            Vm.EthGetLogs[] memory l = vm.eth_getLogs(from, to, registry, topic);
            address[] memory next = new address[](vaults.length + l.length);
            for (uint256 i; i < vaults.length; ++i) {
                next[i] = vaults[i];
            }
            for (uint256 i; i < l.length; ++i) {
                next[vaults.length + i] = address(uint160(uint256(l[i].topics[1])));
            }
            vaults = next;
        }
    }

    /// @notice Audit R1-23: nothing is waiting in the Timelock except the manifest's allowVault proposal, and no
    ///         vault other than the manifest's is allowlisted. A queued `grantRole`, `updateDelay`,
    ///         `transferOwnership`, `setOperator`, `setGuardian` or `setTreasury` used to pass until it executed.
    /// @param m The manifest.
    /// @param scheduled Every operation id scheduled since batch 2.
    /// @param allowed Every vault allowlisted since batch 2.
    function verifyGovernanceQueue(Manifest memory m, bytes32[] memory scheduled, address[] memory allowed)
        public
        view
    {
        TimelockController tl = TimelockController(payable(m.timelock));
        for (uint256 i; i < scheduled.length; ++i) {
            bytes32 id = scheduled[i];
            _require(
                !tl.isOperationPending(id) || (id == m.allowVaultOperationId && id != bytes32(0)),
                "Timelock: an unexpected operation is pending"
            );
        }
        IMHCircleRegistry registry = IMHCircleRegistry(m.registry);
        for (uint256 i; i < allowed.length; ++i) {
            _require(
                allowed[i] == m.circleVault || !registry.isAllowedVault(allowed[i]),
                "registry: a vault other than the manifest's is allowlisted"
            );
        }
    }

    function _dirOf(string memory path) private pure returns (string memory dir) {
        bytes memory b = bytes(path);
        bytes memory tail = bytes("manifest.json");
        _require(b.length >= tail.length, "MANIFEST_PATH must end in manifest.json");
        for (uint256 i; i < tail.length; ++i) {
            _require(b[b.length - tail.length + i] == tail[i], "MANIFEST_PATH must end in manifest.json");
        }
        bytes memory d = new bytes(b.length - tail.length);
        for (uint256 i; i < d.length; ++i) {
            d[i] = b[i];
        }
        dir = string(d);
    }

    /// @notice Parses a manifest written by `BuildBaseBatch`.
    /// @param path Path to `manifest.json`.
    /// @return m The parsed fields.
    function load(string memory path) public view returns (Manifest memory m) {
        string memory j = vm.readFile(path);
        m.chainId = vm.parseJsonUint(j, ".chainId");
        m.usdc = vm.parseJsonAddress(j, ".external.usdc");
        m.govSafe = vm.parseJsonAddress(j, ".roles.govSafe");
        m.guardianSafe = vm.parseJsonAddress(j, ".roles.guardianSafe");
        m.treasurySafe = vm.parseJsonAddress(j, ".roles.treasurySafe");
        m.operator = vm.parseJsonAddress(j, ".roles.operator");
        m.circleVault = vm.parseJsonAddress(j, ".roles.circleVault");
        m.earnWrapper = vm.parseJsonAddress(j, ".roles.earnWrapper");
        m.timelockDelay = vm.parseJsonUint(j, ".params.timelockDelay");
        m.govOwners = vm.parseJsonAddressArray(j, ".safes.gov.owners");
        m.govThreshold = vm.parseJsonUint(j, ".safes.gov.threshold");
        m.guardianOwners = vm.parseJsonAddressArray(j, ".safes.guardian.owners");
        m.guardianThreshold = vm.parseJsonUint(j, ".safes.guardian.threshold");
        m.treasuryOwners = vm.parseJsonAddressArray(j, ".safes.treasury.owners");
        m.treasuryThreshold = vm.parseJsonUint(j, ".safes.treasury.threshold");
        address[7] memory a;
        for (uint256 i; i < 7; ++i) {
            a[i] = vm.parseJsonAddress(j, string.concat(".contracts.", KEYS[i], ".address"));
            m.runtimeCodeHash[i] =
                vm.parseJsonBytes32(j, string.concat(".contracts.", KEYS[i], ".runtimeCodeHash"));
        }
        (m.rotatingImpl, m.accumulationImpl, m.timelock, m.canceller, m.registry, m.reputation, m.factory) =
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
        if (m.circleVault != address(0)) {
            m.allowVaultOperationId = vm.parseJsonBytes32(j, ".allowVaultProposal.operationId");
        }
    }

    /// @notice Every `RoleGranted`/`RoleRevoked` emitted by `timelock` in [fromBlock, toBlock], in log order.
    /// @param timelock The Timelock.
    /// @param fromBlock First block (the batch-2 block).
    /// @param toBlock Last block.
    /// @return events The role changes.
    function fetchRoleEvents(address timelock, uint256 fromBlock, uint256 toBlock)
        public
        returns (RoleEvent[] memory events)
    {
        bytes32[] memory granted = new bytes32[](1);
        granted[0] = IAccessControl.RoleGranted.selector;
        bytes32[] memory revoked = new bytes32[](1);
        revoked[0] = IAccessControl.RoleRevoked.selector;
        uint256 chunk = _logChunk();
        for (uint256 from = fromBlock; from <= toBlock; from += chunk) {
            uint256 to = from + chunk - 1 > toBlock ? toBlock : from + chunk - 1;
            Vm.EthGetLogs[] memory g = vm.eth_getLogs(from, to, timelock, granted);
            Vm.EthGetLogs[] memory r = vm.eth_getLogs(from, to, timelock, revoked);
            events = _append(events, _merge(g, r));
        }
    }

    // ================================================================ Verification

    /// @notice Runs every check; reverts `VerifyFailed(check)` on the first failure.
    /// @param m The manifest.
    /// @param deployEoas EOAs used during deployment (none may hold any role).
    /// @param events The Timelock's role changes since batch 2 (must include the constructor grants).
    function verify(Manifest memory m, address[] memory deployEoas, RoleEvent[] memory events) public {
        _verifyExternal(m);
        _verifyCode(m);
        _verifyTimelock(m, events);
        _verifyLinks(m);
        _verifyImplementations(m);
        _verifyDeployEoas(m, deployEoas);
        _verifySafe("gov", m.govSafe, m.govOwners, m.govThreshold);
        _verifySafe("guardian", m.guardianSafe, m.guardianOwners, m.guardianThreshold);
        _verifySafe("treasury", m.treasurySafe, m.treasuryOwners, m.treasuryThreshold);
        _verifyPolicy(m);
    }

    /// @dev Audit R1-05 / R1-17: the ceremony policy on the live state, independent of the manifest's values.
    function _verifyPolicy(Manifest memory m) private view {
        uint256 delay = TimelockController(payable(m.timelock)).getMinDelay();
        _require(
            delay >= BaseChain.MIN_TIMELOCK_DELAY && delay <= BaseChain.MAX_TIMELOCK_DELAY,
            "policy: Timelock delay in [48h, 7 days]"
        );
        address[6] memory roles =
            [m.govSafe, m.guardianSafe, m.treasurySafe, m.operator, m.circleVault, m.earnWrapper];
        _verifySafePolicy("gov", BaseChain.ROLE_GOV, m.govSafe, roles);
        _verifySafePolicy("guardian", BaseChain.ROLE_GUARDIAN, m.guardianSafe, roles);
        _verifySafePolicy("treasury", BaseChain.ROLE_TREASURY, m.treasurySafe, roles);
        address[] memory gov = ISafe(m.govSafe).getOwners();
        address[] memory guardian = ISafe(m.guardianSafe).getOwners();
        for (uint256 i; i < gov.length; ++i) {
            for (uint256 j; j < guardian.length; ++j) {
                _require(gov[i] != guardian[j], "policy: Gov and Guardian keys disjoint");
            }
        }
    }

    function _verifySafePolicy(string memory name, uint8 role, address safe, address[6] memory roles)
        private
        view
    {
        address[] memory owners = ISafe(safe).getOwners();
        uint256 threshold = ISafe(safe).getThreshold();
        _require(
            BaseChain.safePolicyOk(role, threshold, owners.length),
            string.concat(name, " Safe: threshold policy")
        );
        for (uint256 i; i < owners.length; ++i) {
            address o = owners[i];
            _require(_isEoa(o), string.concat(name, " Safe: every owner is an EOA"));
            for (uint256 r; r < 6; ++r) {
                _require(
                    roles[r] == address(0) || o != roles[r], string.concat(name, " Safe: an owner is a role")
                );
            }
        }
    }

    /// @dev No code at all. Audit R2-16: an EIP-7702 delegation designator (0xef0100 ‖ address) is code too: the
    ///      delegate can act for the account under any authority it implements, and the delegation can change at any
    ///      time, so a delegated owner no longer proves a separate hardware key.
    function _isEoa(address a) private view returns (bool) {
        return a.code.length == 0;
    }

    function _verifyExternal(Manifest memory m) private view {
        _require(block.chainid == m.chainId, "chain id");
        (address usdc, bytes32 usdcHash) = BaseChain.usdcOf(block.chainid);
        _require(usdc != address(0) && m.usdc == usdc, "USDC address");
        _require(usdc.codehash == usdcHash, "USDC proxy codehash");
        _require(BaseChain.CREATEX.codehash == BaseChain.CREATEX_CODEHASH, "CreateX codehash");
        _require(
            BaseChain.MULTISEND_CALL_ONLY.codehash == BaseChain.MULTISEND_CALL_ONLY_CODEHASH,
            "MultiSendCallOnly codehash"
        );
        _require(BaseChain.SAFE_L2.codehash == BaseChain.SAFE_L2_CODEHASH, "SafeL2 codehash");
        _require(
            BaseChain.SAFE_PROXY_FACTORY.codehash == BaseChain.SAFE_PROXY_FACTORY_CODEHASH,
            "SafeProxyFactory codehash"
        );
        _require(
            BaseChain.FALLBACK_HANDLER.codehash == BaseChain.FALLBACK_HANDLER_CODEHASH,
            "fallback handler codehash"
        );
    }

    /// @dev Audit R2-04: the expected runtime is derived here from the local build, never read from the manifest.
    ///      Each initcode is rebuilt from the local creation code and the constructor arguments the manifest's roles
    ///      and addresses imply (as `MHManifestCheck` does), run in the local EVM at its address (state reverted),
    ///      and the chain's code must equal the result; the manifest must record the same value.
    function _verifyCode(Manifest memory m) private {
        address[7] memory a = [
            m.rotatingImpl, m.accumulationImpl, m.timelock, m.canceller, m.registry, m.reputation, m.factory
        ];
        bytes32[7] memory onchain;
        for (uint256 i; i < 7; ++i) {
            _require(a[i].code.length != 0, string.concat(KEYS[i], " has code"));
            onchain[i] = a[i].codehash;
        }
        (bytes32[7] memory expected,) = MHManifestCheck.runtimeOf(_initCodes(m), a);
        for (uint256 i; i < 7; ++i) {
            _require(onchain[i] == expected[i], string.concat(KEYS[i], " runtime codehash"));
            _require(
                m.runtimeCodeHash[i] == expected[i], string.concat(KEYS[i], " manifest runtime codehash")
            );
        }
    }

    /// @dev The seven initcodes the manifest's roles and addresses imply, in `MHDeployPlan` order.
    function _initCodes(Manifest memory m) private pure returns (bytes[7] memory init) {
        address[] memory govOnly = new address[](1);
        govOnly[0] = m.govSafe;
        init[0] = abi.encodePacked(
            type(MHRotatingCircle).creationCode, abi.encode(m.usdc, m.registry, m.reputation)
        );
        init[1] = abi.encodePacked(
            type(MHAccumulationCircle).creationCode, abi.encode(m.usdc, m.registry, m.reputation)
        );
        init[2] = abi.encodePacked(
            type(TimelockController).creationCode, abi.encode(m.timelockDelay, govOnly, govOnly, m.govSafe)
        );
        init[3] = abi.encodePacked(
            type(MHGuardianCanceller).creationCode,
            abi.encode(m.timelock, m.registry, m.earnWrapper, m.guardianSafe)
        );
        init[4] = abi.encodePacked(
            type(MHCircleRegistry).creationCode,
            abi.encode(m.timelock, m.usdc, m.operator, m.guardianSafe, m.treasurySafe)
        );
        init[5] = abi.encodePacked(type(MHReputation).creationCode, abi.encode(m.timelock, m.factory));
        init[6] = abi.encodePacked(
            type(MHCircleFactory).creationCode,
            abi.encode(m.registry, m.reputation, m.rotatingImpl, m.accumulationImpl)
        );
    }

    function _verifyTimelock(Manifest memory m, RoleEvent[] memory events) private view {
        TimelockController tl = TimelockController(payable(m.timelock));
        _require(tl.getMinDelay() == m.timelockDelay, "Timelock delay");

        // Replay every role change; the surviving set must be exactly the expected five grants.
        _require(events.length != 0, "Timelock role logs found (check BATCH2_BLOCK)");
        bytes32[] memory roles = new bytes32[](events.length);
        address[] memory accounts = new address[](events.length);
        bool[] memory held = new bool[](events.length);
        uint256 n;
        for (uint256 i; i < events.length; ++i) {
            uint256 k = n;
            for (uint256 j; j < n; ++j) {
                if (roles[j] == events[i].role && accounts[j] == events[i].account) k = j;
            }
            if (k == n) {
                roles[n] = events[i].role;
                accounts[n] = events[i].account;
                ++n;
            }
            held[k] = events[i].granted;
        }
        uint256 live;
        for (uint256 j; j < n; ++j) {
            if (!held[j]) continue;
            ++live;
            _require(_expectedRole(m, roles[j], accounts[j]), "Timelock: unexpected role holder in logs");
            _require(tl.hasRole(roles[j], accounts[j]), "Timelock: logged grant not live");
        }
        _require(live == 5, "Timelock: exactly five role grants");

        // Cross-check with hasRole over every address the ceremony knows about, address(0) (an open role) included.
        address[] memory known = _knownAddresses(m);
        bytes32[4] memory all = [ADMIN, PROPOSER, EXECUTOR, CANCELLER];
        for (uint256 i; i < known.length; ++i) {
            for (uint256 r; r < 4; ++r) {
                _require(
                    tl.hasRole(all[r], known[i]) == _expectedRole(m, all[r], known[i]), "Timelock role matrix"
                );
            }
        }
    }

    function _expectedRole(Manifest memory m, bytes32 role, address account) private pure returns (bool) {
        if (role == ADMIN) return account == m.timelock;
        if (role == PROPOSER || role == EXECUTOR) return account == m.govSafe;
        if (role == CANCELLER) return account == m.govSafe || account == m.canceller;
        return false;
    }

    function _verifyLinks(Manifest memory m) private view {
        IMHCircleRegistry registry = IMHCircleRegistry(m.registry);
        _require(IOwnable2Step(m.registry).owner() == m.timelock, "registry owner == Timelock");
        _require(IOwnable2Step(m.registry).pendingOwner() == address(0), "registry pendingOwner == 0");
        _require(address(registry.USDC()) == m.usdc, "registry USDC");
        _require(registry.operator() == m.operator, "registry operator");
        // Audit 2 R1-26: the operator is a key (no code, no EIP-7702 delegation), never a call forwarder.
        _require(m.operator.code.length == 0, "operator is an EOA");
        _require(registry.guardian() == m.guardianSafe, "registry guardian");
        _require(registry.treasury() == m.treasurySafe, "registry treasury");
        console2.log("  registry.creationPaused:", registry.creationPaused());
        if (m.circleVault != address(0)) {
            console2.log("  registry.isAllowedVault(circleVault):", registry.isAllowedVault(m.circleVault));
        }

        _require(IOwnable2Step(m.reputation).owner() == m.timelock, "reputation owner == Timelock");
        _require(IOwnable2Step(m.reputation).pendingOwner() == address(0), "reputation pendingOwner == 0");
        _require(IMHReputation(m.reputation).FACTORY() == m.factory, "reputation authorizer == factory");

        IMHCircleFactory factory = IMHCircleFactory(m.factory);
        _require(address(factory.REGISTRY()) == m.registry, "factory registry");
        _require(address(factory.REPUTATION()) == m.reputation, "factory reputation");
        _require(factory.ROTATING_IMPL() == m.rotatingImpl, "factory rotating implementation");
        _require(factory.ACCUMULATION_IMPL() == m.accumulationImpl, "factory accumulation implementation");

        MHGuardianCanceller canceller = MHGuardianCanceller(m.canceller);
        _require(canceller.TIMELOCK() == m.timelock, "canceller Timelock");
        _require(canceller.REGISTRY() == m.registry, "canceller registry");
        _require(canceller.WRAPPER() == m.earnWrapper, "canceller wrapper");
        _require(canceller.guardian() == m.guardianSafe, "canceller guardian");
    }

    function _verifyImplementations(Manifest memory m) private view {
        _verifyImpl(m, m.rotatingImpl, CircleMode.Rotating, "rotating");
        _verifyImpl(m, m.accumulationImpl, CircleMode.Accumulation, "accumulation");
        RotatingParams memory rp;
        AccumulationParams memory ap;
        _initializeReverts(m.rotatingImpl, abi.encodeCall(IMHRotatingCircle.initialize, (rp)), "rotating");
        _initializeReverts(
            m.accumulationImpl, abi.encodeCall(IMHAccumulationCircle.initialize, (ap)), "accumulation"
        );
    }

    function _verifyImpl(Manifest memory m, address impl, CircleMode mode, string memory name) private view {
        IMHCircle c = IMHCircle(impl);
        _require(c.circleMode() == mode, string.concat(name, " implementation mode"));
        _require(address(c.USDC()) == m.usdc, string.concat(name, " implementation USDC"));
        _require(address(c.REGISTRY()) == m.registry, string.concat(name, " implementation registry"));
        _require(address(c.REPUTATION()) == m.reputation, string.concat(name, " implementation reputation"));
        uint64 initialized = uint64(uint256(vm.load(impl, INITIALIZABLE_SLOT)));
        _require(
            initialized == type(uint64).max, string.concat(name, " implementation initializers disabled")
        );
    }

    /// @dev A staticcall is enough: a disabled implementation reverts `InvalidInitialization` before any write, while
    ///      an initializable one would hit a static-context violation (empty revert data) and fail the check.
    function _initializeReverts(address impl, bytes memory data, string memory name) private view {
        (bool ok, bytes memory ret) = impl.staticcall(data);
        _require(
            !ok
                && keccak256(ret)
                    == keccak256(abi.encodeWithSelector(Initializable.InvalidInitialization.selector)),
            string.concat(name, " implementation initialize reverts InvalidInitialization")
        );
    }

    function _verifyDeployEoas(Manifest memory m, address[] memory eoas) private view {
        _require(eoas.length != 0, "DEPLOY_EOAS is empty");
        TimelockController tl = TimelockController(payable(m.timelock));
        bytes32[4] memory all = [ADMIN, PROPOSER, EXECUTOR, CANCELLER];
        for (uint256 i; i < eoas.length; ++i) {
            address e = eoas[i];
            for (uint256 r; r < 4; ++r) {
                _require(!tl.hasRole(all[r], e), "deploy EOA holds a Timelock role");
            }
            _require(
                e != IOwnable2Step(m.registry).owner() && e != IOwnable2Step(m.registry).pendingOwner()
                    && e != IOwnable2Step(m.reputation).owner()
                    && e != IOwnable2Step(m.reputation).pendingOwner(),
                "deploy EOA owns Registry or Reputation"
            );
            IMHCircleRegistry registry = IMHCircleRegistry(m.registry);
            _require(
                e != registry.operator() && e != registry.guardian() && e != registry.treasury(),
                "deploy EOA holds a registry role"
            );
            _require(e != MHGuardianCanceller(m.canceller).guardian(), "deploy EOA is the canceller guardian");
            _require(e != m.govSafe && e != m.guardianSafe && e != m.treasurySafe, "deploy EOA is a Safe");
        }
    }

    function _verifySafe(string memory name, address safe, address[] memory owners, uint256 threshold)
        private
        view
    {
        _require(
            safe.codehash == BaseChain.SAFE_PROXY_CODEHASH, string.concat(name, " Safe: canonical proxy")
        );
        _require(
            address(uint160(uint256(vm.load(safe, BaseChain.SAFE_SINGLETON_SLOT)))) == BaseChain.SAFE_L2,
            string.concat(name, " Safe: SafeL2 v1.4.1 singleton")
        );
        _require(ISafe(safe).getThreshold() == threshold, string.concat(name, " Safe: threshold"));
        _require(ISafe(safe).getOwners().length == owners.length, string.concat(name, " Safe: owner count"));
        for (uint256 i; i < owners.length; ++i) {
            _require(ISafe(safe).isOwner(owners[i]), string.concat(name, " Safe: owner set"));
        }
        (address[] memory modules,) = ISafe(safe).getModulesPaginated(BaseChain.SAFE_SENTINEL, 1);
        _require(modules.length == 0, string.concat(name, " Safe: no modules"));
        _require(
            vm.load(safe, BaseChain.SAFE_GUARD_SLOT) == bytes32(0), string.concat(name, " Safe: no guard")
        );
        _require(
            address(uint160(uint256(vm.load(safe, BaseChain.SAFE_FALLBACK_HANDLER_SLOT))))
                == BaseChain.FALLBACK_HANDLER,
            string.concat(name, " Safe: fallback handler")
        );
    }

    // ================================================================ Helpers

    function _knownAddresses(Manifest memory m) private pure returns (address[] memory k) {
        uint256 n = 13 + m.govOwners.length + m.guardianOwners.length + m.treasuryOwners.length;
        k = new address[](n);
        address[13] memory fixedSet = [
            address(0),
            m.govSafe,
            m.guardianSafe,
            m.treasurySafe,
            m.operator,
            m.rotatingImpl,
            m.accumulationImpl,
            m.timelock,
            m.canceller,
            m.registry,
            m.reputation,
            m.factory,
            BaseChain.CREATEX
        ];
        uint256 c;
        for (uint256 i; i < 13; ++i) {
            k[c++] = fixedSet[i];
        }
        for (uint256 i; i < m.govOwners.length; ++i) {
            k[c++] = m.govOwners[i];
        }
        for (uint256 i; i < m.guardianOwners.length; ++i) {
            k[c++] = m.guardianOwners[i];
        }
        for (uint256 i; i < m.treasuryOwners.length; ++i) {
            k[c++] = m.treasuryOwners[i];
        }
    }

    /// @dev Merges two log lists (each in log order) by (blockNumber, logIndex).
    function _merge(Vm.EthGetLogs[] memory a, Vm.EthGetLogs[] memory b)
        private
        pure
        returns (RoleEvent[] memory e)
    {
        e = new RoleEvent[](a.length + b.length);
        uint256 i;
        uint256 j;
        for (uint256 k; k < e.length; ++k) {
            bool takeA = j == b.length
                || (i < a.length
                    && (a[i].blockNumber < b[j].blockNumber
                        || (a[i].blockNumber == b[j].blockNumber && a[i].logIndex < b[j].logIndex)));
            Vm.EthGetLogs memory l = takeA ? a[i++] : b[j++];
            e[k] = RoleEvent({
                role: l.topics[1], account: address(uint160(uint256(l.topics[2]))), granted: takeA
            });
        }
    }

    function _append(RoleEvent[] memory a, RoleEvent[] memory b) private pure returns (RoleEvent[] memory c) {
        c = new RoleEvent[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }

    function _require(bool ok, string memory check) private pure {
        if (!ok) revert VerifyFailed(check);
    }
}
