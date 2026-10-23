// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";

import { BaseChain } from "./BaseChain.sol";
import { ICreateX, IMultiSendCallOnly } from "./DeployInterfaces.sol";

/// @notice A Safe and the owners and threshold the ceremony expects it to have.
/// @param safe The Safe proxy.
/// @param owners Expected owners (any order on input, compared as a set; `MHDeployPlan.plan` sorts them ascending, the
///        order the manifest records and `inputsHash` hashes).
/// @param threshold Expected threshold.
struct SafeSpec {
    address safe;
    address[] owners;
    uint256 threshold;
}

/// @notice Every input of the ceremony. `BuildBaseBatch` reads each field from the environment with no default.
/// @param usdc USDC on the target chain (must equal the pinned canonical address).
/// @param gov Gov Safe (deployer, Timelock proposer/executor/canceller, temporary Timelock admin).
/// @param guardian Guardian Safe (registry guardian, canceller guardian).
/// @param treasury Treasury Safe (fee recipient).
/// @param operator Registry operator (backend hot key that creates circles).
/// @param circleVault Vault V2 to allowlist through the Timelock after deployment; address(0) = none.
/// @param earnWrapper Timelock-owned Earn wrapper whose `setIsSentinel` is a protected rotation call; 0 = none.
/// @param timelockDelay Timelock minimum delay in seconds.
/// @param rotatingFeeBps Launch fee policy for rotating circles (per-circle; recorded, not deployed).
/// @param accumulationFeeBps Launch fee policy for accumulation circles (per-circle; recorded, not deployed).
/// @param saltSeed Seed of the 11 entropy bytes of each CREATE3 salt (fixed so the manifest is reproducible).
/// @param govNonce Gov Safe nonce of batch 1a; batch 1b uses `govNonce + 1` and batch 2 `govNonce + 2` (audit 2 R1-25).
/// @param commit The audited commit (40 lowercase hex characters), recorded in the manifest.
struct DeployConfig {
    address usdc;
    SafeSpec gov;
    SafeSpec guardian;
    SafeSpec treasury;
    address operator;
    address circleVault;
    address earnWrapper;
    uint256 timelockDelay;
    uint256 rotatingFeeBps;
    uint256 accumulationFeeBps;
    bytes32 saltSeed;
    uint256 govNonce;
    string commit;
}

/// @notice One CREATE3 deployment through CreateX.
struct Deployment {
    string key;
    string contractName;
    uint256 batch;
    bytes32 salt;
    bytes32 guardedSalt;
    address addr;
    bytes creationCode;
    bytes constructorArgs;
    bytes initCode;
    bytes32 runtimeCodeHash;
    uint256 runtimeSize;
}

/// @notice One CALL inside a Safe batch.
struct Call {
    address to;
    uint256 value;
    bytes data;
    string description;
}

/// @notice One Gov Safe transaction: a DELEGATECALL to MultiSendCallOnly wrapping `calls`, or, for a single call, that
///         call itself as a plain CALL (operation 0), which is how Safe{Wallet}'s Transaction Builder sends a
///         one-transaction batch (audit 2 R1-25: batches 1a and 1b).
struct SafeBatch {
    string key;
    string fileName;
    string title;
    Call[] calls;
    /// @dev The Safe transaction's `to`, `operation` and `data`.
    address to;
    uint8 operation;
    bytes txData;
    uint256 nonce;
    bytes32 domainSeparator;
    bytes32 messageHash;
    bytes32 safeTxHash;
    uint256 gasUsed;
    uint256 txGas;
}

/// @notice A plain Gov Safe transaction (operation 0, CALL, every gas field zero) and the hashes signers compare.
struct SafeTxRef {
    uint256 nonce;
    bytes32 messageHash;
    bytes32 safeTxHash;
}

/// @notice The timelocked `registry.allowVault(circleVault)` operation (scheduled by Gov after deployment). Audit
///         R2-03: the two Gov Safe transactions that schedule and execute it are precomputed at nonces `govNonce + 3`
///         and `govNonce + 4` (right after the three batches), so signers compare a device hash at step 10 too.
struct Proposal {
    address target;
    bytes data;
    bytes32 predecessor;
    bytes32 salt;
    uint256 delay;
    bytes32 operationId;
    Call schedule;
    Call execute;
    SafeTxRef scheduleTx;
    SafeTxRef executeTx;
}

/// @notice The full, deterministic deployment plan.
struct Plan {
    DeployConfig cfg;
    uint256 chainId;
    string network;
    Deployment[] deployments;
    SafeBatch batch1a;
    SafeBatch batch1b;
    SafeBatch batch2;
    bool hasProposal;
    Proposal allowVault;
}

/// @title MHDeployPlan
/// @notice Pure planning for the spec §5 ceremony: CREATE3 salts, initcodes, predicted addresses, the three Gov Safe
///         batches (MultiSendCallOnly-wrapped: batch 1 split into 1a and 1b, one implementation each, audit 2 R1-25)
///         and their EIP-712 Safe transaction hashes. Depends only on the inputs
///         and the compiled bytecode, never on chain state, so every signer reproduces it byte for byte.
library MHDeployPlan {
    /// @notice Index of each deployment in `Plan.deployments` (also the deployment order).
    uint256 internal constant ROTATING_IMPL = 0;
    uint256 internal constant ACCUMULATION_IMPL = 1;
    uint256 internal constant TIMELOCK = 2;
    uint256 internal constant CANCELLER = 3;
    uint256 internal constant REGISTRY = 4;
    uint256 internal constant REPUTATION = 5;
    uint256 internal constant FACTORY = 6;
    uint256 internal constant COUNT = 7;

    /// @notice keccak256 of CreateX's CREATE3 proxy child initcode (`0x67363d3d37363d34f03d5260086018f3`), as
    ///         hard-coded in `CreateX.computeCreate3Address`.
    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice Domain of the allowVault Timelock salt.
    bytes32 internal constant ALLOW_VAULT_SALT_DOMAIN = keccak256("moolahub.circles.allowVault");

    // ================================================================ Salts and addresses

    /// @notice The CreateX guarded salt `GovSafe ‖ 0x01 ‖ 11 bytes` for `label`, and its effective (guarded) value.
    /// @dev The 11 entropy bytes are `bytes11(keccak256(abi.encode(seed, label)))`. With bytes 0..19 == msg.sender
    ///      (the Gov Safe) and byte 20 == 0x01, CreateX `_guard` returns keccak256(abi.encode(msg.sender, chainid,
    ///      salt)): only the Gov Safe can deploy there, and only on this chain.
    /// @param gov The Gov Safe (the CreateX caller).
    /// @param chainId The target chain.
    /// @param seed The salt seed.
    /// @param label The deployment label.
    /// @return salt The salt passed to `deployCreate3`.
    /// @return guarded The salt CreateX actually uses.
    function guardedSalt(address gov, uint256 chainId, bytes32 seed, string memory label)
        internal
        pure
        returns (bytes32 salt, bytes32 guarded)
    {
        bytes11 entropy = bytes11(keccak256(abi.encode(seed, label)));
        salt = bytes32(abi.encodePacked(gov, bytes1(0x01), entropy));
        guarded = keccak256(abi.encode(gov, chainId, salt));
    }

    /// @notice CreateX `computeCreate3Address(guarded, CREATEX)`, reimplemented (cross-checked on chain).
    /// @param guarded The guarded salt.
    /// @return The address the contract will have.
    function create3Address(bytes32 guarded) internal pure returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), BaseChain.CREATEX, guarded, CREATE3_PROXY_INITCODE_HASH
                        )
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    // ================================================================ Plan

    /// @notice Builds the full plan for `cfg` on `chainId`.
    /// @param cfg The validated configuration.
    /// @param chainId The target chain.
    /// @return p The plan (runtime codehashes and gas are filled in later by the simulation).
    function plan(DeployConfig memory cfg, uint256 chainId) internal pure returns (Plan memory p) {
        // Closing review: every check compares owners as a set, but the manifest records them as lists and
        // `inputsHash` hashes those lists. Sorting them here (ascending, in place) makes both canonical, so a signer
        // that gives the same owners in another order rebuilds the same manifest and inputs hash
        // (`MHManifestCheck.policy` requires the recorded lists to be sorted).
        sortAddresses(cfg.gov.owners);
        sortAddresses(cfg.guardian.owners);
        sortAddresses(cfg.treasury.owners);
        p.cfg = cfg;
        p.chainId = chainId;
        p.network = BaseChain.networkOf(chainId);
        p.deployments = new Deployment[](COUNT);

        _slot(p, ROTATING_IMPL, "rotatingImpl", "MHRotatingCircle", 1);
        _slot(p, ACCUMULATION_IMPL, "accumulationImpl", "MHAccumulationCircle", 1);
        _slot(p, TIMELOCK, "timelock", "TimelockController", 2);
        _slot(p, CANCELLER, "canceller", "MHGuardianCanceller", 2);
        _slot(p, REGISTRY, "registry", "MHCircleRegistry", 2);
        _slot(p, REPUTATION, "reputation", "MHReputation", 2);
        _slot(p, FACTORY, "factory", "MHCircleFactory", 2);

        _initCodes(p);
        _batches(p);
        _proposal(p);
    }

    /// @notice Sorts `a` ascending, in place (insertion sort; a Safe has a handful of owners).
    /// @param a The addresses.
    function sortAddresses(address[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            address k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                --j;
            }
            a[j] = k;
        }
    }

    /// @notice The address of deployment `i`.
    /// @param p The plan.
    /// @param i The deployment index.
    /// @return The predicted address.
    function at(Plan memory p, uint256 i) internal pure returns (address) {
        return p.deployments[i].addr;
    }

    function _slot(Plan memory p, uint256 i, string memory key, string memory name, uint256 batch)
        private
        pure
    {
        Deployment memory d = p.deployments[i];
        d.key = key;
        d.contractName = name;
        d.batch = batch;
        (d.salt, d.guardedSalt) = guardedSalt(p.cfg.gov.safe, p.chainId, p.cfg.saltSeed, key);
        d.addr = create3Address(d.guardedSalt);
    }

    function _initCodes(Plan memory p) private pure {
        DeployConfig memory c = p.cfg;
        address registry = at(p, REGISTRY);
        address reputation = at(p, REPUTATION);
        address timelock = at(p, TIMELOCK);

        _code(p, ROTATING_IMPL, type(MHRotatingCircle).creationCode, abi.encode(c.usdc, registry, reputation));
        _code(
            p,
            ACCUMULATION_IMPL,
            type(MHAccumulationCircle).creationCode,
            abi.encode(c.usdc, registry, reputation)
        );

        address[] memory govOnly = new address[](1);
        govOnly[0] = c.gov.safe;
        // proposers = executors = [Gov]; Gov is the temporary admin (renounced as the last call of batch 2).
        _code(
            p,
            TIMELOCK,
            type(TimelockController).creationCode,
            abi.encode(c.timelockDelay, govOnly, govOnly, c.gov.safe)
        );
        _code(
            p,
            CANCELLER,
            type(MHGuardianCanceller).creationCode,
            abi.encode(timelock, registry, c.earnWrapper, c.guardian.safe)
        );
        _code(
            p,
            REGISTRY,
            type(MHCircleRegistry).creationCode,
            abi.encode(timelock, c.usdc, c.operator, c.guardian.safe, c.treasury.safe)
        );
        _code(p, REPUTATION, type(MHReputation).creationCode, abi.encode(timelock, at(p, FACTORY)));
        _code(
            p,
            FACTORY,
            type(MHCircleFactory).creationCode,
            abi.encode(registry, reputation, at(p, ROTATING_IMPL), at(p, ACCUMULATION_IMPL))
        );
    }

    function _code(Plan memory p, uint256 i, bytes memory creationCode, bytes memory args) private pure {
        Deployment memory d = p.deployments[i];
        d.creationCode = creationCode;
        d.constructorArgs = args;
        d.initCode = abi.encodePacked(creationCode, args);
    }

    function _deployCall(Plan memory p, uint256 i) private pure returns (Call memory) {
        Deployment memory d = p.deployments[i];
        return Call({
            to: BaseChain.CREATEX,
            value: 0,
            data: abi.encodeCall(ICreateX.deployCreate3, (d.salt, d.initCode)),
            description: string.concat("CreateX.deployCreate3 ", d.contractName)
        });
    }

    function _batches(Plan memory p) private pure {
        TimelockController tl = TimelockController(payable(at(p, TIMELOCK)));

        // Batch 1 (inert): the circle implementations, one Safe transaction each (audit 2 R1-25: together they no
        // longer fit the 10M batch budget).
        Call[] memory b1a = new Call[](1);
        b1a[0] = _deployCall(p, ROTATING_IMPL);
        Call[] memory b1b = new Call[](1);
        b1b[0] = _deployCall(p, ACCUMULATION_IMPL);

        // Batch 2 (atomic), spec §5 order.
        Call[] memory b2 = new Call[](7);
        b2[0] = _deployCall(p, TIMELOCK);
        b2[1] = _deployCall(p, CANCELLER);
        b2[2] = Call({
            to: address(tl),
            value: 0,
            data: abi.encodeCall(tl.grantRole, (keccak256("CANCELLER_ROLE"), at(p, CANCELLER))),
            description: "Timelock.grantRole(CANCELLER_ROLE, canceller)"
        });
        b2[3] = _deployCall(p, REGISTRY);
        b2[4] = _deployCall(p, REPUTATION);
        b2[5] = _deployCall(p, FACTORY);
        b2[6] = Call({
            to: address(tl),
            value: 0,
            data: abi.encodeCall(tl.renounceRole, (bytes32(0), p.cfg.gov.safe)),
            description: "Timelock.renounceRole(DEFAULT_ADMIN_ROLE, GovSafe)"
        });

        p.batch1a =
            _safeBatch(p, "batch1a", "Moolahub circles batch 1a of 3: rotating implementation", b1a, 0);
        p.batch1b =
            _safeBatch(p, "batch1b", "Moolahub circles batch 1b of 3: accumulation implementation", b1b, 1);
        p.batch2 = _safeBatch(p, "batch2", "Moolahub circles batch 2 of 3: governance and factory", b2, 2);
        p.batch1a.fileName = "batch1a-rotating-implementation.safe.json";
        p.batch1b.fileName = "batch1b-accumulation-implementation.safe.json";
        p.batch2.fileName = "batch2-governance.safe.json";
    }

    function _safeBatch(
        Plan memory p,
        string memory key,
        string memory title,
        Call[] memory calls,
        uint256 nonceOffset
    ) private pure returns (SafeBatch memory b) {
        b.key = key;
        b.title = title;
        b.calls = calls;
        if (calls.length == 1) {
            b.to = calls[0].to;
            b.operation = BaseChain.OP_CALL;
            b.txData = calls[0].data;
        } else {
            b.to = BaseChain.MULTISEND_CALL_ONLY;
            b.operation = BaseChain.OP_DELEGATECALL;
            b.txData = abi.encodeCall(IMultiSendCallOnly.multiSend, (encodeMultiSend(calls)));
        }
        b.nonce = p.cfg.govNonce + nonceOffset;
        (b.domainSeparator, b.messageHash, b.safeTxHash) =
            safeTxHash(p.cfg.gov.safe, p.chainId, b.to, 0, b.txData, b.operation, b.nonce);
    }

    function _proposal(Plan memory p) private pure {
        if (p.cfg.circleVault == address(0)) return;
        p.hasProposal = true;
        Proposal memory a = p.allowVault;
        TimelockController tl = TimelockController(payable(at(p, TIMELOCK)));
        a.target = at(p, REGISTRY);
        a.data = abi.encodeCall(IMHCircleRegistry.allowVault, (p.cfg.circleVault));
        a.predecessor = bytes32(0);
        a.salt = keccak256(abi.encode(ALLOW_VAULT_SALT_DOMAIN, p.cfg.circleVault, p.cfg.saltSeed));
        a.delay = p.cfg.timelockDelay;
        // OZ v5.1.0 `hashOperation`.
        a.operationId = keccak256(abi.encode(a.target, uint256(0), a.data, a.predecessor, a.salt));
        a.schedule = Call({
            to: address(tl),
            value: 0,
            data: abi.encodeCall(tl.schedule, (a.target, 0, a.data, a.predecessor, a.salt, a.delay)),
            description: "Timelock.schedule(registry.allowVault(circleVault))"
        });
        a.execute = Call({
            to: address(tl),
            value: 0,
            data: abi.encodeCall(tl.execute, (a.target, 0, a.data, a.predecessor, a.salt)),
            description: "Timelock.execute(registry.allowVault(circleVault))"
        });
        a.scheduleTx = _plainTx(p, a.schedule, 3);
        a.executeTx = _plainTx(p, a.execute, 4);
    }

    /// @dev The Gov Safe transaction for one call sent directly (operation 0, CALL) at `govNonce + nonceOffset`.
    function _plainTx(Plan memory p, Call memory c, uint256 nonceOffset)
        private
        pure
        returns (SafeTxRef memory r)
    {
        r.nonce = p.cfg.govNonce + nonceOffset;
        (, r.messageHash, r.safeTxHash) =
            safeTxHash(p.cfg.gov.safe, p.chainId, c.to, c.value, c.data, BaseChain.OP_CALL, r.nonce);
    }

    /// @notice Audit R2-03: one hash over every ceremony input (chain, USDC, the three Safes with owners and
    ///         thresholds, operator, circle vault, Earn wrapper, delay, fee policy, salt seed, nonce, commit), printed
    ///         by `CheckManifest` and recorded in the manifest so signers can compare all inputs out of band at once.
    /// @param p The plan.
    /// @return The inputs hash.
    function inputsHash(Plan memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.chainId, p.cfg));
    }

    // ================================================================ Safe encoding

    /// @notice MultiSendCallOnly payload: for each call, abi.encodePacked(uint8(0), to, value, data.length, data).
    /// @param calls The calls (all CALL; MultiSendCallOnly reverts on a delegatecall entry).
    /// @return packed The `transactions` argument of `multiSend`.
    function encodeMultiSend(Call[] memory calls) internal pure returns (bytes memory packed) {
        for (uint256 i; i < calls.length; ++i) {
            packed = abi.encodePacked(
                packed, BaseChain.OP_CALL, calls[i].to, calls[i].value, calls[i].data.length, calls[i].data
            );
        }
    }

    /// @notice Safe v1.4.1 EIP-712 hashes with safeTxGas = baseGas = gasPrice = 0 and no gas token or refund
    ///         receiver: the domain hash, the SafeTx struct ("message") hash and the safeTxHash signers approve.
    ///         These are the three values `safe-tx-hashes-util` prints and the hardware wallet shows.
    /// @param safe The Safe.
    /// @param chainId The chain.
    /// @param to The Safe transaction's target.
    /// @param value The ETH value.
    /// @param data The calldata.
    /// @param operation 0 = CALL, 1 = DELEGATECALL.
    /// @param nonce The Safe nonce.
    /// @return domain The domain separator.
    /// @return message The SafeTx struct hash.
    /// @return txHash The safeTxHash.
    function safeTxHash(
        address safe,
        uint256 chainId,
        address to,
        uint256 value,
        bytes memory data,
        uint8 operation,
        uint256 nonce
    ) internal pure returns (bytes32 domain, bytes32 message, bytes32 txHash) {
        domain = keccak256(abi.encode(BaseChain.SAFE_DOMAIN_TYPEHASH, chainId, safe));
        message = keccak256(
            abi.encode(
                BaseChain.SAFE_TX_TYPEHASH,
                to,
                value,
                keccak256(data),
                operation,
                uint256(0),
                uint256(0),
                uint256(0),
                address(0),
                address(0),
                nonce
            )
        );
        txHash = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, message));
    }
}
