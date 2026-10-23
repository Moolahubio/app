// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { MockRotatingCircle } from "../mocks/MockCircles.sol";

contract MHReputationTest is CircleFixture {
    address internal reporter = makeAddr("reporterCircle");
    address internal user = makeAddr("member");

    function setUp() public override {
        super.setUp();
        vm.prank(address(factory));
        reputation.setReporter(reporter);
    }

    // ---------------------------------------------------------------- Construction and ownership

    function test_constructor() public view {
        assertEq(reputation.owner(), address(timelock));
        assertEq(reputation.FACTORY(), address(factory));
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(IMHReputation.ZeroAddress.selector);
        new MHReputation(address(timelock), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MHReputation(address(0), address(factory));
    }

    function test_ownershipIsTwoStep_andRenounceDisabled() public {
        address next = makeAddr("next");
        vm.prank(address(timelock));
        reputation.transferOwnership(next);
        assertEq(reputation.owner(), address(timelock));
        vm.prank(next);
        reputation.acceptOwnership();
        assertEq(reputation.owner(), next);

        vm.prank(next);
        vm.expectRevert(IMHReputation.RenounceDisabled.selector);
        reputation.renounceOwnership();
    }

    function test_ownerHasNoPowerOverReporters() public {
        vm.prank(address(timelock));
        vm.expectRevert(IMHReputation.NotFactory.selector);
        reputation.setReporter(attacker);
    }

    // ---------------------------------------------------------------- setReporter

    function test_setReporter_onlyFactory() public {
        address[4] memory callers = [attacker, operator, guardian, gov];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IMHReputation.NotFactory.selector);
            reputation.setReporter(callers[i]);
        }
        assertFalse(reputation.isReporter(attacker));
    }

    function test_setReporter_emitsAndRegisters() public {
        address c = makeAddr("circle2");
        vm.expectEmit(true, false, false, false, address(reputation));
        emit IMHReputation.ReporterSet(c);
        vm.prank(address(factory));
        reputation.setReporter(c);
        assertTrue(reputation.isReporter(c));
    }

    function test_setReporter_rejectsZero() public {
        vm.prank(address(factory));
        vm.expectRevert(IMHReputation.ZeroAddress.selector);
        reputation.setReporter(address(0));
    }

    // ---------------------------------------------------------------- record

    function test_record_onlyReporter() public {
        vm.prank(attacker);
        vm.expectRevert(IMHReputation.NotReporter.selector);
        reputation.record(user, attacker, 1, IMHReputation.Reason.LATE);
        // Not even the factory or the owner can write strikes.
        vm.prank(address(factory));
        vm.expectRevert(IMHReputation.NotReporter.selector);
        reputation.record(user, address(factory), 1, IMHReputation.Reason.LATE);
        vm.prank(address(timelock));
        vm.expectRevert(IMHReputation.NotReporter.selector);
        reputation.record(user, address(timelock), 1, IMHReputation.Reason.LATE);
    }

    function test_record_writesAndEmits() public {
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(user, reporter, 3, IMHReputation.Reason.COVERED);
        vm.prank(reporter);
        bool recorded = reputation.record(user, reporter, 3, IMHReputation.Reason.COVERED);
        assertTrue(recorded);
        assertTrue(reputation.struck(user, reporter, 3, IMHReputation.Reason.COVERED));
        assertEq(reputation.strikeCount(user), 1);
        assertEq(reputation.strikesByReason(user, IMHReputation.Reason.COVERED), 1);
    }

    function test_record_isIdempotent() public {
        vm.startPrank(reporter);
        assertTrue(reputation.record(user, reporter, 2, IMHReputation.Reason.MISSED));
        vm.recordLogs();
        assertFalse(reputation.record(user, reporter, 2, IMHReputation.Reason.MISSED));
        assertFalse(reputation.record(user, reporter, 2, IMHReputation.Reason.MISSED));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0, "no event on repeat");
        assertEq(reputation.strikeCount(user), 1);
        assertEq(reputation.strikesByReason(user, IMHReputation.Reason.MISSED), 1);
    }

    /// @dev Regression for the legacy `struck` key without a reason: a LATE strike must not block a later
    ///      DEFAULT strike for the same round.
    function test_record_reasonIsPartOfTheKey() public {
        vm.startPrank(reporter);
        assertTrue(reputation.record(user, reporter, 4, IMHReputation.Reason.LATE));
        assertTrue(reputation.record(user, reporter, 4, IMHReputation.Reason.DEFAULT));
        assertTrue(reputation.record(user, reporter, 4, IMHReputation.Reason.COVERED));
        assertTrue(reputation.record(user, reporter, 4, IMHReputation.Reason.MISSED));
        assertTrue(reputation.record(user, reporter, 5, IMHReputation.Reason.LATE));
        vm.stopPrank();
        assertEq(reputation.strikeCount(user), 5);
        assertEq(reputation.strikesByReason(user, IMHReputation.Reason.LATE), 2);
        assertEq(reputation.strikesByReason(user, IMHReputation.Reason.DEFAULT), 1);
    }

    function test_record_circlesAreSeparateKeys() public {
        address other = makeAddr("otherCircle");
        vm.prank(address(factory));
        reputation.setReporter(other);
        vm.prank(reporter);
        assertTrue(reputation.record(user, reporter, 1, IMHReputation.Reason.LATE));
        vm.prank(other);
        assertTrue(reputation.record(user, other, 1, IMHReputation.Reason.LATE));
        assertEq(reputation.strikeCount(user), 2);
    }

    function test_record_cannotStrikeUnderAnotherCircle() public {
        address victim = makeAddr("victimCircle");
        vm.prank(reporter);
        vm.recordLogs();
        bool recorded = reputation.record(user, victim, 1, IMHReputation.Reason.DEFAULT);
        assertFalse(recorded, "ignored, not reverted");
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(reputation.struck(user, victim, 1, IMHReputation.Reason.DEFAULT));
        assertEq(reputation.strikeCount(user), 0);
    }

    /// @dev "Never reverts for a registered reporter": any user, round and reason, repeated or not.
    function testFuzz_record_neverRevertsForReporter(address who, uint256 round, uint8 reasonRaw, bool repeat)
        public
    {
        IMHReputation.Reason reason = IMHReputation.Reason(bound(reasonRaw, 0, 3));
        vm.startPrank(reporter);
        bool first = reputation.record(who, reporter, round, reason);
        assertTrue(first);
        if (repeat) assertFalse(reputation.record(who, reporter, round, reason));
        vm.stopPrank();
        assertTrue(reputation.struck(who, reporter, round, reason));
        assertEq(reputation.strikeCount(who), 1);
    }

    function test_record_gasIsSmallAndBounded() public {
        vm.prank(reporter);
        uint256 g = gasleft();
        reputation.record(user, reporter, 1, IMHReputation.Reason.LATE);
        uint256 used = g - gasleft();
        assertLt(used, 100_000, "record must stay cheap");
    }

    // ---------------------------------------------------------------- Integration: factory-created circle

    function test_factoryCreatedCircleCanStrike() public {
        vm.prank(operator);
        address circle = factory.createRotating(_rotParams(keccak256("c1"), 3));
        assertTrue(reputation.isReporter(circle));
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(user, circle, 2, IMHReputation.Reason.LATE);
        MockRotatingCircle(circle).strikeForTest(user, 2, IMHReputation.Reason.LATE);
        assertTrue(reputation.struck(user, circle, 2, IMHReputation.Reason.LATE));
    }

    function test_implementationIsNotAReporter() public {
        vm.expectRevert(IMHReputation.NotReporter.selector);
        rotImpl.strikeForTest(user, 1, IMHReputation.Reason.LATE);
    }
}
