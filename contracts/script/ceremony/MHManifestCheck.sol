// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHCircleConstants } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";

import { BaseChain } from "./BaseChain.sol";
import { ICreateX } from "./DeployInterfaces.sol";
import { MHDeployPlan, DeployConfig, SafeSpec, Plan } from "./MHDeployPlan.sol";
import { MHDeployJson } from "./MHDeployJson.sol";

/// @title MHManifestCheck
/// @notice Offline, non-circular check of a ceremony directory (audit R1-05). The old check compared
///         `keccak(local creation code ‖ manifest constructorArgs)` with the manifest's own `initCodeHash`, so a
///         manifest that wired an attacker's roles or addresses passed. This one trusts only the manifest's
///         INPUTS (chain, roles, Safes, params, salt seed, nonce, commit) and the local build:
///         1. policy: re-applies `BuildBaseBatch.validate`'s offline bounds (delay in [48h, 7d], fee caps, Safe
///            threshold ≥ 2 and below the owner count, distinct non-zero roles, no owner that is a role, Gov and
///            Guardian keys disjoint, operator owning no Safe, canonical USDC, non-zero seed, commit format);
///         2. re-derivation: rebuilds the plan with `MHDeployPlan.plan` and requires the manifest, both batch
///            files and the allowVault proposal files to equal the re-derived bytes exactly. Audit R2-04: the runtime
///            codehashes and sizes are derived too, by running every initcode in the local EVM at its predicted
///            address in batch order (`runtimeOf`, state reverted), never copied from the manifest: under CREATE3
///            an address commits to no code, so the manifest's runtime codehash is the only link between the
///            deployed code and the audited build, and `VerifyBase` compares the chain with it;
///         3. independent decoding, without the planner: every address is recomputed from its salt with the
///            CreateX CREATE3 formula, every constructor argument list is decoded and compared with the roles,
///            every batch transaction is decoded from the batch files (the bytes the Safe signs), and every Safe
///            transaction hash is recomputed from those bytes. So a tampered planner is caught too.
///         Runs with no RPC: `forge script script/CheckManifest.s.sol --sig "run(string)" <dir>`.
library MHManifestCheck {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice A re-derived or decoded value differs from the ceremony files.
    error ManifestMismatch(string what);
    /// @notice An input breaks the ceremony policy.
    error PolicyViolation(string what);

    string internal constant BATCH1A = "batch1a-rotating-implementation.safe.json";
    string internal constant BATCH1B = "batch1b-accumulation-implementation.safe.json";
    string internal constant BATCH2 = "batch2-governance.safe.json";
    string internal constant SCHEDULE = "proposal-allow-vault.schedule.safe.json";
    string internal constant EXECUTE = "proposal-allow-vault.execute.safe.json";

    // ================================================================ Entry point

    /// @notice Checks the ceremony files in `dir` (with a trailing `/` or not). Reverts on the first problem.
    ///         Not `view`: it runs every initcode in the local EVM (state reverted) to derive the runtime code.
    /// @param dir Directory holding `manifest.json` and the batch files.
    /// @return p The re-derived plan, runtime codehashes included.
    function check(string memory dir) internal returns (Plan memory p) {
        dir = _slash(dir);
        string memory json = vm.readFile(string.concat(dir, "manifest.json"));
        (DeployConfig memory cfg, uint256 chainId) = configOf(json);
        policy(cfg, chainId);
        p = MHDeployPlan.plan(cfg, chainId);
        deriveRuntime(p);
        _rederive(p, json, dir);
        _independent(p, json, dir);
    }

    /// @notice `check`, then requires the manifest's inputs hash (`MHDeployPlan.inputsHash`: chain, every role,
    ///         every Safe with its owners and threshold, the operator, vault, wrapper, delay, fees, seed, nonce and
    ///         commit) to equal `expected`, taken from the independent ceremony record (audit 2 R2-08). The policy
    ///         only checks the shape of the non-Gov inputs; this ties every one of them to a record the signer did not
    ///         get from the coordinator.
    /// @param dir Directory holding `manifest.json` and the batch files.
    /// @param expected The inputs hash from the independent ceremony record.
    /// @return p The re-derived plan.
    function checkInputs(string memory dir, bytes32 expected) internal returns (Plan memory p) {
        p = check(dir);
        _require(MHDeployPlan.inputsHash(p) == expected, "inputsHash != the independent ceremony record");
    }

    // ================================================================ Runtime derivation (audit R2-04)

    /// @notice Fills in every deployment's `runtimeCodeHash` and `runtimeSize` from the local build (`runtimeOf`).
    /// @param p The plan.
    function deriveRuntime(Plan memory p) internal {
        bytes[7] memory init;
        address[7] memory at;
        for (uint256 i; i < 7; ++i) {
            init[i] = p.deployments[i].initCode;
            at[i] = p.deployments[i].addr;
        }
        (bytes32[7] memory h, uint256[7] memory size) = runtimeOf(init, at);
        for (uint256 i; i < 7; ++i) {
            p.deployments[i].runtimeCodeHash = h[i];
            p.deployments[i].runtimeSize = size[i];
        }
    }

    /// @notice The runtime code each initcode produces, run in deployment order at its predicted address (the
    ///         factory's constructor checks the reputation's and the implementations' wiring, so they must sit at
    ///         their addresses first). Each initcode is etched and called, the runtime it returns is etched, and all
    ///         state is reverted at the end (it works offline, and on a fork with the real contracts deployed).
    /// @param init The seven initcodes, in `MHDeployPlan` order.
    /// @param at Their CREATE3 addresses.
    /// @return h keccak256 of each runtime code.
    /// @return size Each runtime code's length.
    function runtimeOf(bytes[7] memory init, address[7] memory at)
        internal
        returns (bytes32[7] memory h, uint256[7] memory size)
    {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 7; ++i) {
            vm.etch(at[i], init[i]);
            (bool ok, bytes memory runtime) = at[i].call("");
            _require(ok && runtime.length != 0, "an initcode reverts in the local EVM");
            vm.etch(at[i], runtime);
            h[i] = keccak256(runtime);
            size[i] = runtime.length;
        }
        vm.revertToState(snap);
    }

    /// @notice Layer 3 alone, without the planner: what still rejects a tamper if the planner itself had been
    ///         changed to produce it (used by the tests to show the layers are independent).
    /// @param dir The ceremony directory.
    function independentOnly(string memory dir) internal view {
        dir = _slash(dir);
        string memory json = vm.readFile(string.concat(dir, "manifest.json"));
        Plan memory p;
        (p.cfg, p.chainId) = configOf(json);
        _independent(p, json, dir);
    }

    function _slash(string memory dir) private pure returns (string memory) {
        bytes memory b = bytes(dir);
        return b.length != 0 && b[b.length - 1] != "/" ? string.concat(dir, "/") : dir;
    }

    /// @notice The ceremony inputs recorded in a manifest.
    /// @param json The manifest.
    /// @return cfg The inputs.
    /// @return chainId The chain.
    function configOf(string memory json) internal pure returns (DeployConfig memory cfg, uint256 chainId) {
        chainId = vm.parseJsonUint(json, ".chainId");
        cfg.usdc = vm.parseJsonAddress(json, ".external.usdc");
        cfg.gov = _safe(json, "gov");
        cfg.guardian = _safe(json, "guardian");
        cfg.treasury = _safe(json, "treasury");
        if (vm.parseJsonAddress(json, ".roles.govSafe") != cfg.gov.safe) {
            revert ManifestMismatch("roles.govSafe");
        }
        if (vm.parseJsonAddress(json, ".roles.guardianSafe") != cfg.guardian.safe) {
            revert ManifestMismatch("roles.guardianSafe");
        }
        if (vm.parseJsonAddress(json, ".roles.treasurySafe") != cfg.treasury.safe) {
            revert ManifestMismatch("roles.treasurySafe");
        }
        cfg.operator = vm.parseJsonAddress(json, ".roles.operator");
        cfg.circleVault = vm.parseJsonAddress(json, ".roles.circleVault");
        cfg.earnWrapper = vm.parseJsonAddress(json, ".roles.earnWrapper");
        cfg.timelockDelay = vm.parseJsonUint(json, ".params.timelockDelay");
        cfg.rotatingFeeBps = vm.parseJsonUint(json, ".params.rotatingFeeBps");
        cfg.accumulationFeeBps = vm.parseJsonUint(json, ".params.accumulationFeeBps");
        cfg.saltSeed = vm.parseJsonBytes32(json, ".params.saltSeed");
        cfg.govNonce = vm.parseJsonUint(json, ".params.govSafeNonce");
        cfg.commit = vm.parseJsonString(json, ".commit");
    }

    // ================================================================ 1. Policy

    /// @notice The offline part of `BuildBaseBatch.validate`, re-applied to the recorded inputs.
    /// @param c The inputs.
    /// @param chainId The chain.
    function policy(DeployConfig memory c, uint256 chainId) internal pure {
        (address usdc,) = BaseChain.usdcOf(chainId);
        _policy(usdc != address(0) && c.usdc == usdc, "USDC is the chain's canonical USDC");
        _policy(
            c.timelockDelay >= BaseChain.MIN_TIMELOCK_DELAY
                && c.timelockDelay <= BaseChain.MAX_TIMELOCK_DELAY,
            "Timelock delay in [48h, 7 days]"
        );
        _policy(c.rotatingFeeBps <= MHCircleConstants.MAX_ROTATING_FEE_BPS, "rotating fee cap");
        _policy(c.accumulationFeeBps <= MHCircleConstants.MAX_ACCUMULATION_FEE_BPS, "accumulation fee cap");
        _policy(c.saltSeed != bytes32(0), "salt seed non-zero");
        _requireCommit(c.commit);
        // Audit R2-03: the vault is the one input no initcode, address or batch hash commits to; it must be the one
        // pinned for the chain in reviewed source (`BaseChain.circleVaultOf`), or none.
        _policy(
            c.circleVault == address(0) || c.circleVault == BaseChain.circleVaultOf(chainId),
            "circle vault is the chain's pinned vault"
        );

        address[6] memory roles =
            [c.gov.safe, c.guardian.safe, c.treasury.safe, c.operator, c.circleVault, c.earnWrapper];
        for (uint256 i; i < 6; ++i) {
            if (roles[i] == address(0)) {
                _policy(i >= 4, "roles non-zero");
                continue;
            }
            for (uint256 j = i + 1; j < 6; ++j) {
                _policy(roles[i] != roles[j], "roles distinct");
            }
        }
        // Audit 2 R1-26: offline, the operator cannot be checked for code, but it must not be a known contract that
        // forwards calls for anyone (or another pinned contract of the ceremony).
        address op = c.operator;
        _policy(
            op != BaseChain.MULTICALL3 && op != BaseChain.MULTISEND_CALL_ONLY && op != BaseChain.CREATEX
                && op != BaseChain.SAFE_L2 && op != BaseChain.SAFE_PROXY_FACTORY
                && op != BaseChain.FALLBACK_HANDLER && op != c.usdc,
            "operator is not a known contract"
        );
        _safePolicy(c.gov, BaseChain.ROLE_GOV, roles);
        _safePolicy(c.guardian, BaseChain.ROLE_GUARDIAN, roles);
        _safePolicy(c.treasury, BaseChain.ROLE_TREASURY, roles);
        for (uint256 i; i < c.gov.owners.length; ++i) {
            for (uint256 j; j < c.guardian.owners.length; ++j) {
                _policy(c.gov.owners[i] != c.guardian.owners[j], "Gov and Guardian keys disjoint");
            }
        }
    }

    function _safePolicy(SafeSpec memory s, uint8 role, address[6] memory roles) private pure {
        uint256 n = s.owners.length;
        // Audit R2-17: the spec §5 threshold per role (Gov 3-of-5, minimum 2-of-3; Guardian 2-of-4; Treasury 2-of-3).
        _policy(BaseChain.safePolicyOk(role, s.threshold, n), "Safe threshold policy");
        for (uint256 i; i < n; ++i) {
            address o = s.owners[i];
            _policy(o != address(0) && o != BaseChain.SAFE_SENTINEL, "Safe owner valid");
            // Closing review: the planner records owners sorted ascending, so the inputs hash is canonical.
            _policy(i == 0 || s.owners[i - 1] < o, "Safe owners sorted ascending");
            for (uint256 j = i + 1; j < n; ++j) {
                _policy(s.owners[j] != o, "Safe owners unique");
            }
            // Audit R1-17: no Safe is owned by a role (another Safe, the operator, the vault or the wrapper).
            for (uint256 r; r < 6; ++r) {
                _policy(roles[r] == address(0) || o != roles[r], "Safe owner is not a role");
            }
        }
    }

    // ================================================================ 2. Re-derivation

    function _rederive(Plan memory p, string memory json, string memory dir) private view {
        // Audit R2-04: the derived runtime must be what the manifest records (named first, for a clear error).
        for (uint256 i; i < p.deployments.length; ++i) {
            string memory key = p.deployments[i].key;
            string memory k = string.concat(".contracts.", key);
            _require(
                vm.parseJsonBytes32(json, string.concat(k, ".runtimeCodeHash"))
                        == p.deployments[i].runtimeCodeHash
                    && vm.parseJsonUint(json, string.concat(k, ".runtimeSize"))
                        == p.deployments[i].runtimeSize,
                string.concat(key, ": runtime code differs from the local build")
            );
        }
        _same(MHDeployJson.manifest(p), json, "manifest.json != the plan re-derived from its inputs");
        _same(MHDeployJson.batchFile(p, p.batch1a), _read(dir, BATCH1A), "batch 1a file != re-derived");
        _same(MHDeployJson.batchFile(p, p.batch1b), _read(dir, BATCH1B), "batch 1b file != re-derived");
        _same(MHDeployJson.batchFile(p, p.batch2), _read(dir, BATCH2), "batch 2 file != re-derived");
        if (p.hasProposal) {
            _same(
                MHDeployJson.proposalFile(p, p.allowVault.schedule, "schedule"),
                _read(dir, SCHEDULE),
                "allowVault schedule file != re-derived"
            );
            _same(
                MHDeployJson.proposalFile(p, p.allowVault.execute, "execute"),
                _read(dir, EXECUTE),
                "allowVault execute file != re-derived"
            );
        }
    }

    // ================================================================ 3. Independent decoding

    struct Addrs {
        address rot;
        address acc;
        address timelock;
        address canceller;
        address registry;
        address reputation;
        address factory;
    }

    function _independent(Plan memory p, string memory json, string memory dir) private view {
        DeployConfig memory c = p.cfg;
        uint256 chainId = p.chainId;
        Addrs memory a;
        a.rot = _address(json, c, chainId, "rotatingImpl");
        a.acc = _address(json, c, chainId, "accumulationImpl");
        a.timelock = _address(json, c, chainId, "timelock");
        a.canceller = _address(json, c, chainId, "canceller");
        a.registry = _address(json, c, chainId, "registry");
        a.reputation = _address(json, c, chainId, "reputation");
        a.factory = _address(json, c, chainId, "factory");

        bytes[7] memory init;
        init[0] = _initCode(
            json,
            "rotatingImpl",
            type(MHRotatingCircle).creationCode,
            abi.encode(c.usdc, a.registry, a.reputation)
        );
        init[1] = _initCode(
            json,
            "accumulationImpl",
            type(MHAccumulationCircle).creationCode,
            abi.encode(c.usdc, a.registry, a.reputation)
        );
        address[] memory govOnly = new address[](1);
        govOnly[0] = c.gov.safe;
        init[2] = _initCode(
            json,
            "timelock",
            type(TimelockController).creationCode,
            abi.encode(c.timelockDelay, govOnly, govOnly, c.gov.safe)
        );
        init[3] = _initCode(
            json,
            "canceller",
            type(MHGuardianCanceller).creationCode,
            abi.encode(a.timelock, a.registry, c.earnWrapper, c.guardian.safe)
        );
        init[4] = _initCode(
            json,
            "registry",
            type(MHCircleRegistry).creationCode,
            abi.encode(a.timelock, c.usdc, c.operator, c.guardian.safe, c.treasury.safe)
        );
        init[5] =
            _initCode(json, "reputation", type(MHReputation).creationCode, abi.encode(a.timelock, a.factory));
        init[6] = _initCode(
            json,
            "factory",
            type(MHCircleFactory).creationCode,
            abi.encode(a.registry, a.reputation, a.rot, a.acc)
        );

        _checkBatch1(json, dir, c, chainId, init);
        _checkBatch2(json, dir, c, chainId, init, a);
        if (c.circleVault != address(0)) {
            _checkProposal(json, dir, c, a);
            _checkProposalTxs(json, c, chainId, a);
        }
        _require(vm.parseJsonBytes32(json, ".inputsHash") == keccak256(abi.encode(chainId, c)), "inputs hash");
    }

    /// @dev The address of `key`: its salt must be `Gov ‖ 0x01 ‖ bytes11(keccak(seed, key))`, guarded by CreateX to
    ///      `keccak(gov, chainId, salt)`, deployed through CreateX's CREATE3 proxy.
    function _address(string memory json, DeployConfig memory c, uint256 chainId, string memory key)
        private
        pure
        returns (address addr)
    {
        string memory k = string.concat(".contracts.", key);
        bytes32 salt = bytes32(
            abi.encodePacked(c.gov.safe, bytes1(0x01), bytes11(keccak256(abi.encode(c.saltSeed, key))))
        );
        bytes32 guarded = keccak256(abi.encode(c.gov.safe, chainId, salt));
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            BaseChain.CREATEX,
                            guarded,
                            keccak256(hex"67363d3d37363d34f03d5260086018f3")
                        )
                    )
                )
            )
        );
        addr = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
        _require(vm.parseJsonBytes32(json, string.concat(k, ".salt")) == salt, string.concat(key, ": salt"));
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".guardedSalt")) == guarded,
            string.concat(key, ": guarded salt")
        );
        _require(
            vm.parseJsonAddress(json, string.concat(k, ".address")) == addr, string.concat(key, ": address")
        );
    }

    /// @dev Local creation code ‖ the constructor arguments the roles require; the manifest must record exactly these.
    function _initCode(string memory json, string memory key, bytes memory creation, bytes memory args)
        private
        pure
        returns (bytes memory init)
    {
        string memory k = string.concat(".contracts.", key);
        init = abi.encodePacked(creation, args);
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".creationCodeHash")) == keccak256(creation),
            string.concat(key, ": creation code differs from the local build")
        );
        _require(
            keccak256(vm.parseJsonBytes(json, string.concat(k, ".constructorArgs"))) == keccak256(args),
            string.concat(key, ": constructor arguments differ from the roles")
        );
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".initCodeHash")) == keccak256(init),
            string.concat(key, ": initcode hash")
        );
    }

    function _checkBatch1(
        string memory json,
        string memory dir,
        DeployConfig memory c,
        uint256 chainId,
        bytes[7] memory init
    ) private view {
        // Audit 2 R1-25: one implementation per Safe transaction (1a at N, 1b at N+1).
        string memory f = _read(dir, BATCH1A);
        _require(_txCount(f) == 1, "batch 1a: one transaction");
        bytes[] memory data = new bytes[](1);
        data[0] = _deployTx(f, 0, c, "rotatingImpl", init[0]);
        _checkSafeTx(json, "batch1a", c, chainId, _targets(1, BaseChain.CREATEX), data, c.govNonce);
        f = _read(dir, BATCH1B);
        _require(_txCount(f) == 1, "batch 1b: one transaction");
        data[0] = _deployTx(f, 0, c, "accumulationImpl", init[1]);
        _checkSafeTx(json, "batch1b", c, chainId, _targets(1, BaseChain.CREATEX), data, c.govNonce + 1);
    }

    function _checkBatch2(
        string memory json,
        string memory dir,
        DeployConfig memory c,
        uint256 chainId,
        bytes[7] memory init,
        Addrs memory a
    ) private view {
        string memory f = _read(dir, BATCH2);
        _require(_txCount(f) == 7, "batch 2: seven transactions");
        address[] memory to = _targets(7, BaseChain.CREATEX);
        to[2] = a.timelock;
        to[6] = a.timelock;
        bytes[] memory data = new bytes[](7);
        data[0] = _deployTx(f, 0, c, "timelock", init[2]);
        data[1] = _deployTx(f, 1, c, "canceller", init[3]);
        data[2] = abi.encodeCall(IAccessControl.grantRole, (keccak256("CANCELLER_ROLE"), a.canceller));
        data[3] = _deployTx(f, 3, c, "registry", init[4]);
        data[4] = _deployTx(f, 4, c, "reputation", init[5]);
        data[5] = _deployTx(f, 5, c, "factory", init[6]);
        data[6] = abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), c.gov.safe));
        for (uint256 i; i < 7; ++i) {
            _requireTx(f, i, to[i], data[i], "batch 2");
        }
        _checkSafeTx(json, "batch2", c, chainId, to, data, c.govNonce + 2);
    }

    /// @dev Transaction `i` of a batch file must be `CreateX.deployCreate3(salt(key), init)` with value 0.
    function _deployTx(
        string memory f,
        uint256 i,
        DeployConfig memory c,
        string memory key,
        bytes memory init
    ) private pure returns (bytes memory data) {
        bytes32 salt = bytes32(
            abi.encodePacked(c.gov.safe, bytes1(0x01), bytes11(keccak256(abi.encode(c.saltSeed, key))))
        );
        data = abi.encodeCall(ICreateX.deployCreate3, (salt, init));
        _requireTx(f, i, BaseChain.CREATEX, data, key);
    }

    function _requireTx(string memory f, uint256 i, address to, bytes memory data, string memory what)
        private
        pure
    {
        string memory k = string.concat(".transactions[", vm.toString(i), "]");
        _require(
            vm.parseJsonAddress(f, string.concat(k, ".to")) == to, string.concat(what, ": transaction target")
        );
        _require(
            keccak256(bytes(vm.parseJsonString(f, string.concat(k, ".value")))) == keccak256("0"),
            string.concat(what, ": transaction value")
        );
        _require(
            keccak256(vm.parseJsonBytes(f, string.concat(k, ".data"))) == keccak256(data),
            string.concat(what, ": transaction data")
        );
    }

    /// @dev The Safe transaction the signers approve, recomputed from the decoded calls: a DELEGATECALL to
    ///      MultiSendCallOnly of the packed calls or, for a single call (batches 1a and 1b, audit 2 R1-25), that call
    ///      as a plain CALL (as Safe{Wallet} sends a one-transaction batch); every gas field zero, at `nonce`; Safe
    ///      v1.4.1 EIP-712.
    function _checkSafeTx(
        string memory json,
        string memory key,
        DeployConfig memory c,
        uint256 chainId,
        address[] memory to,
        bytes[] memory data,
        uint256 nonce
    ) private pure {
        bytes32[4] memory h = _safeTxHashes(c.gov.safe, chainId, to, data, nonce);
        string memory k = string.concat(".batches.", key);
        bool single = to.length == 1;
        _require(vm.parseJsonUint(json, string.concat(k, ".nonce")) == nonce, string.concat(key, ": nonce"));
        _require(
            vm.parseJsonAddress(json, string.concat(k, ".to"))
                == (single ? to[0] : BaseChain.MULTISEND_CALL_ONLY),
            string.concat(key, ": Safe transaction target")
        );
        _require(
            vm.parseJsonUint(json, string.concat(k, ".operation")) == (single ? 0 : 1),
            string.concat(key, ": Safe transaction operation")
        );
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".dataHash")) == h[0],
            string.concat(key, ": data hash")
        );
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".domainHash")) == h[1], string.concat(key, ": domain")
        );
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".messageHash")) == h[2],
            string.concat(key, ": message")
        );
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".safeTxHash")) == h[3],
            string.concat(key, ": safeTxHash")
        );
    }

    /// @dev [Safe transaction data hash, domain separator, SafeTx struct hash, safeTxHash], written out here rather
    ///      than taken from `MHDeployPlan` so a planner change cannot hide a different signed transaction.
    function _safeTxHashes(
        address safe,
        uint256 chainId,
        address[] memory to,
        bytes[] memory data,
        uint256 nonce
    ) private pure returns (bytes32[4] memory h) {
        bool single = to.length == 1;
        bytes memory packed;
        for (uint256 i; i < to.length; ++i) {
            packed = abi.encodePacked(packed, uint8(0), to[i], uint256(0), data[i].length, data[i]);
        }
        h[0] = single ? keccak256(data[0]) : keccak256(abi.encodeWithSignature("multiSend(bytes)", packed));
        h[1] = keccak256(
            abi.encode(keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"), chainId, safe)
        );
        h[2] = keccak256(
            abi.encode(
                keccak256(
                    "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
                ),
                single ? to[0] : BaseChain.MULTISEND_CALL_ONLY,
                uint256(0),
                h[0],
                uint8(single ? 0 : 1),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                nonce
            )
        );
        h[3] = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), h[1], h[2]));
    }

    function _checkProposal(string memory json, string memory dir, DeployConfig memory c, Addrs memory a)
        private
        view
    {
        bytes memory call_ = abi.encodeCall(IMHCircleRegistry.allowVault, (c.circleVault));
        bytes32 salt =
            keccak256(abi.encode(keccak256("moolahub.circles.allowVault"), c.circleVault, c.saltSeed));
        bytes32 id = keccak256(abi.encode(a.registry, uint256(0), call_, bytes32(0), salt));
        _require(vm.parseJsonAddress(json, ".allowVaultProposal.target") == a.registry, "proposal target");
        _require(vm.parseJsonBytes32(json, ".allowVaultProposal.operationId") == id, "proposal operation id");
        _require(vm.parseJsonUint(json, ".allowVaultProposal.delay") == c.timelockDelay, "proposal delay");
        bytes memory schedule = abi.encodeCall(
            TimelockController.schedule, (a.registry, 0, call_, bytes32(0), salt, c.timelockDelay)
        );
        bytes memory execute =
            abi.encodeCall(TimelockController.execute, (a.registry, 0, call_, bytes32(0), salt));
        string memory s = _read(dir, SCHEDULE);
        string memory e = _read(dir, EXECUTE);
        _require(_txCount(s) == 1 && _txCount(e) == 1, "proposal files: one transaction each");
        _requireTx(s, 0, a.timelock, schedule, "allowVault schedule");
        _requireTx(e, 0, a.timelock, execute, "allowVault execute");
    }

    /// @dev Audit R2-03: the two plain Gov Safe transactions (operation 0, to the Timelock) that schedule and execute
    ///      the allowVault operation, at nonces N+3 and N+4 (after the three batches, audit 2 R1-25).
    function _checkProposalTxs(string memory json, DeployConfig memory c, uint256 chainId, Addrs memory a)
        private
        pure
    {
        bytes memory call_ = abi.encodeCall(IMHCircleRegistry.allowVault, (c.circleVault));
        bytes32 salt =
            keccak256(abi.encode(keccak256("moolahub.circles.allowVault"), c.circleVault, c.saltSeed));
        _checkPlainTx(
            json,
            "scheduleSafeTx",
            c.gov.safe,
            chainId,
            a.timelock,
            abi.encodeCall(
                TimelockController.schedule, (a.registry, 0, call_, bytes32(0), salt, c.timelockDelay)
            ),
            c.govNonce + 3
        );
        _checkPlainTx(
            json,
            "executeSafeTx",
            c.gov.safe,
            chainId,
            a.timelock,
            abi.encodeCall(TimelockController.execute, (a.registry, 0, call_, bytes32(0), salt)),
            c.govNonce + 4
        );
    }

    /// @dev A plain Safe v1.4.1 transaction (CALL, value 0, every gas field zero), hashed here independently of
    ///      `MHDeployPlan`, against `.allowVaultProposal.<key>`.
    function _checkPlainTx(
        string memory json,
        string memory key,
        address safe,
        uint256 chainId,
        address to,
        bytes memory data,
        uint256 nonce
    ) private pure {
        string memory k = string.concat(".allowVaultProposal.", key);
        bytes32 domain = keccak256(
            abi.encode(keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"), chainId, safe)
        );
        bytes32 message = keccak256(
            abi.encode(
                keccak256(
                    "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
                ),
                to,
                uint256(0),
                keccak256(data),
                uint8(0),
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                nonce
            )
        );
        _require(vm.parseJsonUint(json, string.concat(k, ".nonce")) == nonce, string.concat(key, ": nonce"));
        _require(vm.parseJsonAddress(json, string.concat(k, ".to")) == to, string.concat(key, ": to"));
        _require(
            vm.parseJsonBytes32(json, string.concat(k, ".safeTxHash"))
                == keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, message)),
            string.concat(key, ": safeTxHash")
        );
    }

    // ================================================================ Helpers

    function _safe(string memory json, string memory name) private pure returns (SafeSpec memory s) {
        string memory k = string.concat(".safes.", name);
        s.safe = vm.parseJsonAddress(json, string.concat(k, ".address"));
        s.owners = vm.parseJsonAddressArray(json, string.concat(k, ".owners"));
        s.threshold = vm.parseJsonUint(json, string.concat(k, ".threshold"));
    }

    function _targets(uint256 n, address to) private pure returns (address[] memory t) {
        t = new address[](n);
        for (uint256 i; i < n; ++i) {
            t[i] = to;
        }
    }

    function _txCount(string memory f) private view returns (uint256 n) {
        while (vm.keyExistsJson(f, string.concat(".transactions[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    function _read(string memory dir, string memory file) private view returns (string memory) {
        return vm.readFile(string.concat(dir, file));
    }

    function _same(string memory a, string memory b, string memory what) private pure {
        _require(keccak256(bytes(a)) == keccak256(bytes(b)), what);
    }

    function _requireCommit(string memory commit) private pure {
        bytes memory b = bytes(commit);
        _policy(b.length == 40, "commit is 40 lowercase hex characters");
        for (uint256 i; i < 40; ++i) {
            bytes1 ch = b[i];
            _policy(
                (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f"), "commit is 40 lowercase hex characters"
            );
        }
    }

    function _policy(bool ok, string memory what) private pure {
        if (!ok) revert PolicyViolation(what);
    }

    function _require(bool ok, string memory what) private pure {
        if (!ok) revert ManifestMismatch(what);
    }
}
