// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import {
    RotatingConfig,
    RotatingParams,
    AccumulationConfig,
    AccumulationParams
} from "../../src/circles/MHCircleTypes.sol";

import { MockUSDC } from "../mocks/MockUSDC.sol";
import { MockVaultV2 } from "../mocks/MockVaultV2.sol";
import { MockRotatingCircle, MockAccumulationCircle } from "../mocks/MockCircles.sol";

/// @notice Deploys the governance stack in the spec §5 order and wiring:
///         batch 1 = both (mock) implementations; batch 2 = Timelock (Gov temporary admin) → canceller →
///         grantRole(CANCELLER_ROLE, canceller) → Registry → Reputation (predicted factory) → Factory →
///         renounceRole(DEFAULT_ADMIN_ROLE, Gov). Addresses that are needed before they exist are predicted from
///         this contract's CREATE nonce, standing in for CreateX `deployCreate3`.
abstract contract CircleFixture is Test {
    uint256 internal constant DELAY = 48 hours;

    address internal gov = makeAddr("govSafe");
    address internal guardian = makeAddr("guardianSafe");
    address internal treasury = makeAddr("treasurySafe");
    address internal operator = makeAddr("operator");
    address internal attacker = makeAddr("attacker");

    MockUSDC internal usdc;
    TimelockController internal timelock;
    MockVaultV2 internal wrapper;
    address internal rotatingImpl;
    address internal accumulationImpl;
    MockRotatingCircle internal rotImpl;
    MockAccumulationCircle internal accImpl;
    MHGuardianCanceller internal canceller;
    MHCircleRegistry internal registry;
    MHReputation internal reputation;
    MHCircleFactory internal factory;

    uint256 private _saltNonce;

    function setUp() public virtual {
        uint256 n = vm.getNonce(address(this));
        address pRegistry = vm.computeCreateAddress(address(this), n + 6);
        address pReputation = vm.computeCreateAddress(address(this), n + 7);
        address pFactory = vm.computeCreateAddress(address(this), n + 8);

        usdc = new MockUSDC(); // n
        address[] memory govList = new address[](1);
        govList[0] = gov;
        timelock = new TimelockController(DELAY, govList, govList, gov); // n+1, Gov temporary admin
        wrapper = new MockVaultV2(address(usdc), address(timelock)); // n+2, Timelock-owned Earn wrapper
        // Batch 1: inert implementations (exactly one CREATE each, see the hooks below).
        rotatingImpl = _deployRotatingImpl(IMHCircleRegistry(pRegistry), IMHReputation(pReputation)); // n+3
        accumulationImpl = _deployAccumulationImpl(IMHCircleRegistry(pRegistry), IMHReputation(pReputation)); // n+4
        // Typed handles for the mock-based suites; meaningless when a hook deploys a real implementation.
        rotImpl = MockRotatingCircle(rotatingImpl);
        accImpl = MockAccumulationCircle(accumulationImpl);
        // Batch 2.
        canceller = new MHGuardianCanceller(address(timelock), pRegistry, address(wrapper), guardian); // n+5
        vm.startPrank(gov);
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(canceller));
        vm.stopPrank();
        registry = new MHCircleRegistry(address(timelock), IUSDC(address(usdc)), operator, guardian, treasury); // n+6
        reputation = new MHReputation(address(timelock), pFactory); // n+7
        factory = new MHCircleFactory(registry, reputation, rotatingImpl, accumulationImpl); // n+8
        vm.startPrank(gov);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), gov);
        vm.stopPrank();

        assertEq(address(registry), pRegistry, "registry prediction");
        assertEq(address(reputation), pReputation, "reputation prediction");
        assertEq(address(factory), pFactory, "factory prediction");
    }

    // ---------------------------------------------------------------- Implementation hooks

    /// @dev Deploys the rotating implementation with exactly one CREATE. Default: the test-only mock.
    function _deployRotatingImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        virtual
        returns (address)
    {
        return address(new MockRotatingCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    /// @dev Deploys the accumulation implementation with exactly one CREATE. Default: the test-only mock.
    function _deployAccumulationImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        virtual
        returns (address)
    {
        return address(new MockAccumulationCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    // ---------------------------------------------------------------- Governance helpers

    function _nextSalt() internal returns (bytes32) {
        return bytes32(++_saltNonce);
    }

    /// @dev Gov schedules a single call, waits the delay, executes.
    function _govExec(address target, bytes memory data) internal {
        bytes32 salt = _govScheduleAndWait(target, data);
        _govExecute(target, data, salt);
    }

    /// @dev Gov schedules a single call and the delay elapses; execute with `_govExecute`.
    function _govScheduleAndWait(address target, bytes memory data) internal returns (bytes32 salt) {
        salt = _nextSalt();
        vm.prank(gov);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
    }

    function _govExecute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(gov);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _schedule(address target, uint256 value, bytes memory data, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        vm.prank(gov);
        timelock.schedule(target, value, data, bytes32(0), salt, DELAY);
        id = timelock.hashOperation(target, value, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id), "scheduled");
    }

    function _scheduleBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    ) internal returns (bytes32 id) {
        vm.prank(gov);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id), "scheduled");
    }

    // ---------------------------------------------------------------- Circle params

    function _members(uint256 n, uint256 seed) internal pure returns (address[] memory m) {
        m = new address[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = address(uint160(uint256(keccak256(abi.encode("member", seed, i)))));
        }
    }

    function _rotParams(bytes32 circleId, uint256 n) internal view returns (RotatingParams memory p) {
        p.config = RotatingConfig({
            circleId: circleId,
            contribution: 100e6,
            feeBps: 0,
            roundDuration: 30 days,
            grace: 48 hours,
            cure: 72 hours,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            // forge-lint: disable-next-line(unsafe-typecast)
            totalRounds: uint32(n) // n <= 50 in every caller
        });
        p.members = _members(n, uint256(circleId));
        p.securityBps = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            p.securityBps[i] = 10_000;
        }
    }

    function _accParams(bytes32 circleId, uint256 n) internal view returns (AccumulationParams memory p) {
        p.config = AccumulationConfig({
            circleId: circleId,
            contribution: 100e6,
            feeBps: 0,
            roundDuration: 30 days,
            grace: 48 hours,
            cure: 72 hours,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            totalRounds: 12,
            vault: address(0),
            lockUntilMaturity: false
        });
        p.members = _members(n, uint256(circleId));
    }
}
