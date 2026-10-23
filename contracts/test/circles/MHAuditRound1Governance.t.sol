// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { RotatingFixture } from "./RotatingFixture.sol";
import { CircleFixture } from "./CircleFixture.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";

/// @notice Audit round 1: R1-20 (fixed) and the acknowledged governance findings R1-19 and R1-21, pinned so any change
///         to the accepted behaviour is deliberate. The mitigations live in the runbook (IMPLEMENTATION_NOTES,
///         "Round 1 fixes").
contract MHAuditRound1CancellerTest is CircleFixture {
    address internal g2 = makeAddr("guardianSafe2");

    /// @dev R1-20 (fixed): after a partial rotation (only `registry.setGuardian(G2)` executed) the replaced Guardian
    ///      can no longer veto anything; the canceller fails closed until `canceller.setGuardian(G2)` lands too.
    function test_R1_20_partialRotation_oldGuardianLosesVetoAtOnce() public {
        _govExec(address(registry), abi.encodeCall(IMHCircleRegistry.setGuardian, (g2)));
        assertEq(registry.guardian(), g2);
        assertEq(canceller.guardian(), guardian, "the canceller still stores the old Guardian");

        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 salt = _nextSalt();
        _schedule(address(registry), 0, data, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.NotGuardian.selector);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);
        vm.prank(g2);
        vm.expectRevert(MHGuardianCanceller.NotGuardian.selector);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);

        _govExec(address(canceller), abi.encodeCall(MHGuardianCanceller.setGuardian, (g2)));
        vm.prank(g2);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);
    }

    /// @dev R1-19 (acknowledged): a rotation scheduled with a non-rotation predecessor can be blocked by cancelling
    ///      the predecessor. Runbook: rotation-only operations use predecessor 0; monitors alert on a rotation
    ///      `CallScheduled` with a non-zero predecessor.
    function test_R1_19_rotationWithPredecessor_canBeBlocked_usePredecessorZero() public {
        bytes memory p = abi.encodeCall(IMHCircleRegistry.setTreasury, (makeAddr("newTreasury")));
        bytes32 saltP = _nextSalt();
        bytes32 idP = _schedule(address(registry), 0, p, saltP);
        bytes memory r = abi.encodeCall(IMHCircleRegistry.setGuardian, (g2));
        bytes32 saltR = _nextSalt();
        vm.prank(gov);
        timelock.schedule(address(registry), 0, r, idP, saltR, DELAY);
        vm.prank(guardian);
        canceller.cancel(address(registry), 0, p, bytes32(0), saltP);
        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, idP)
        );
        timelock.execute(address(registry), 0, r, idP, saltR);

        // With predecessor 0 (the runbook rule) the rotation cannot be blocked.
        bytes32 salt = _nextSalt();
        _schedule(address(registry), 0, r, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancel(address(registry), 0, r, bytes32(0), salt);
        vm.warp(block.timestamp + DELAY);
        _govExecute(address(registry), r, salt);
        assertEq(registry.guardian(), g2);
    }
}

/// @notice R1-08 (acknowledged) and R1-21 (acknowledged) on the rotating circle.
contract MHAuditRound1RotatingPauseTest is RotatingFixture {
    function _setup() internal {
        _startCircle(3, 0, 10_000);
        _pay(slots[0], 1);
        vm.warp(circle.roundDeadline(1) - 1 hours);
        usdc.pause();
    }

    /// @dev PoC R1-08 `test_a_cancelStalledAtUnpause` (accepted): with no Guardian action, a pause longer than
    ///      grace + cure lets anyone cancel in the first block after the unpause.
    function test_R1_08_pinned_cancelAtUnpauseWithoutGuardian() public {
        _setup();
        vm.warp(_graceEnd(1) + circle.cure() + 1);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.cancelStalled();
        usdc.unpause();
        circle.cancelStalled();
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.DEFAULT));
    }

    /// @dev PoC R1-08 `test_b_guardianExtendsWhilePaused_noStall`: the runbook response, extending while USDC is
    ///      still paused (`extendDeadline` has no pause guard), removes the race.
    function test_R1_08_guardianExtendsWhilePaused_noStall() public {
        _setup();
        vm.warp(circle.roundDeadline(1) + 2 hours);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        vm.warp(circle.roundDeadline(1) - 7 days + GRACE + CURE + 1);
        usdc.unpause();
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelStalled();
        _pay(slots[1], 1);
        _pay(slots[2], 1);
        assertFalse(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.LATE));
        circle.settleRound();
    }

    /// @dev R1-21 (accepted): the 7-day per-call cap is not a rate limit; the 30-day total is the only bound.
    function test_R1_21_pinned_perCallCapIsNotARateLimit() public {
        _startCircle(3, 0, 10_000);
        vm.startPrank(guardian);
        for (uint256 i; i < 4; ++i) {
            circle.extendDeadline(7 days);
        }
        circle.extendDeadline(2 days);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(1);
        vm.stopPrank();
        assertEq(circle.extension(), 30 days);
    }
}

/// @notice R1-08 (acknowledged) and R1-18 (acknowledged) on the accumulation circle.
contract MHAuditRound1AccumulationPauseTest is AccumulationFixture {
    function _setup() internal {
        _start(3, 3, 0, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _pay(people[0], 2);
        vm.warp(circle.roundDeadline(2) - 1 hours);
        usdc.pause();
    }

    /// @dev PoC R1-08 `test_a_raceAtUnpause_flagWins`. Audit 2 R1-08: `flagRound` now waits for grace + cure, so
    ///      in the first block after the unpause it reverts and the Guardian still has the cure to extend; with no
    ///      Guardian action it fires once the cure is over.
    function test_R1_08_pinned_flagAtUnpauseWithoutGuardian() public {
        _setup();
        vm.warp(_graceEnd(2) + 1 hours);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
        usdc.unpause();
        vm.expectRevert(IMHCircle.BadRound.selector); // the cure: no race at the unpause any more
        circle.flagRound(2);
        _afterCure(2);
        circle.flagRound(2);
        assertTrue(reputation.struck(people[1], address(circle), 2, IMHReputation.Reason.MISSED));
    }

    /// @dev PoC R1-08 `test_b_guardianExtendsWhilePaused_noRace`: the runbook response.
    function test_R1_08_guardianExtendsWhilePaused_noRace() public {
        _setup();
        vm.warp(circle.roundDeadline(2) + 1 hours);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        vm.warp(_graceEnd(2) - 7 days + 1 hours);
        usdc.unpause();
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
        _pay(people[1], 2);
        _pay(people[2], 2);
        assertEq(circle.memberState(people[1]).paidRounds, 2);
    }

    /// @dev R1-18 (accepted): between maturity and `finalize` the Active-state Guardian cancel unwinds by shares
    ///      with no caps. It is kept because it is the only exit when the vault cannot value shares before
    ///      `finalize` (R1-03); runbook: cancel after maturity only if `finalize` reverts, and finalize promptly.
    function test_R1_18_pinned_cancelBetweenMaturityAndFinalize() public {
        _startYield(4, 1_000);
        _runRounds(_everyone(), 3, (1 << 4) | (1 << 8));
        morpho.mockYield(115e6);
        _mature();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
        vm.prank(guardian);
        circle.guardianCancel();
        vm.prank(people[3]);
        circle.claim();
        assertApproxEqAbs(usdc.balanceOf(people[3]), 1_025e6, 2, "uncapped (accepted)");
    }
}
