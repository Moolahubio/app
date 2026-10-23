// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { BuildBaseBatch } from "../../script/BuildBaseBatch.s.sol";
import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import { ICreateX, IMultiSendCallOnly } from "../../script/ceremony/DeployInterfaces.sol";
import {
    MHDeployPlan,
    DeployConfig,
    SafeSpec,
    Plan,
    Call,
    Deployment
} from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";

import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";

/// @dev Exposes the libraries' internal functions so `expectRevert` can observe their reverts.
contract DeployPlanHarness {
    /// @notice `MHDeployJson.txBuilderFile`, external.
    function txBuilderFile(
        uint256 chainId,
        address safe,
        string memory name,
        string memory description,
        Call[] memory c
    ) external pure returns (string memory) {
        return MHDeployJson.txBuilderFile(chainId, safe, name, description, c);
    }
}

/// @notice Offline unit tests of the ceremony planner and JSON writer (no fork, so they run in every CI job):
///         salt layout, CREATE3 formula, initcode wiring, batch contents and order, MultiSend packing, Safe
///         EIP-712 hashing, the Transaction Builder checksum against an independent reference, determinism, and
///         the gas formula. The fork suite (`test/fork/SafeDeployRehearsal.t.sol`) checks the same plan against
///         the real CreateX, Safe, Timelock and Morpho contracts.
contract MHDeployPlanTest is Test {
    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");
    address internal vault = makeAddr("vault");

    function _cfg() internal view returns (DeployConfig memory c) {
        c.usdc = BaseChain.USDC_BASE;
        c.gov = SafeSpec({ safe: gov, owners: new address[](0), threshold: 3 });
        c.guardian = SafeSpec({ safe: guardian, owners: new address[](0), threshold: 2 });
        c.treasury = SafeSpec({ safe: treasury, owners: new address[](0), threshold: 2 });
        c.operator = operator;
        c.circleVault = vault;
        c.earnWrapper = address(0);
        c.timelockDelay = 48 hours;
        c.saltSeed = keccak256("seed");
        c.govNonce = 5;
        c.commit = "0123456789abcdef0123456789abcdef01234567";
    }

    // ================================================================ Salts and addresses

    function test_guardedSalt_layout() public view {
        (bytes32 salt, bytes32 guarded) = MHDeployPlan.guardedSalt(gov, 8453, keccak256("seed"), "registry");
        // Exact byte slices of the 32-byte salt (no truncation of a value):
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(address(bytes20(salt)), gov, "bytes 0..19 = Gov Safe (permissioned deploy)");
        assertEq(uint8(salt[20]), 1, "byte 20 = 0x01 (cross-chain redeploy protection)");
        bytes32 tail = salt << 168;
        bytes32 entropy = keccak256(abi.encode(keccak256("seed"), "registry"));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes11(tail), bytes11(entropy), "bytes 21..31 = 11 entropy bytes");
        // CreateX `_guard` for MsgSender + True: keccak256(abi.encode(msg.sender, block.chainid, salt)).
        assertEq(guarded, keccak256(abi.encode(gov, uint256(8453), salt)));
        // Chain-bound: the same salt guards to a different value on Sepolia.
        (, bytes32 sepolia) = MHDeployPlan.guardedSalt(gov, 84532, keccak256("seed"), "registry");
        assertTrue(sepolia != guarded);
    }

    /// @dev The local CREATE3 formula reproduces a known CreateX vector: Solady's CREATE3 with deployer CreateX.
    function test_create3Address_formula() public pure {
        bytes32 guarded = keccak256("any guarded salt");
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
        // The deployed contract is the proxy's first CREATE (nonce 1).
        assertEq(MHDeployPlan.create3Address(guarded), vm.computeCreateAddress(proxy, 1));
        assertEq(MHDeployPlan.CREATE3_PROXY_INITCODE_HASH, keccak256(hex"67363d3d37363d34f03d5260086018f3"));
    }

    // ================================================================ Plan contents

    function test_plan_wiring() public view {
        DeployConfig memory c = _cfg();
        Plan memory p = MHDeployPlan.plan(c, 8453);
        address tl = MHDeployPlan.at(p, MHDeployPlan.TIMELOCK);
        address registry = MHDeployPlan.at(p, MHDeployPlan.REGISTRY);
        address reputation = MHDeployPlan.at(p, MHDeployPlan.REPUTATION);
        address factory = MHDeployPlan.at(p, MHDeployPlan.FACTORY);
        address rot = MHDeployPlan.at(p, MHDeployPlan.ROTATING_IMPL);
        address acc = MHDeployPlan.at(p, MHDeployPlan.ACCUMULATION_IMPL);

        assertEq(p.network, "base-mainnet");
        assertEq(p.deployments.length, 7);
        // Constructor arguments use the final (predicted) addresses: no post-deploy wiring is needed.
        assertEq(
            p.deployments[MHDeployPlan.ROTATING_IMPL].constructorArgs,
            abi.encode(c.usdc, registry, reputation)
        );
        assertEq(
            p.deployments[MHDeployPlan.ACCUMULATION_IMPL].constructorArgs,
            abi.encode(c.usdc, registry, reputation)
        );
        address[] memory govOnly = new address[](1);
        govOnly[0] = gov;
        assertEq(
            p.deployments[MHDeployPlan.TIMELOCK].constructorArgs, abi.encode(48 hours, govOnly, govOnly, gov)
        );
        assertEq(
            p.deployments[MHDeployPlan.CANCELLER].constructorArgs,
            abi.encode(tl, registry, address(0), guardian)
        );
        assertEq(
            p.deployments[MHDeployPlan.REGISTRY].constructorArgs,
            abi.encode(tl, c.usdc, operator, guardian, treasury)
        );
        assertEq(p.deployments[MHDeployPlan.REPUTATION].constructorArgs, abi.encode(tl, factory));
        assertEq(
            p.deployments[MHDeployPlan.FACTORY].constructorArgs, abi.encode(registry, reputation, rot, acc)
        );
        // Initcode = creation code ‖ args, and the creation code is the compiled artifact.
        for (uint256 i; i < 7; ++i) {
            Deployment memory d = p.deployments[i];
            assertEq(d.initCode, abi.encodePacked(d.creationCode, d.constructorArgs));
            assertLe(d.initCode.length, 49_152, "EIP-3860");
            assertEq(d.addr, MHDeployPlan.create3Address(d.guardedSalt));
            for (uint256 j; j < i; ++j) {
                assertTrue(p.deployments[j].addr != d.addr, "distinct addresses");
            }
        }
        assertEq(p.deployments[MHDeployPlan.ROTATING_IMPL].creationCode, type(MHRotatingCircle).creationCode);
        assertEq(p.deployments[MHDeployPlan.FACTORY].creationCode, type(MHCircleFactory).creationCode);
    }

    /// @dev Batches 1a and 1b = one implementation each (audit 2 R1-25); batch 2 = the spec §5 seven steps in order;
    ///      nonces follow.
    function test_plan_batches() public view {
        Plan memory p = MHDeployPlan.plan(_cfg(), 8453);
        TimelockController tl = TimelockController(payable(MHDeployPlan.at(p, MHDeployPlan.TIMELOCK)));

        assertEq(p.batch1a.calls.length, 1);
        assertEq(p.batch1a.nonce, 5);
        _assertDeploy(p, p.batch1a.calls[0], MHDeployPlan.ROTATING_IMPL);
        assertEq(p.batch1b.calls.length, 1);
        assertEq(p.batch1b.nonce, 6);
        _assertDeploy(p, p.batch1b.calls[0], MHDeployPlan.ACCUMULATION_IMPL);

        assertEq(p.batch2.calls.length, 7);
        assertEq(p.batch2.nonce, 7);
        _assertDeploy(p, p.batch2.calls[0], MHDeployPlan.TIMELOCK);
        _assertDeploy(p, p.batch2.calls[1], MHDeployPlan.CANCELLER);
        assertEq(p.batch2.calls[2].to, address(tl));
        assertEq(
            p.batch2.calls[2].data,
            abi.encodeCall(
                IAccessControl.grantRole,
                (keccak256("CANCELLER_ROLE"), MHDeployPlan.at(p, MHDeployPlan.CANCELLER))
            )
        );
        _assertDeploy(p, p.batch2.calls[3], MHDeployPlan.REGISTRY);
        _assertDeploy(p, p.batch2.calls[4], MHDeployPlan.REPUTATION);
        _assertDeploy(p, p.batch2.calls[5], MHDeployPlan.FACTORY);
        assertEq(p.batch2.calls[6].to, address(tl));
        assertEq(p.batch2.calls[6].data, abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), gov)));
        for (uint256 i; i < 7; ++i) {
            assertEq(p.batch2.calls[i].value, 0);
        }
        // The Gov Safe signs one DELEGATECALL to MultiSendCallOnly for batch 2, and a plain CALL to CreateX for each
        // one-call batch (how Safe{Wallet} sends a one-transaction batch).
        assertEq(p.batch2.to, BaseChain.MULTISEND_CALL_ONLY);
        assertEq(p.batch2.operation, 1);
        assertEq(
            p.batch2.txData,
            abi.encodeCall(IMultiSendCallOnly.multiSend, (MHDeployPlan.encodeMultiSend(p.batch2.calls)))
        );
        assertEq(p.batch1a.to, BaseChain.CREATEX);
        assertEq(p.batch1a.operation, 0);
        assertEq(p.batch1a.txData, p.batch1a.calls[0].data);
        (,, bytes32 h) =
            MHDeployPlan.safeTxHash(gov, 8453, BaseChain.CREATEX, 0, p.batch1b.calls[0].data, 0, 6);
        assertEq(p.batch1b.safeTxHash, h);
        // The allowVault proposal transactions follow the three batches.
        assertEq(p.allowVault.scheduleTx.nonce, 8);
        assertEq(p.allowVault.executeTx.nonce, 9);
    }

    function test_plan_allowVaultProposal() public view {
        Plan memory p = MHDeployPlan.plan(_cfg(), 8453);
        assertTrue(p.hasProposal);
        address registry = MHDeployPlan.at(p, MHDeployPlan.REGISTRY);
        bytes memory data = abi.encodeCall(IMHCircleRegistry.allowVault, (vault));
        assertEq(p.allowVault.target, registry);
        assertEq(p.allowVault.data, data);
        assertEq(p.allowVault.delay, 48 hours);
        assertEq(
            p.allowVault.operationId, keccak256(abi.encode(registry, 0, data, bytes32(0), p.allowVault.salt))
        );
        assertEq(p.allowVault.schedule.to, MHDeployPlan.at(p, MHDeployPlan.TIMELOCK));
        assertEq(
            p.allowVault.schedule.data,
            abi.encodeCall(TimelockController.schedule, (registry, 0, data, 0, p.allowVault.salt, 48 hours))
        );
        assertEq(
            p.allowVault.execute.data,
            abi.encodeCall(TimelockController.execute, (registry, 0, data, 0, p.allowVault.salt))
        );
        DeployConfig memory c = _cfg();
        c.circleVault = address(0);
        assertFalse(MHDeployPlan.plan(c, 8453).hasProposal, "no vault, no proposal");
    }

    function test_plan_deterministicAndSeedSensitive() public {
        DeployConfig memory c = _cfg();
        Plan memory a = MHDeployPlan.plan(c, 8453);
        Plan memory b = MHDeployPlan.plan(c, 8453);
        assertEq(keccak256(abi.encode(a.deployments)), keccak256(abi.encode(b.deployments)));
        assertEq(a.batch2.safeTxHash, b.batch2.safeTxHash);
        c.saltSeed = keccak256("other seed");
        Plan memory d = MHDeployPlan.plan(c, 8453);
        for (uint256 i; i < 7; ++i) {
            assertTrue(a.deployments[i].addr != d.deployments[i].addr, "new seed, new addresses");
        }
        // Another Gov Safe gets other addresses even with the same seed (salts are sender-bound).
        c = _cfg();
        c.gov.safe = makeAddr("otherGov");
        assertTrue(MHDeployPlan.plan(c, 8453).deployments[0].addr != a.deployments[0].addr);
    }

    // ================================================================ Encoding and hashing

    function test_encodeMultiSend_packing() public pure {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({ to: address(0xAAAA), value: 0, data: hex"deadbeef", description: "" });
        calls[1] = Call({ to: address(0xBBBB), value: 7, data: "", description: "" });
        bytes memory expected = bytes.concat(
            hex"00",
            bytes20(address(0xAAAA)),
            bytes32(uint256(0)),
            bytes32(uint256(4)),
            hex"deadbeef",
            hex"00",
            bytes20(address(0xBBBB)),
            bytes32(uint256(7)),
            bytes32(uint256(0))
        );
        assertEq(MHDeployPlan.encodeMultiSend(calls), expected);
    }

    /// @dev Safe v1.4.1 EIP-712: domain(chainId, safe) and SafeTx with zero gas fields (independently encoded).
    function test_safeTxHash_eip712() public pure {
        address safe = address(0x5afe);
        bytes memory data = hex"8d80ff0a";
        (bytes32 domain, bytes32 message, bytes32 h) =
            MHDeployPlan.safeTxHash(safe, 8453, BaseChain.MULTISEND_CALL_ONLY, 0, data, 1, 9);
        assertEq(
            domain,
            keccak256(
                abi.encode(keccak256("EIP712Domain(uint256 chainId,address verifyingContract)"), 8453, safe)
            )
        );
        bytes32 typehash = keccak256(
            "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
        );
        assertEq(typehash, BaseChain.SAFE_TX_TYPEHASH);
        assertEq(
            message,
            keccak256(
                abi.encode(
                    typehash,
                    BaseChain.MULTISEND_CALL_ONLY,
                    0,
                    keccak256(data),
                    1,
                    0,
                    0,
                    0,
                    address(0),
                    address(0),
                    9
                )
            )
        );
        assertEq(h, keccak256(abi.encodePacked(hex"1901", domain, message)));
    }

    /// @dev Reference vector computed with an independent Python port of safe-react-apps
    ///      `apps/tx-builder/src/lib/checksum.ts` (`serializeJSONObject` + keccak256), which itself reproduces the
    ///      official `checksum.test.js` vector 0x4ecbfd36…db64c.
    function test_txBuilderFile_checksumMatchesReference() public pure {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({ to: BaseChain.CREATEX, value: 0, data: hex"deadbeef", description: "" });
        calls[1] = Call({ to: BaseChain.MULTISEND_CALL_ONLY, value: 1, data: hex"00", description: "" });
        string memory json = MHDeployJson.txBuilderFile(
            8453, address(0x5afe), "Moolahub test batch", "Gov Safe nonce 0. Plain ASCII description.", calls
        );
        assertEq(
            vm.parseJsonBytes32(json, ".meta.checksum"),
            0x3c78742d8bfbdcc7a2995dd77134b27b79e381ae5c06c619e2084e41121b047d,
            "tx-builder checksum"
        );
        assertEq(vm.parseJsonString(json, ".chainId"), "8453");
        assertEq(vm.parseJsonString(json, ".transactions[1].value"), "1");
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), BaseChain.CREATEX);
    }

    function test_txBuilderFile_rejectsUnsafeStrings() public {
        DeployPlanHarness h = new DeployPlanHarness();
        Call[] memory calls = new Call[](0);
        vm.expectRevert(abi.encodeWithSelector(MHDeployJson.JsonUnsafeString.selector, "a\"b"));
        h.txBuilderFile(8453, address(1), "a\"b", "", calls);
        vm.expectRevert(abi.encodeWithSelector(MHDeployJson.JsonUnsafeString.selector, "back\\slash"));
        h.txBuilderFile(8453, address(1), "ok", "back\\slash", calls);
        vm.expectRevert(abi.encodeWithSelector(MHDeployJson.JsonUnsafeString.selector, "line\nbreak"));
        h.txBuilderFile(8453, address(1), "line\nbreak", "", calls);
    }

    /// @dev max(21,000 + 4·zero + 16·nonzero + execution, 21,000 + 10·(zero + 4·nonzero)) (EIP-2028, EIP-7623).
    function test_txGas_formula() public {
        BuildBaseBatch b = new BuildBaseBatch();
        assertEq(b.txGas(100_000, hex"00ff00ff"), 21_000 + 2 * 4 + 2 * 16 + 100_000);
        // Calldata-heavy, execution-light: the floor applies.
        assertEq(b.txGas(0, hex"ffffffff"), 21_000 + 10 * 16);
    }

    function _assertDeploy(Plan memory p, Call memory c, uint256 i) internal pure {
        assertEq(c.to, BaseChain.CREATEX);
        assertEq(c.value, 0);
        assertEq(
            c.data, abi.encodeCall(ICreateX.deployCreate3, (p.deployments[i].salt, p.deployments[i].initCode))
        );
    }
}
