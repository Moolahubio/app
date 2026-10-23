// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHCircleTerms } from "../../src/circles/MHCircleTerms.sol";
import { IMHCircleFactory } from "../../src/circles/interfaces/IMHCircleFactory.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { CircleMode, RotatingParams, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

import { MockUSDC } from "../mocks/MockUSDC.sol";
import { MockRotatingCircle, MockAccumulationCircle, MockCircleCore } from "../mocks/MockCircles.sol";

contract MHCircleFactoryTest is CircleFixture {
    bytes32 internal constant ID = keccak256("circle-1");

    // ---------------------------------------------------------------- Construction and wiring

    function test_constructor_wiring() public view {
        assertEq(address(factory.REGISTRY()), address(registry));
        assertEq(address(factory.REPUTATION()), address(reputation));
        assertEq(factory.ROTATING_IMPL(), address(rotImpl));
        assertEq(factory.ACCUMULATION_IMPL(), address(accImpl));
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(IMHCircleFactory.ZeroAddress.selector);
        new MHCircleFactory(IMHCircleRegistry(address(0)), reputation, address(rotImpl), address(accImpl));
        vm.expectRevert(IMHCircleFactory.ZeroAddress.selector);
        new MHCircleFactory(registry, IMHReputation(address(0)), address(rotImpl), address(accImpl));
        vm.expectRevert(IMHCircleFactory.ZeroAddress.selector);
        new MHCircleFactory(registry, reputation, address(0), address(accImpl));
        vm.expectRevert(IMHCircleFactory.ZeroAddress.selector);
        new MHCircleFactory(registry, reputation, address(rotImpl), address(0));
    }

    function test_constructor_revertsWhenReputationAuthorizesAnotherFactory() public {
        // `reputation.FACTORY()` is the fixture factory, not this new one.
        vm.expectRevert(IMHCircleFactory.WiringMismatch.selector);
        new MHCircleFactory(registry, reputation, address(rotImpl), address(accImpl));
    }

    function test_constructor_freshStackWiresUp() public {
        (MHReputation rep, address r, address a) = _stack(Variant.Ok);
        MHCircleFactory f = new MHCircleFactory(registry, rep, r, a);
        assertEq(rep.FACTORY(), address(f));
    }

    function test_constructor_revertsOnSwappedModes() public {
        (MHReputation rep, address r, address a) = _stack(Variant.Swapped);
        vm.expectRevert(IMHCircleFactory.WiringMismatch.selector);
        new MHCircleFactory(registry, rep, r, a);
    }

    function test_constructor_revertsOnForeignRegistry() public {
        (MHReputation rep, address r, address a) = _stack(Variant.ForeignRegistry);
        vm.expectRevert(IMHCircleFactory.WiringMismatch.selector);
        new MHCircleFactory(registry, rep, r, a);
    }

    function test_constructor_revertsOnForeignReputation() public {
        (MHReputation rep, address r, address a) = _stack(Variant.ForeignReputation);
        vm.expectRevert(IMHCircleFactory.WiringMismatch.selector);
        new MHCircleFactory(registry, rep, r, a);
    }

    function test_constructor_revertsOnForeignUsdc() public {
        (MHReputation rep, address r, address a) = _stack(Variant.ForeignUsdc);
        vm.expectRevert(IMHCircleFactory.WiringMismatch.selector);
        new MHCircleFactory(registry, rep, r, a);
    }

    // ---------------------------------------------------------------- createRotating / createAccumulation

    function test_createRotating_fullSequence() public {
        RotatingParams memory p = _rotParams(ID, 5);
        address predicted = factory.predictAddress(ID, CircleMode.Rotating);
        bytes32 expectedTerms =
            MHCircleTerms.rotating(block.chainid, predicted, p.config, p.members, p.securityBps);

        vm.expectEmit(true, false, false, false, address(reputation));
        emit IMHReputation.ReporterSet(predicted);
        vm.expectEmit(true, true, true, true, address(factory));
        emit IMHCircleFactory.CircleCreated(ID, predicted, CircleMode.Rotating, expectedTerms, operator);
        vm.prank(operator);
        address circle = factory.createRotating(p);

        assertEq(circle, predicted, "deterministic address");
        assertTrue(factory.isCircle(circle));
        assertEq(factory.circleOf(ID), circle);
        assertTrue(reputation.isReporter(circle));
        MockRotatingCircle c = MockRotatingCircle(circle);
        assertEq(c.circleId(), ID);
        assertEq(c.memberCount(), 5);
        assertEq(c.termsHash(), expectedTerms);
        assertEq(c.initCaller(), address(factory), "initialized by the factory");
        assertEq(uint8(c.circleMode()), uint8(CircleMode.Rotating));
        // Clones share the implementation's immutables.
        assertEq(address(c.USDC()), address(usdc));
        assertEq(address(c.REGISTRY()), address(registry));
        assertEq(address(c.REPUTATION()), address(reputation));
    }

    function test_createAccumulation_fullSequence() public {
        AccumulationParams memory p = _accParams(ID, 4);
        address predicted = factory.predictAddress(ID, CircleMode.Accumulation);
        bytes32 expectedTerms = MHCircleTerms.accumulation(block.chainid, predicted, p.config, p.members);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IMHCircleFactory.CircleCreated(ID, predicted, CircleMode.Accumulation, expectedTerms, operator);
        vm.prank(operator);
        address circle = factory.createAccumulation(p);

        assertEq(circle, predicted);
        assertTrue(factory.isCircle(circle));
        assertTrue(reputation.isReporter(circle));
        assertEq(MockAccumulationCircle(circle).termsHash(), expectedTerms);
        assertEq(uint8(MockAccumulationCircle(circle).circleMode()), uint8(CircleMode.Accumulation));
    }

    /// @dev Spec order: clone → setReporter → initialize → isCircle → CircleCreated.
    function test_order_reporterBeforeInitialize_isCircleAfter() public {
        vm.prank(operator);
        address circle = factory.createRotating(_rotParams(ID, 3));
        assertTrue(MockRotatingCircle(circle).reporterAtInit(), "reporter registered before initialize");
        assertFalse(MockRotatingCircle(circle).isCircleAtInit(), "isCircle set only after initialize");
        assertTrue(factory.isCircle(circle));
    }

    // ---------------------------------------------------------------- Determinism

    /// @dev Independent recomputation: CREATE2(factory, keccak256(abi.encode(circleId)), EIP-1167 initcode).
    function testFuzz_predictAddress_matchesCreate2Formula(bytes32 circleId) public view {
        bytes32 salt = keccak256(abi.encode(circleId));
        assertEq(
            factory.predictAddress(circleId, CircleMode.Rotating),
            vm.computeCreate2Address(salt, keccak256(_cloneInitcode(address(rotImpl))), address(factory))
        );
        assertEq(
            factory.predictAddress(circleId, CircleMode.Accumulation),
            vm.computeCreate2Address(salt, keccak256(_cloneInitcode(address(accImpl))), address(factory))
        );
    }

    function testFuzz_createdAddressEqualsPrediction(bytes32 circleId, uint8 nRaw, bool rotating) public {
        vm.assume(circleId != MockCircleCore(address(rotImpl)).REVERT_ID());
        uint256 n = bound(nRaw, 2, 50);
        vm.startPrank(operator);
        address circle = rotating
            ? factory.createRotating(_rotParams(circleId, n))
            : factory.createAccumulation(_accParams(circleId, n));
        vm.stopPrank();
        CircleMode mode = rotating ? CircleMode.Rotating : CircleMode.Accumulation;
        assertEq(circle, factory.predictAddress(circleId, mode));
        assertTrue(factory.isCircle(circle));
    }

    function test_predictAddress_dependsOnlyOnIdAndMode() public {
        address a = factory.predictAddress(ID, CircleMode.Rotating);
        address b = factory.predictAddress(ID, CircleMode.Accumulation);
        assertTrue(a != b);
        assertTrue(a != factory.predictAddress(keccak256("circle-2"), CircleMode.Rotating));
        // Different terms, same id → same address.
        RotatingParams memory p = _rotParams(ID, 7);
        p.config.contribution = 55e6;
        vm.prank(operator);
        assertEq(factory.createRotating(p), a);
    }

    // ---------------------------------------------------------------- Access control

    function test_create_onlyOperator() public {
        address[5] memory callers = [attacker, guardian, gov, address(timelock), treasury];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(IMHCircleFactory.NotOperator.selector);
            factory.createRotating(_rotParams(ID, 3));
            vm.expectRevert(IMHCircleFactory.NotOperator.selector);
            factory.createAccumulation(_accParams(ID, 3));
            vm.stopPrank();
        }
    }

    function testFuzz_create_onlyOperator(address caller) public {
        vm.assume(caller != operator);
        vm.startPrank(caller);
        vm.expectRevert(IMHCircleFactory.NotOperator.selector);
        factory.createRotating(_rotParams(ID, 3));
        vm.stopPrank();
    }

    function test_operatorRotation_takesEffect() public {
        address op2 = makeAddr("operator2");
        _govExec(address(registry), abi.encodeCall(IMHCircleRegistry.setOperator, (op2)));
        vm.prank(operator);
        vm.expectRevert(IMHCircleFactory.NotOperator.selector);
        factory.createRotating(_rotParams(ID, 3));
        vm.prank(op2);
        address circle = factory.createRotating(_rotParams(ID, 3));
        assertTrue(factory.isCircle(circle));
    }

    // ---------------------------------------------------------------- Pause

    function test_create_blockedWhilePaused_thenUnpaused() public {
        vm.prank(guardian);
        registry.pauseCreation();

        vm.startPrank(operator);
        vm.expectRevert(IMHCircleFactory.CreationPaused.selector);
        factory.createRotating(_rotParams(ID, 3));
        vm.expectRevert(IMHCircleFactory.CreationPaused.selector);
        factory.createAccumulation(_accParams(ID, 3));
        vm.stopPrank();
        assertEq(factory.predictAddress(ID, CircleMode.Rotating).code.length, 0);

        _govExec(address(registry), abi.encodeCall(IMHCircleRegistry.unpauseCreation, ()));
        vm.prank(operator);
        address circle = factory.createRotating(_rotParams(ID, 3));
        assertTrue(factory.isCircle(circle));
    }

    function test_pauseDoesNotAffectExistingCircles() public {
        vm.prank(operator);
        address circle = factory.createRotating(_rotParams(ID, 3));
        vm.prank(guardian);
        registry.pauseCreation();
        assertTrue(factory.isCircle(circle));
        assertTrue(reputation.isReporter(circle));
    }

    // ---------------------------------------------------------------- Uniqueness and atomicity

    function test_create_sameIdTwice_reverts() public {
        vm.startPrank(operator);
        factory.createRotating(_rotParams(ID, 3));
        vm.expectRevert(IMHCircleFactory.CircleIdUsed.selector);
        factory.createRotating(_rotParams(ID, 3));
        vm.expectRevert(IMHCircleFactory.CircleIdUsed.selector);
        factory.createAccumulation(_accParams(ID, 3));
        vm.stopPrank();
    }

    function test_create_failedInitializeRollsBackEverything() public {
        bytes32 bad = MockCircleCore(address(rotImpl)).REVERT_ID();
        address predicted = factory.predictAddress(bad, CircleMode.Rotating);
        vm.prank(operator);
        vm.expectRevert(IMHCircle.BadConfig.selector);
        factory.createRotating(_rotParams(bad, 3));
        assertEq(predicted.code.length, 0, "no clone left behind");
        assertFalse(factory.isCircle(predicted));
        assertFalse(reputation.isReporter(predicted));
        assertEq(factory.circleOf(bad), address(0));
    }

    function test_clone_cannotBeReinitialized() public {
        vm.prank(operator);
        address circle = factory.createRotating(_rotParams(ID, 3));
        vm.prank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        MockRotatingCircle(circle).initialize(_rotParams(keccak256("hijack"), 3));
        assertEq(MockRotatingCircle(circle).circleId(), ID);
    }

    function test_implementations_haveInitializersDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        rotImpl.initialize(_rotParams(ID, 3));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        accImpl.initialize(_accParams(ID, 3));
    }

    function test_cloneByAnotherDeployer_isNotACircle() public {
        // Anyone can clone the implementation elsewhere, but it is never `isCircle` and never a reporter.
        address rogue = _rogueClone(address(rotImpl));
        MockRotatingCircle(rogue).initialize(_rotParams(ID, 3));
        assertFalse(factory.isCircle(rogue));
        assertFalse(reputation.isReporter(rogue));
        vm.expectRevert(IMHReputation.NotReporter.selector);
        MockRotatingCircle(rogue).strikeForTest(attacker, 1, IMHReputation.Reason.DEFAULT);
    }

    // ---------------------------------------------------------------- Helpers

    enum Variant {
        Ok,
        Swapped,
        ForeignRegistry,
        ForeignReputation,
        ForeignUsdc
    }

    /// @dev Deploys a Reputation that authorizes the factory the caller deploys next, plus two implementations
    ///      wired per `v`. Nonces: reputation n, implementations n+1 and n+2, factory n+3.
    function _stack(Variant v) internal returns (MHReputation rep, address r, address a) {
        IUSDC u = IUSDC(address(usdc));
        IMHCircleRegistry reg = registry;
        if (v == Variant.ForeignRegistry) {
            reg = new MHCircleRegistry(address(timelock), u, operator, guardian, treasury);
        } else if (v == Variant.ForeignUsdc) {
            u = IUSDC(address(new MockUSDC()));
        }
        uint256 n = vm.getNonce(address(this));
        rep = new MHReputation(address(timelock), vm.computeCreateAddress(address(this), n + 3));
        IMHReputation repForImpl = v == Variant.ForeignReputation ? IMHReputation(makeAddr("otherRep")) : rep;
        if (v == Variant.Swapped) {
            r = address(new MockAccumulationCircle(u, reg, repForImpl));
            a = address(new MockRotatingCircle(u, reg, repForImpl));
        } else {
            r = address(new MockRotatingCircle(u, reg, repForImpl));
            a = address(new MockAccumulationCircle(u, reg, repForImpl));
        }
    }

    function _cloneInitcode(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    function _rogueClone(address impl) internal returns (address instance) {
        bytes memory code = _cloneInitcode(impl);
        assembly ("memory-safe") {
            instance := create(0, add(code, 0x20), mload(code))
        }
        require(instance != address(0), "clone failed");
    }
}
