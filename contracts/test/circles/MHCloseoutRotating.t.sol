// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RotatingFixture } from "./RotatingFixture.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Closeout of the internal audit of the rotating circle: list A (audit 1, round 2: A-R2-05 and the A-R2-21
///         survivor R17) and list B (audit 2, round 2: B-R2-02, B-R2-03, B-R2-04 (acknowledged, pinned), B-R2-05,
///         and the B-R2-14 survivors R04/R09 plus overlapping-round fuzzing). Each B low finding was first reproduced
///         on the unfixed code; these tests assert the fixed (or, for B-R2-04, the accepted) behaviour.
contract MHCloseoutRotatingTest is RotatingFixture {
    function _bit(uint256 slot) internal pure returns (uint256) {
        // forge-lint: disable-next-line(incorrect-shift)
        return 1 << (slot - 1);
    }

    function _allBut(uint256 slot) internal pure returns (uint256) {
        return type(uint256).max ^ _bit(slot);
    }

    function _nets(uint256 n) internal view returns (int256[] memory nets) {
        nets = new int256[](n);
        for (uint256 i; i < n; ++i) {
            nets[i] = _net(slots[i]);
        }
    }

    // ================================================================ A-R2-05: σ < 100% paid-out member

    /// @dev A-R2-05: at σ = 50% a paid-out member (slot 1, security $400 after its payout, fully drawn for round 2)
    ///      that has not paid the stalled round moves nothing onto the creditors, whether it does nothing, withdraws
    ///      everything it may first (R2-05: its requirement keeps a full contribution for the open round), or
    ///      satisfies round 2 explicitly: every member's final position is identical, and the member gets out
    ///      exactly what a cancellation refunds. Closing review: this equality holds for a member drawn in full for
    ///      the stalled round. A paid-out member at σ < 100% drawn only in part (it owes `c − draw` from its wallet)
    ///      keeps that wallet part by skipping (COVERED strike, write-off): acknowledged, pinned in
    ///      `MHClosingReviewRotating::test_CR_02_partiallyDrawnDebtor_skipKeepsTheWalletPart_pinned`.
    function test_A1R2_05_sigma50_paidOutMember_withdrawOrSkipMovesNothing() public {
        uint256 n = 6;
        int256[] memory base;
        for (uint256 mode; mode < 3; ++mode) {
            uint256 snap = vm.snapshotState();
            uint256[] memory col = new uint256[](1);
            col[0] = 500e6; // S_1 = $250, round 1 drawn in full, $400 left after the payout
            _startCircle(n, 0, 5_000, col);
            _payAll(1, _everyone());
            circle.settleRound();
            assertEq(circle.memberState(slots[0]).sec, 400e6);
            _openRound(2);
            assertEq(circle.amountDue(slots[0], 2), 0, "round 2 fully drawn");
            _payAll(2, _allBut(1) & _allBut(6)); // slot 6 defaults; slot 1 owes nothing from its wallet
            if (mode == 1) {
                assertEq(circle.requiredSecurity(slots[0]), 300e6, "ceil(50% x 4 x c) + c");
                vm.prank(slots[0]);
                circle.withdrawSecurity(100e6);
            } else if (mode == 2) {
                vm.prank(slots[0]);
                circle.contribute(2, 0);
            }
            _afterCure(2);
            circle.cancelStalled();
            _claimAll();
            _assertBuckets();
            int256[] memory nets = _nets(n);
            if (mode == 0) {
                base = nets;
            } else {
                for (uint256 i; i < n; ++i) {
                    assertEq(nets[i], base[i], "every final position is independent of slot 1's choice");
                }
            }
            vm.revertToState(snap);
        }
    }

    // ================================================================ Boundaries (A-R2-21 R17, B-R2-14 R04/R09)

    /// @dev R17 / R04: the R1-06 withdrawal lock starts strictly after the (un-extended) grace end: a withdrawal below
    ///      c is still allowed at the grace end itself and refused one second later.
    function test_A2R2_14_R04_withdrawLockBoundary() public {
        uint256[] memory col = new uint256[](3);
        col[2] = 150e6; // slot 3: S_3 = 0
        _startCircle(3, 0, 10_000, col);
        _payAll(1, 3); // slot 3 does not pay round 1
        uint256 graceEnd = circle.startTime() + ROUND + GRACE;
        uint256 snap = vm.snapshotState();
        vm.warp(graceEnd);
        vm.prank(slots[2]);
        circle.withdrawSecurity(60e6); // leaves $90 < c: allowed at the boundary
        vm.revertToState(snap);
        vm.warp(graceEnd + 1);
        vm.prank(slots[2]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(60e6);
    }

    /// @dev R09: a wallet payment exactly at the grace end is on time; one second later it is LATE.
    function test_A2R2_14_R09_lateStrikeBoundary() public {
        _startCircle(3, 0, 10_000);
        uint256 snap = vm.snapshotState();
        vm.warp(_graceEnd(1));
        _payApp(slots[2], 1);
        assertEq(reputation.strikeCount(slots[2]), 0, "on time at the boundary");
        vm.revertToState(snap);
        vm.warp(_graceEnd(1) + 1);
        _payApp(slots[2], 1);
        assertTrue(reputation.struck(slots[2], address(circle), 1, IMHReputation.Reason.LATE));
    }

    // ================================================================ B-R2-02: own round skipped only when nettable

    /// @dev B-R2-02 (reproduced: slot 1, which `settleRound` cannot net, prepaid round 2, defaulted round 1 and lost
    ///      the prepayment as its penalty). Its own round is no longer skipped: round 2 is not due and not payable
    ///      until round 1 is paid. A nettable recipient still skips its own round.
    function test_A2R2_02_nonNettableRecipient_mustPayItsOwnRoundFirst() public {
        _startCircle(3, 200, 10_000);
        vm.warp(circle.startTime() + ROUND); // round 2 open, round 1 in grace
        assertEq(circle.amountDue(slots[0], 1), C, "not nettable: its part is due");
        assertEq(circle.amountDue(slots[0], 2), 0, "round 2 is not payable yet");
        _fund(slots[0], C);
        vm.prank(slots[0]);
        vm.expectRevert(IMHRotatingCircle.OutOfOrder.selector);
        circle.contribute(2, C);
        _payApp(slots[0], 1);
        assertEq(circle.amountDue(slots[0], 2), C, "now due");
        _payApp(slots[0], 2);

        // Slot 2 (nettable: its payout of $294 absorbs its $100) may pay round 3 before its own round 2.
        _payApp(slots[1], 1);
        _payApp(slots[2], 1);
        circle.settleRound();
        vm.warp(circle.startTime() + 2 * ROUND); // round 3 open, round 2 in grace
        assertEq(circle.amountDue(slots[1], 2), 0, "own round netted");
        assertEq(circle.amountDue(slots[1], 3), C);
        _payApp(slots[1], 3);
        assertTrue(circle.paid(3, slots[1]));
    }

    // ================================================================ B-R2-03: a fully drawn round does not block

    function _overlapCircle() internal {
        RotatingParams memory p = _params(4, 0, 10_000);
        p.config.roundDuration = 14 days;
        p.config.cure = 20 days; // the cure outlasts a round: round 1 can settle after round 2's grace
        _create(p);
        _join(slots[0], 0);
        _join(slots[1], 0);
        _join(slots[2], 0);
        _join(slots[3], 150e6); // slot 4: S_4 = 0, round 1 drawn in full, round 2 draws $50
        vm.warp(circle.startTime());
    }

    /// @dev B-R2-03 (reproduced: slot 4, fully drawn for round 1, could not pay round 2 and was never asked; when round
    ///      1 settled after round 2's grace it was struck LATE). Round 2 is now due during its window, and paying it
    ///      draws round 1 first; nothing is struck when round 1 finally settles.
    function test_A2R2_03_fullyDrawnRound_doesNotBlockTheNext() public {
        _overlapCircle();
        assertEq(circle.amountDue(slots[3], 1), 0, "round 1 fully drawn");
        _payApp(slots[1], 1); // slot 2 pays; slot 3 does not; slot 1 is netted
        vm.warp(circle.startTime() + 14 days); // round 2 open
        assertEq(circle.amountDue(slots[3], 2), 50e6, "asked for round 2 in its window");
        _fund(slots[3], 50e6);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[3], 1, 0, C, false); // round 1 drawn first, zero pull
        vm.prank(slots[3]);
        assertEq(circle.contribute(2, 50e6), 50e6);
        assertTrue(circle.paid(1, slots[3]) && circle.paid(2, slots[3]));
        _payApp(slots[0], 2); // slot 1's own round 1 is nettable, so round 2 is payable
        assertEq(circle.amountDue(slots[2], 2), 0, "slot 3 must pay round 1 first");
        vm.warp(circle.roundDeadline(2) + circle.grace() + 1); // round 2's grace over, round 1 in its cure
        _payApp(slots[2], 1); // slot 3 pays round 1 late
        circle.settleRound(); // round 1
        assertTrue(reputation.struck(slots[2], address(circle), 1, IMHReputation.Reason.LATE));
        _payApp(slots[2], 2); // late for round 2 as well
        circle.settleRound();
        assertEq(circle.nextSettle(), 3);
        assertEq(reputation.strikeCount(slots[3]), 0, "slot 4 paid as asked: no strike");
        _assertBuckets();
    }

    // ================================================================ B-R2-04: acknowledged, pinned

    function _pauseAcrossGraceEnd() internal {
        uint256[] memory col = new uint256[](3);
        col[1] = 150e6; // slot 2: draw $50 < c, security >= c: coverable
        _startCircle(3, 0, 10_000, col);
        _payAll(1, 5); // slots 1 and 3
        usdc.setPaused(true);
        vm.warp(circle.startTime() + ROUND); // the pause starts before the grace end
    }

    /// @dev B-R2-04 (acknowledged, same root cause as audit 1 R1-08 / R2-12): with no Guardian action, the first block
    ///      after a USDC pause that spanned the grace end can cover a member with a COVERED strike (or strike a payment
    ///      LATE). Pinned so any change is deliberate.
    function test_A2R2_04_pinned_strikeInFirstBlockAfterPause_withoutGuardian() public {
        _pauseAcrossGraceEnd();
        vm.warp(_graceEnd(1) + 1 hours);
        usdc.setPaused(false);
        circle.settleRound();
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.COVERED));
    }

    /// @dev B-R2-04 control: the runbook. `extendDeadline` works while USDC is paused, and the extension moves every
    ///      gate (grace for covers and LATE, grace + cure for the stall), so the member pays after the unpause with
    ///      no strike.
    function test_A2R2_04_guardianExtendsDuringPause_noStrike() public {
        _pauseAcrossGraceEnd();
        vm.prank(guardian);
        circle.extendDeadline(7 days); // while paused
        vm.warp(circle.startTime() + ROUND + GRACE + 1 hours);
        usdc.setPaused(false);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound(); // not past the extended grace: no cover
        _payApp(slots[1], 1);
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[1]), 0);
    }

    // ================================================================ B-R2-05: late collateral is a late payment

    /// @dev B-R2-05 (reproduced: a late payment through `depositCollateral` was never struck). A deposit after grace
    ///      that turns the member's short draw into a full one is a LATE payment.
    function test_A2R2_05_lateCollateral_isStruckLate() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, 3); // slot 3 (S_3 = 0, no security) does not pay
        _afterGrace(1);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();
        _fund(slots[2], C);
        vm.prank(slots[2]);
        circle.depositCollateral(C);
        assertTrue(reputation.struck(slots[2], address(circle), 1, IMHReputation.Reason.LATE));
        circle.settleRound(); // drawn in full: no cover, no second strike
        assertEq(reputation.strikeCount(slots[2]), 1);
        _assertBuckets();
    }

    /// @dev B-R2-05: no strike for a deposit that is not a late payment: before the grace end, by a member that already
    ///      paid, by a member fully drawn already, or one too small to make the draw full (then `settleRound` covers
    ///      it: one COVERED strike, never two).
    function test_A2R2_05_otherDeposits_notStruck() public {
        uint256[] memory col = new uint256[](4);
        col[1] = 150e6; // slot 2: S_2 = $200 > $150, so its draw is 0 and it owes c; security >= c: coverable
        _startCircle(4, 0, 10_000, col);
        // Before the grace end: slot 4 tops up instead of paying; on time.
        _fund(slots[3], C);
        vm.prank(slots[3]);
        circle.depositCollateral(C);
        assertEq(reputation.strikeCount(slots[3]), 0);
        _payApp(slots[0], 1);
        _payApp(slots[2], 1);
        _afterGrace(1);
        // Slot 3 already paid: a late deposit is not a payment.
        _fund(slots[2], 10e6);
        vm.prank(slots[2]);
        circle.depositCollateral(10e6);
        assertEq(reputation.strikeCount(slots[2]), 0);
        // Slot 2 (S_2 = $200, security $150: draw 0) deposits $100: security $250 >= c but the draw is still $50.
        _fund(slots[1], C);
        vm.prank(slots[1]);
        circle.depositCollateral(C);
        assertEq(reputation.strikeCount(slots[1]), 0, "a partial top-up is not a payment");
        circle.settleRound(); // covers slot 2 in full
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.COVERED));
        assertEq(reputation.strikeCount(slots[1]), 1, "one strike");
    }

    /// @dev B-R2-03 variant, found by `testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck` (seed
    ///      0x3a06…0a0f): slot 2 (σ = 50%, $300 collateral) is shown `amountDue(3) == 0` before its own round 2
    ///      settles. Round 2 settles only after round 3's grace (slot 4 pays it late, in a cure longer than a round).
    ///      The settlement used to draw slot 2's own round from that security, so round 3 suddenly needed $50 from its
    ///      wallet past grace. The own round is now netted in full from the payout, so round 3 stays fully drawn.
    function test_A2R2_03_ownRoundSettlement_keepsLaterRoundsDrawn() public {
        RotatingParams memory p = _params(4, 0, 5_000);
        p.config.roundDuration = 14 days;
        p.config.cure = 20 days;
        _create(p);
        _join(slots[0], 0);
        _join(slots[1], 300e6); // S_2 = $100: round 1 drawn in full, $200 left
        _join(slots[2], 0);
        _join(slots[3], 0);
        vm.warp(circle.startTime());
        for (uint256 i; i < 4; ++i) {
            _payApp(slots[i], 1);
        }
        circle.settleRound();
        vm.warp(circle.startTime() + 14 days); // round 2: slot 4 does not pay
        _payApp(slots[0], 2);
        _payApp(slots[2], 2);
        vm.warp(circle.startTime() + 28 days); // round 3 open, round 2 short (past grace, in cure)
        assertEq(circle.amountDue(slots[1], 2), 0, "own round: netted");
        assertEq(circle.amountDue(slots[1], 3), 0, "round 3: drawn in full from its security");
        _payApp(slots[0], 3);
        _payApp(slots[2], 3);
        vm.warp(circle.roundDeadline(3) + circle.grace() + 1); // round 3's grace over
        _payApp(slots[3], 2); // late
        circle.settleRound(); // round 2, slot 2's own: netted in full
        assertEq(circle.memberState(slots[1]).sec, 200e6, "security untouched by its own round");
        _payApp(slots[3], 3); // late
        circle.settleRound(); // round 3: slot 2 drawn in full
        assertEq(reputation.strikeCount(slots[1]), 0, "slot 2 did what the app showed: no strike");
        _assertBuckets();
    }

    // ================================================================ B-R2-14: overlapping rounds, fuzzed

    struct Fz {
        uint256 n;
        uint256 reliable;
        uint256 h;
    }

    /// @dev B-R2-14 test gap (the rotating fuzzer played rounds one at a time with a fixed round and cure): random
    ///      round length (7–30 days), grace and cure up to 30 days (so the cure can outlast several rounds), σ, fee
    ///      and collateral; time moves in random steps of at most one round, members pay any open round in any
    ///      order the circle accepts, and the keeper settles or cancels at random. Properties: the buckets stay exact
    ///      and a member that pays every non-zero `amountDue` when it sees it (the app) is never struck.
    function testFuzz_A2R2_14_overlappingRounds_reliableMembersNeverStruck(uint256 seed) public {
        Fz memory z;
        z.n = bound(seed, 3, 7);
        RotatingParams memory p =
            _params(z.n, uint16(bound(seed >> 8, 0, 200)), (seed >> 16) % 2 == 0 ? 10_000 : 5_000);
        p.config.roundDuration = uint64(bound(seed >> 24, 7 days, 30 days));
        p.config.grace = uint64(bound(seed >> 48, 48 hours, p.config.roundDuration - 1));
        p.config.cure = uint64(bound(seed >> 72, 72 hours, 30 days));
        _create(p);
        for (uint256 i; i < z.n; ++i) {
            _join(slots[i], uint256(keccak256(abi.encode(seed, "col", i))) % 4 == 0 ? 3 * C : 0);
        }
        vm.warp(circle.startTime());
        z.reliable = uint256(keccak256(abi.encode(seed, "reliable"))) | 1; // at least slot 1 is reliable
        for (uint256 step; step < 6 * z.n && circle.status() == CircleStatus.Active; ++step) {
            z.h = uint256(keccak256(abi.encode(seed, step)));
            vm.warp(block.timestamp + bound(z.h, 1 hours, p.config.roundDuration));
            for (uint256 i; i < z.n; ++i) {
                bool rel = (z.reliable >> i) & 1 == 1;
                if (!rel && (z.h >> (8 + i)) % 3 != 0) continue; // unreliable: pays sometimes
                uint256 last = circle.currentRound();
                for (uint256 r = circle.nextSettle(); r <= last; ++r) {
                    if (circle.paid(r, slots[i])) continue;
                    _payApp(slots[i], r);
                }
            }
            if ((z.h >> 64) % 2 == 0) {
                (bool ok,) = address(circle).call(abi.encodeCall(circle.settleRound, ()));
                ok;
            }
            if ((z.h >> 72) % 4 == 0) {
                (bool ok,) = address(circle).call(abi.encodeCall(circle.cancelStalled, ()));
                ok;
            }
            _assertBuckets();
        }
        for (uint256 i; i < z.n; ++i) {
            if ((z.reliable >> i) & 1 == 1) {
                assertEq(reputation.strikeCount(slots[i]), 0, "a member that paid as asked was struck");
            }
        }
    }
}
