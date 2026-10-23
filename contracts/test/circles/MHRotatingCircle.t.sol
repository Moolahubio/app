// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { RotatingFixture } from "./RotatingFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHCircleTerms } from "../../src/circles/MHCircleTerms.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { CircleMode, CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Unit tests for `MHRotatingCircle`: every function, revert and event (spec §4.5, §4.7).
contract MHRotatingCircleTest is RotatingFixture {
    // ================================================================ Implementation

    function test_implementation_isInertAndWired() public {
        MHRotatingCircle impl = MHRotatingCircle(rotatingImpl);
        assertEq(uint8(impl.circleMode()), uint8(CircleMode.Rotating));
        assertEq(address(impl.USDC()), address(usdc));
        assertEq(address(impl.REGISTRY()), address(registry));
        assertEq(address(impl.REPUTATION()), address(reputation));
        RotatingParams memory p = _params(3, 0, 10_000);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHRotatingCircle(IUSDC(address(0)), registry, reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHRotatingCircle(IUSDC(address(usdc)), IMHCircleRegistry(address(0)), reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHRotatingCircle(IUSDC(address(usdc)), registry, IMHReputation(address(0)));
    }

    // ================================================================ initialize

    function test_initialize_storesTerms() public {
        RotatingParams memory p = _params(4, 150, 7_500);
        p.securityBps[3] = 5_000;
        MHRotatingCircle c = _create(p);

        assertTrue(factory.isCircle(address(c)));
        assertEq(c.circleId(), p.config.circleId);
        assertEq(c.contribution(), C);
        assertEq(c.feeBps(), 150);
        assertEq(c.roundDuration(), ROUND);
        assertEq(c.grace(), GRACE);
        assertEq(c.cure(), CURE);
        assertEq(c.joinDeadline(), p.config.joinDeadline);
        assertEq(c.plannedStart(), p.config.plannedStart);
        assertEq(c.totalRounds(), 4);
        assertEq(uint8(c.status()), uint8(CircleStatus.Pending));
        assertEq(c.nextSettle(), 1);
        assertEq(c.joinedCount(), 0);
        assertEq(c.startTime(), 0);
        assertEq(c.extension(), 0);
        assertEq(c.members(), p.members);
        for (uint256 i; i < 4; ++i) {
            assertEq(c.slotOf(p.members[i]), i + 1);
            IMHRotatingCircle.MemberState memory st = c.memberState(p.members[i]);
            assertEq(st.slot, i + 1);
            assertEq(st.securityBps, p.securityBps[i]);
            assertFalse(st.joined);
        }
        assertEq(c.slotOf(attacker), 0);
        assertEq(
            c.termsHash(),
            MHCircleTerms.rotating(block.chainid, address(c), p.config, p.members, p.securityBps),
            "terms hash"
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        c.initialize(p);
    }

    function test_initialize_rejectsEveryBadConfig() public {
        for (uint256 k; k < 22; ++k) {
            RotatingParams memory p = _badParams(k);
            vm.prank(operator);
            vm.expectRevert(IMHCircle.BadConfig.selector);
            factory.createRotating(p);
        }
    }

    function test_initialize_acceptsBoundaries() public {
        RotatingParams memory p = _params(50, 200, 5_000);
        p.securityBps[49] = 10_000;
        p.config.contribution = K.MIN_CONTRIBUTION;
        p.config.roundDuration = uint64(K.MAX_ROUND);
        p.config.grace = uint64(K.MAX_ROUND - 1);
        p.config.cure = uint64(K.MAX_CURE);
        p.config.joinDeadline = uint64(block.timestamp + K.MAX_JOIN_WINDOW);
        p.config.plannedStart = uint64(block.timestamp + K.MAX_JOIN_WINDOW + K.MAX_START_DELAY);
        _create(p);

        p = _params(2, 0, 10_000);
        // forge-lint: disable-next-line(divide-before-multiply)
        p.config.contribution = (K.MAX_CONTRIBUTION / K.CENT) * K.CENT; // largest whole-cent amount
        p.config.roundDuration = uint64(K.MIN_ROUND);
        p.config.grace = uint64(K.MIN_GRACE);
        p.config.cure = uint64(K.MIN_CURE);
        p.config.joinDeadline = uint64(block.timestamp + 1);
        p.config.plannedStart = 0;
        _create(p);
    }

    function _badParams(uint256 k) internal returns (RotatingParams memory p) {
        p = _params(3, 0, 10_000);
        if (k == 0) p.config.circleId = bytes32(0);
        else if (k == 1) p = _params(1, 0, 10_000);
        else if (k == 2) p = _params(51, 0, 10_000);
        else if (k == 3) p.config.totalRounds = 4;
        else if (k == 4) p.securityBps = new uint16[](2);
        else if (k == 5) p.securityBps[1] = 4_999;
        else if (k == 6) p.securityBps[2] = 10_001;
        else if (k == 7) p.config.contribution = K.MIN_CONTRIBUTION - K.CENT;
        else if (k == 8) p.config.contribution = C + 1;
        else if (k == 9) p.config.contribution = (K.MAX_CONTRIBUTION / K.CENT + 1) * K.CENT;
        else if (k == 10) p.config.feeBps = 201;
        else if (k == 11) p.config.roundDuration = 7 days - 1;
        else if (k == 12) p.config.roundDuration = 92 days + 1;
        else if (k == 13) p.config.grace = 48 hours - 1;
        else if (k == 14) p.config.grace = ROUND;
        else if (k == 15) p.config.cure = 72 hours - 1;
        else if (k == 16) p.config.cure = 30 days + 1;
        else if (k == 17) p.config.joinDeadline = uint64(block.timestamp);
        else if (k == 18) p.config.joinDeadline = uint64(block.timestamp + 30 days + 1);
        else if (k == 19) p.config.plannedStart = p.config.joinDeadline + 30 days + 1;
        else if (k == 20) p.members[1] = address(0);
        else if (k == 21) p.members[2] = p.members[0];
    }

    // ================================================================ join

    function test_join_recordsMemberAndPullsCollateral() public {
        _create(_params(3, 0, 10_000));
        _fund(slots[0], 250e6);
        bytes32 terms = circle.termsHash();
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.Joined(slots[0], 250e6);
        vm.prank(slots[0]);
        circle.join(terms, 250e6);

        IMHRotatingCircle.MemberState memory st = circle.memberState(slots[0]);
        assertTrue(st.joined);
        assertEq(st.sec, 250e6);
        assertEq(st.cashIn, 250e6);
        assertEq(circle.secTotal(), 250e6);
        assertEq(circle.joinedCount(), 1);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Pending));
        assertEq(usdc.balanceOf(address(circle)), 250e6);
        assertEq(usdc.allowance(slots[0], address(circle)), 0, "exact approval consumed");
        _assertBuckets();
    }

    function test_join_lastJoinActivatesAtPlannedStart() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 0);
        _join(slots[1], 0);
        uint64 planned = circle.plannedStart();
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHRotatingCircle.Activated(planned);
        _join(slots[2], 0);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
        assertEq(circle.startTime(), planned);
        assertEq(circle.currentRound(), 0, "round 1 not open yet");
        vm.warp(planned);
        assertEq(circle.currentRound(), 1);
    }

    function test_join_lastJoinAfterPlannedStartStartsNow() public {
        RotatingParams memory p = _params(3, 0, 10_000);
        p.config.plannedStart = uint64(block.timestamp + 1 days);
        _create(p);
        _join(slots[0], 0);
        _join(slots[1], 0);
        vm.warp(block.timestamp + 3 days);
        _join(slots[2], 0);
        assertEq(circle.startTime(), block.timestamp);
        assertEq(circle.currentRound(), 1);
    }

    function test_join_reverts() public {
        _create(_params(3, 0, 10_000));
        bytes32 terms = circle.termsHash();

        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.join(terms, 0);

        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.BadTerms.selector);
        circle.join(terms ^ bytes32(uint256(1)), 0);

        _join(slots[0], 0);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.AlreadyJoined.selector);
        circle.join(terms, 0);

        vm.warp(circle.joinDeadline());
        _join(slots[1], 0); // the deadline itself is still open
        vm.warp(circle.joinDeadline() + 1);
        vm.prank(slots[2]);
        vm.expectRevert(IMHCircle.JoinClosed.selector);
        circle.join(terms, 0);
    }

    function test_join_revertsNotPendingOnceActive() public {
        _startCircle(3, 0, 10_000);
        bytes32 terms = circle.termsHash();
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotPending.selector);
        circle.join(terms, 0);
    }

    function test_join_withoutCollateralWorksWhileUsdcPaused() public {
        _create(_params(3, 0, 10_000));
        usdc.pause();
        _join(slots[0], 0);
        assertTrue(circle.memberState(slots[0]).joined);
        bytes32 terms = circle.termsHash();
        usdc.unpause();
        _fund(slots[1], 1e6); // minting and approving revert while paused, so fund first
        usdc.pause();
        vm.prank(slots[1]);
        vm.expectRevert("Pausable: paused");
        circle.join(terms, 1e6);
    }

    // ================================================================ depositCollateral

    function test_depositCollateral_pendingAndActive() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 0);
        _fund(slots[0], 40e6);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CollateralDeposited(slots[0], 40e6);
        vm.prank(slots[0]);
        circle.depositCollateral(40e6);
        assertEq(circle.memberState(slots[0]).sec, 40e6);
        assertEq(circle.memberState(slots[0]).cashIn, 40e6);

        _join(slots[1], 0);
        _join(slots[2], 0);
        _fund(slots[1], 10e6);
        vm.prank(slots[1]);
        circle.depositCollateral(10e6);
        assertEq(circle.memberState(slots[1]).sec, 10e6);
        assertEq(circle.secTotal(), 50e6);
        _assertBuckets();
    }

    function test_depositCollateral_reverts() public {
        _create(_params(3, 0, 10_000));
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotMember.selector); // a member who has not joined
        circle.depositCollateral(1e6);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.depositCollateral(1e6);

        _join(slots[0], 0);
        vm.prank(slots[0]);
        vm.expectRevert(IMHRotatingCircle.ZeroAmount.selector);
        circle.depositCollateral(0);

        vm.prank(guardian);
        circle.guardianCancel();
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.depositCollateral(1e6);
    }

    // ================================================================ contribute

    function test_contribute_pullsAndEmits() public {
        _startCircle(3, 0, 10_000);
        _fund(slots[2], C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[2], 1, C, 0, false);
        vm.prank(slots[2]);
        uint256 pulled = circle.contribute(1, C);

        assertEq(pulled, C);
        assertTrue(circle.paid(1, slots[2]));
        assertEq(circle.pot(1), C);
        assertEq(circle.potTotal(), C);
        IMHRotatingCircle.MemberState memory st = circle.memberState(slots[2]);
        assertEq(st.paidRounds, 1);
        assertEq(st.cashIn, C);
        assertEq(usdc.balanceOf(slots[2]), 0);
        _assertBuckets();
    }

    function test_contribute_reverts() public {
        _create(_params(3, 0, 10_000));
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.contribute(1, C);

        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.BadRound.selector); // Active, but round 1 has not opened
        circle.contribute(1, C);

        vm.warp(circle.startTime());
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.contribute(1, C);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(0, C);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.BadRound.selector); // round 2 has not opened
        circle.contribute(2, C);

        _pay(slots[0], 1);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.AlreadyPaid.selector);
        circle.contribute(1, C);

        _fund(slots[1], C);
        vm.prank(slots[1]);
        vm.expectRevert(IMHCircle.ExceedsMaxPull.selector);
        circle.contribute(1, C - 1);

        _pay(slots[1], 1);
        _pay(slots[2], 1);
        circle.settleRound();
        _openRound(2);
        vm.prank(slots[1]);
        vm.expectRevert(IMHCircle.BadRound.selector); // already settled
        circle.contribute(1, C);
    }

    function test_contribute_lateRecordsLateStrike() public {
        _startCircle(3, 0, 10_000);
        vm.warp(_graceEnd(1));
        _pay(slots[0], 1); // exactly at the end of grace: on time
        assertEq(reputation.strikeCount(slots[0]), 0);

        vm.warp(_graceEnd(1) + 1);
        _fund(slots[1], C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[1], 1, C, 0, true);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(slots[1], address(circle), 1, IMHReputation.Reason.LATE);
        vm.prank(slots[1]);
        circle.contribute(1, C);
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.LATE));
        assertEq(reputation.strikeCount(slots[1]), 1);
    }

    function test_contribute_lateWhileUsdcPaused_reverts() public {
        _startCircle(3, 0, 10_000);
        _afterGrace(1);
        _fund(slots[1], C);
        usdc.pause();
        vm.prank(slots[1]);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.contribute(1, C);
    }

    function test_contribute_fullyDrawnPullsNothingAndIsNeverLate() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        circle.settleRound(); // slot 1 holds S_1 = 200
        _openRound(2);
        _afterGrace(2);
        assertEq(circle.amountDue(slots[0], 2), 0);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[0], 2, 0, C, false);
        vm.prank(slots[0]);
        assertEq(circle.contribute(2, 0), 0);
        assertEq(reputation.strikeCount(slots[0]), 0);
        assertEq(circle.memberState(slots[0]).sec, 100e6);
        _assertBuckets();
    }

    function test_contribute_partialDrawAtSigma50() public {
        _startCircle(3, 0, 5_000); // S_1 = ceil(0.5·2·100) = 100
        _payAll(1, _everyone());
        circle.settleRound();
        assertEq(circle.memberState(slots[0]).sec, 100e6);
        _openRound(2);
        // reqAfter = ceil(0.5·1·100) = 50, so 50 is drawn and the wallet owes 50.
        assertEq(circle.amountDue(slots[0], 2), 50e6);
        _fund(slots[0], 50e6);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[0], 2, 50e6, 50e6, false);
        vm.prank(slots[0]);
        circle.contribute(2, 50e6);
        assertEq(circle.memberState(slots[0]).sec, 50e6);
        assertEq(circle.requiredSecurity(slots[0]), 50e6);
    }

    function test_contribute_aheadForAnOpenRound() public {
        _startCircle(3, 0, 10_000);
        _pay(slots[0], 1);
        _pay(slots[1], 1);
        _openRound(2);
        assertEq(circle.currentRound(), 2);
        _pay(slots[0], 2); // window: nextSettle (1) ≤ 2 ≤ currentRound (2)
        assertEq(circle.pot(2), C);
        _pay(slots[2], 1);
        circle.settleRound();

        // Slot 1 paid round 2 before its payout, so the literal S_1 holdback (200) exceeds what it still owes
        // (one round, 100); the excess is immediately withdrawable.
        assertEq(circle.memberState(slots[0]).sec, 200e6);
        assertEq(circle.requiredSecurity(slots[0]), 100e6);
        vm.prank(slots[0]);
        circle.withdrawSecurity(100e6);

        _payAll(2, _everyone());
        circle.settleRound();
        assertEq(circle.nextSettle(), 3);
        _assertBuckets();
    }

    // ================================================================ amountDue

    function test_amountDue_cases() public {
        _create(_params(3, 0, 10_000));
        assertEq(circle.amountDue(slots[0], 1), 0, "pending");
        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
        assertEq(circle.amountDue(slots[1], 1), C);
        assertEq(circle.amountDue(slots[0], 1), 0, "audit 2 R1-19: the recipient's own round is netted");
        assertEq(circle.amountDue(attacker, 1), 0, "non-member");
        assertEq(circle.amountDue(slots[1], 0), 0, "round 0");
        assertEq(circle.amountDue(slots[1], 4), 0, "beyond the last round");
        _pay(slots[1], 1);
        assertEq(circle.amountDue(slots[1], 1), 0, "paid");
        // Audit R2-22 (closeout A-R2-22): a round that has not opened is not due (`contribute` would revert BadRound).
        assertEq(circle.amountDue(slots[2], 2), 0, "round 2 not open yet");
        vm.prank(slots[2]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(2, C);
        vm.warp(circle.startTime() + ROUND);
        _pay(slots[2], 1);
        assertEq(circle.amountDue(slots[2], 2), C, "due once open");
    }

    // ================================================================ settleRound

    function test_settleRound_fundedPaysRecipient() public {
        _startCircle(3, 200, 10_000);
        _payAll(1, _everyone());
        // gross 300, fee 6, holdback S_1 = 200, cash 94
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.RoundSettled(1, slots[0], 300e6, 6e6, 200e6, 94e6);
        circle.settleRound();

        IMHRotatingCircle.MemberState memory st = circle.memberState(slots[0]);
        assertTrue(st.received);
        assertEq(st.sec, 200e6);
        assertEq(st.cashOut, 94e6);
        assertEq(usdc.balanceOf(slots[0]), 94e6);
        assertEq(circle.feeEscrow(), 6e6);
        assertEq(circle.nextSettle(), 2);
        assertEq(circle.pot(1), 0);
        assertEq(circle.potTotal(), 0);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
        _assertBuckets();
    }

    function test_settleRound_reverts() public {
        _create(_params(3, 0, 10_000));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.settleRound();

        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        vm.expectRevert(IMHCircle.BadRound.selector); // round 1 not open
        circle.settleRound();

        vm.warp(circle.startTime());
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();

        _payAll(1, _everyone());
        circle.settleRound();
        vm.expectRevert(IMHCircle.BadRound.selector); // round 2 not open
        circle.settleRound();
    }

    function test_settleRound_coversAfterGraceWithStrike() public {
        uint256[] memory col = new uint256[](2);
        col[1] = C; // slot 2: S_2 = 100, so no draw and the wallet owes 100
        _startCircle(3, 0, 10_000, col);
        _pay(slots[0], 1);
        _pay(slots[2], 1);
        vm.warp(_graceEnd(1));
        vm.expectRevert(IMHCircle.RoundShort.selector); // no cover before grace has passed
        circle.settleRound();

        vm.warp(_graceEnd(1) + 1);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[1], 1, 0, C, true);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Covered(slots[1], 1, C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.RoundSettled(1, slots[0], 300e6, 0, 200e6, 100e6);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(slots[1], address(circle), 1, IMHReputation.Reason.COVERED);
        circle.settleRound();

        IMHRotatingCircle.MemberState memory st = circle.memberState(slots[1]);
        assertEq(st.sec, 0);
        assertEq(st.paidRounds, 1);
        assertTrue(circle.paid(1, slots[1]));
        assertEq(reputation.strikeCount(slots[1]), 1);
        _assertBuckets();
    }

    function test_settleRound_noPartialCover() public {
        uint256[] memory col = new uint256[](2);
        col[1] = C - K.CENT;
        _startCircle(3, 0, 10_000, col);
        _pay(slots[0], 1);
        _pay(slots[2], 1);
        _afterCure(1);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();
    }

    function test_settleRound_coverWhileUsdcPaused_reverts() public {
        uint256[] memory col = new uint256[](2);
        col[1] = C;
        _startCircle(3, 0, 10_000, col);
        _pay(slots[0], 1);
        _pay(slots[2], 1);
        _afterGrace(1);
        usdc.pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.settleRound();
        usdc.unpause();
        circle.settleRound();
    }

    function test_settleRound_fundedWhileUsdcPaused_queuesPayout() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        usdc.pause();
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.PayoutQueued(slots[0], 100e6);
        circle.settleRound();
        assertEq(circle.owed(slots[0]), 100e6);
        assertEq(circle.owedTotal(), 100e6);
        assertEq(usdc.balanceOf(slots[0]), 0);
        _assertBuckets();

        usdc.unpause();
        vm.prank(slots[0]);
        assertEq(circle.claimOwed(), 100e6);
        assertEq(usdc.balanceOf(slots[0]), 100e6);
        _assertBuckets();
    }

    function test_settleRound_blacklistedRecipient_queuesPayout() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        usdc.blacklist(slots[0]);
        circle.settleRound();
        assertEq(circle.owed(slots[0]), 100e6);
        // Blacklisted after paying its round: the payout is queued. (Blacklisted before paying, it cannot pay, and
        // its own part is netted from the payout instead: see MHAuditRound1Rotating, R1-07.)
        assertEq(circle.nextSettle(), 2, "a blacklisted recipient does not block the circle");
        vm.prank(slots[0]);
        vm.expectRevert("Blacklistable: account is blacklisted");
        circle.claimOwed();
        usdc.unBlacklist(slots[0]);
        vm.prank(slots[0]);
        circle.claimOwed();
        assertEq(usdc.balanceOf(slots[0]), 100e6);
    }

    function test_settleRound_drawsWithoutStrikeWhenWalletOwesNothing() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone()); // slot 1 owes 0 and is skipped
        assertFalse(circle.paid(2, slots[0]));
        _afterCure(2); // even long after grace a zero-owing member is not "late"
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[0], 2, 0, C, false);
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[0]), 0);
        assertEq(circle.memberState(slots[0]).sec, 100e6);
        _assertBuckets();
    }

    function test_settleRound_lastRoundCompletes() public {
        _startCircle(2, 0, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone());
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCompleted();
        circle.settleRound();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.settleRound();
        _assertBuckets();
    }

    // ================================================================ withdrawSecurity

    function test_withdrawSecurity_aboveRequirementWhileActive() public {
        uint256[] memory col = new uint256[](2);
        col[1] = 150e6; // slot 2: S_2 = 100
        _startCircle(3, 0, 10_000, col);
        assertEq(circle.requiredSecurity(slots[1]), 100e6);
        vm.prank(slots[1]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(50e6 + 1);

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.SecurityWithdrawn(slots[1], 50e6);
        vm.prank(slots[1]);
        circle.withdrawSecurity(50e6);
        IMHRotatingCircle.MemberState memory st = circle.memberState(slots[1]);
        assertEq(st.sec, 100e6);
        assertEq(st.cashOut, 50e6);
        assertEq(usdc.balanceOf(slots[1]), 50e6);

        // After its payout slot 1 holds exactly its requirement: nothing is free.
        _payAll(1, _everyone());
        circle.settleRound();
        assertEq(circle.requiredSecurity(slots[0]), 200e6);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(1);
        _assertBuckets();
    }

    function test_withdrawSecurity_reverts() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 10e6);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector); // Pending
        circle.withdrawSecurity(1e6);

        _join(slots[1], 0);
        _join(slots[2], 0);
        vm.prank(slots[0]);
        vm.expectRevert(IMHRotatingCircle.ZeroAmount.selector);
        circle.withdrawSecurity(0);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.withdrawSecurity(1e6);

        vm.prank(guardian);
        circle.guardianCancel();
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector); // Cancelled: security became claims
        circle.withdrawSecurity(1e6);
    }

    function test_withdrawSecurity_everythingOnceCompleted() public {
        uint256[] memory col = new uint256[](1);
        col[0] = 500e6; // slot 1 of 2: S_1 = 100
        _startCircle(2, 0, 10_000, col);
        _payAll(1, _everyone()); // slot 1 draws 100 from its 400 spare
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        assertEq(circle.memberState(slots[0]).sec, 300e6);
        vm.prank(slots[0]);
        circle.withdrawSecurity(300e6);
        assertEq(circle.secTotal(), 0);
        assertEq(_net(slots[0]), 0);
        assertEq(_net(slots[1]), 0);
        _assertBuckets();
    }

    function test_withdrawSecurity_blacklistedQueuesInOwed() public {
        uint256[] memory col = new uint256[](3);
        col[2] = 30e6; // slot 3: S_3 = 0, all free
        _startCircle(3, 0, 10_000, col);
        usdc.blacklist(slots[2]);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.PayoutQueued(slots[2], 30e6);
        vm.prank(slots[2]);
        circle.withdrawSecurity(30e6);
        assertEq(circle.owed(slots[2]), 30e6);
        assertEq(circle.memberState(slots[2]).cashOut, 30e6);
        _assertBuckets();
    }

    // ================================================================ claim

    function test_claim_paysAndClears() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 70e6);
        vm.prank(guardian);
        circle.guardianCancel();
        assertEq(circle.memberState(slots[0]).claim, 70e6);

        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.claim();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.Claimed(slots[0], 70e6);
        vm.prank(slots[0]);
        assertEq(circle.claim(), 70e6);
        assertEq(usdc.balanceOf(slots[0]), 70e6);
        assertEq(circle.claimTotal(), 0);
        assertEq(circle.memberState(slots[0]).cashOut, 70e6);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.claim();
        _assertBuckets();
    }

    function test_claim_blacklistedQueuesInOwed() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 70e6);
        vm.prank(guardian);
        circle.guardianCancel();
        usdc.blacklist(slots[0]);
        vm.prank(slots[0]);
        circle.claim();
        assertEq(circle.owed(slots[0]), 70e6);
        assertEq(circle.claimTotal(), 0);
        _assertBuckets();
    }

    // ================================================================ cancelStalled

    function test_cancelStalled_reverts() public {
        _create(_params(3, 0, 10_000));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.cancelStalled();

        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
        _pay(slots[0], 1);
        _pay(slots[1], 1);
        vm.warp(_graceEnd(1) + CURE);
        vm.expectRevert(IMHCircle.NotStalled.selector); // the last second of cure
        circle.cancelStalled();

        vm.warp(_graceEnd(1) + CURE + 1);
        usdc.pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.cancelStalled();
        usdc.unpause();
        circle.cancelStalled();
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.cancelStalled();
    }

    function test_cancelStalled_notStalledWhileEveryGapIsCoverable() public {
        uint256[] memory col = new uint256[](2);
        col[1] = C;
        _startCircle(3, 0, 10_000, col);
        _pay(slots[0], 1);
        _pay(slots[2], 1);
        _afterCure(1);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelStalled();
        circle.settleRound(); // the gap is covered instead
    }

    function test_cancelStalled_strikesAndAssignsClaims() public {
        _startCircle(3, 0, 10_000);
        _pay(slots[0], 1);
        _pay(slots[1], 1);
        _afterCure(1);

        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Defaulted(slots[2], 1, 0); // E = 0, so the penalty is 0
        vm.expectEmit(true, false, false, true, address(circle));
        // Audit 2 R1-03: slot 1's own round-1 payment is circular, so it is refunded at par and its E is 0.
        emit IMHRotatingCircle.ClaimAssigned(slots[0], 0, C);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.ClaimAssigned(slots[1], C, C);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.ClaimAssigned(slots[2], 0, 0);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCancelled(IMHRotatingCircle.CancelReason.Stalled, 2 * C, 0);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(slots[2], address(circle), 1, IMHReputation.Reason.DEFAULT);
        circle.cancelStalled();

        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        assertEq(circle.secTotal(), 0);
        assertEq(circle.potTotal(), 0);
        assertEq(circle.pot(1), 0);
        assertEq(circle.feeEscrow(), 0);
        assertEq(circle.claimTotal(), 2 * C);
        assertEq(reputation.strikeCount(slots[0]), 0);
        assertEq(reputation.strikeCount(slots[1]), 0);
        _assertBuckets();
        _claimAll();
        assertEq(_net(slots[0]), 0);
        assertEq(_net(slots[1]), 0);
        _assertBuckets();
    }

    function test_cancelStalled_penaltyStaysWhenNoOtherMemberHasAPositivePosition() public {
        // Slots 2 and 3 post collateral below c and nobody pays round 1. Slot 1 is the recipient: its own part is
        // nettable from its payout (fee 0: 300 − 200 holdback ≥ 100), so it is not a defaulter, and its E is 0.
        uint256[] memory col = new uint256[](3);
        col[1] = 40e6; // S_2 = 100: nothing drawable
        col[2] = 30e6; // S_3 = 0: 30 drawable, 70 owed
        _startCircle(3, 0, 10_000, col);
        _afterCure(1);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Defaulted(slots[1], 1, 0);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Defaulted(slots[2], 1, 0);
        circle.cancelStalled();
        assertEq(circle.memberState(slots[1]).claim, 40e6, "slot 2 keeps its whole position");
        assertEq(circle.memberState(slots[2]).claim, 30e6, "slot 3 keeps its whole position");
        assertEq(circle.memberState(slots[0]).claim, 0);
        assertFalse(reputation.struck(slots[0], address(circle), 1, IMHReputation.Reason.DEFAULT));
        _claimAll();
        for (uint256 i; i < 3; ++i) {
            assertEq(_net(slots[i]), 0);
        }
        _assertBuckets();
    }

    /// @dev Audit R1-07: the recipient that never pays its own round (here with no security at all) is netted
    ///      from its payout instead of stalling the circle; it ends exactly where paying would have left it.
    function test_settleRound_recipientsOwnPartIsNetted() public {
        _startCircle(2, 0, 5_000); // S_1 = ceil(0.5·1·100) = 50
        _payAll(1, _everyone());
        circle.settleRound(); // slot 1: cash 150, holdback 50
        _openRound(2);
        _pay(slots[0], 2); // draws 50, pays 50
        assertEq(circle.amountDue(slots[1], 2), 0, "audit 2 R1-19: nothing due, the payout nets it");
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.OwnContributionNetted(slots[1], 2, C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.RoundSettled(2, slots[1], 200e6, 0, 0, 100e6);
        circle.settleRound(); // before grace, no strike
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        assertEq(reputation.strikeCount(slots[1]), 0);
        assertEq(circle.memberState(slots[1]).paidRounds, 2);
        _withdrawAllSecurity();
        assertEq(_net(slots[0]), 0);
        assertEq(_net(slots[1]), 0);
        _assertBuckets();
    }

    // ================================================================ guardianCancel

    function test_guardianCancel_pendingRefundsCollateral() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 70e6);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCancelled(IMHRotatingCircle.CancelReason.Guardian, 70e6, 0);
        vm.prank(guardian);
        circle.guardianCancel();
        _claimAll();
        assertEq(_net(slots[0]), 0);
        assertEq(reputation.strikeCount(slots[0]), 0);
    }

    function test_guardianCancel_activeBeforeFirstPayoutRefundsExactly() public {
        uint256[] memory col = new uint256[](1);
        col[0] = 50e6;
        _startCircle(3, 200, 10_000, col);
        _pay(slots[0], 1);
        _pay(slots[1], 1);
        _openRound(2);
        _pay(slots[1], 2); // a contribution to the next open round is refunded too
        vm.prank(guardian);
        circle.guardianCancel();
        assertEq(circle.memberState(slots[0]).claim, 150e6);
        assertEq(circle.memberState(slots[1]).claim, 200e6);
        assertEq(circle.memberState(slots[2]).claim, 0);
        assertEq(circle.pot(2), 0);
        _claimAll();
        for (uint256 i; i < 3; ++i) {
            assertEq(_net(slots[i]), 0);
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        _assertBuckets();
    }

    function test_guardianCancel_reverts() public {
        _startCircle(3, 0, 10_000);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.guardianCancel();
        vm.prank(operator);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.guardianCancel();

        _payAll(1, _everyone());
        circle.settleRound();
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.BadRound.selector); // R4: a payout has been made
        circle.guardianCancel();
    }

    function test_guardianCancel_revertsOnceEnded() public {
        _create(_params(3, 0, 10_000));
        vm.prank(guardian);
        circle.guardianCancel();
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.guardianCancel();
    }

    function test_guardianCancel_followsRegistryRotation() public {
        _create(_params(3, 0, 10_000));
        address newGuardian = makeAddr("newGuardian");
        _govExec(address(registry), abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian)));
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.guardianCancel();
        vm.prank(newGuardian);
        circle.guardianCancel();
    }

    // ================================================================ cancelUnjoined

    function test_cancelUnjoined() public {
        _create(_params(3, 0, 10_000));
        _join(slots[0], 30e6);
        _join(slots[1], 0);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelUnjoined();
        vm.warp(circle.joinDeadline());
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelUnjoined();

        vm.warp(circle.joinDeadline() + 1);
        usdc.pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.cancelUnjoined();
        usdc.unpause();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCancelled(IMHRotatingCircle.CancelReason.Unjoined, 30e6, 0);
        vm.prank(attacker); // anyone
        circle.cancelUnjoined();
        _claimAll();
        assertEq(_net(slots[0]), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        vm.expectRevert(IMHCircle.NotPending.selector);
        circle.cancelUnjoined();
    }

    function test_cancelUnjoined_revertsOnceActive() public {
        _startCircle(3, 0, 10_000);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(IMHCircle.NotPending.selector);
        circle.cancelUnjoined();
    }

    // ================================================================ flushFees

    function test_flushFees_onlyOnceCompleted() public {
        _startCircle(2, 200, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        vm.expectRevert(IMHCircle.NotEnded.selector);
        circle.flushFees();
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.FeesFlushed(treasury, 8e6); // 2 rounds × 2% of 200
        vm.prank(attacker); // anyone
        circle.flushFees();
        assertEq(usdc.balanceOf(treasury), 8e6);
        assertEq(circle.feeEscrow(), 0);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.flushFees();
        _assertBuckets();
    }

    function test_flushFees_zeroFeeHasNothing() public {
        _startCircle(2, 0, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.flushFees();
    }

    function test_flushFees_blacklistedTreasuryQueues() public {
        _startCircle(2, 200, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();
        usdc.blacklist(treasury);
        circle.flushFees();
        assertEq(circle.owed(treasury), 8e6);
        _assertBuckets();
    }

    // ================================================================ extendDeadline

    function test_extendDeadline_reverts() public {
        _create(_params(3, 0, 10_000));
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.extendDeadline(1 days);

        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.extendDeadline(1 days);

        vm.startPrank(guardian);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(0);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(7 days + 1);
        for (uint256 i; i < 4; ++i) {
            circle.extendDeadline(7 days);
        }
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(2 days + 1);
        circle.extendDeadline(2 days);
        assertEq(circle.extension(), 30 days);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(1);
        vm.stopPrank();
    }

    function test_extendDeadline_movesEveryGate() public {
        _startCircle(3, 0, 10_000);
        uint256 oldGraceEnd = _graceEnd(1);
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHRotatingCircle.DeadlineExtended(7 days, 7 days);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        assertEq(circle.roundDeadline(1), circle.startTime() + ROUND + 7 days);
        assertEq(circle.currentRound(), 1, "round windows do not move");

        _pay(slots[0], 1);
        vm.warp(oldGraceEnd + CURE + 1);
        vm.expectRevert(IMHCircle.NotStalled.selector); // the stall gate moved
        circle.cancelStalled();
        _pay(slots[1], 1); // the late gate moved: no LATE strike
        assertEq(reputation.strikeCount(slots[1]), 0);
        vm.expectRevert(IMHCircle.RoundShort.selector); // the cover gate moved (and slot 3 has no security)
        circle.settleRound();
        _afterCure(1);
        circle.cancelStalled();
    }

    // ================================================================ sweeps

    function test_sweepDonations_sendsOnlyUntrackedUsdc() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepDonations();

        usdc.mint(address(circle), 5e6); // a donation
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.DonationsSwept(treasury, 5e6);
        vm.prank(attacker); // anyone
        circle.sweepDonations();
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(usdc.balanceOf(address(circle)), circle.trackedAssets());
        circle.settleRound(); // the round is untouched
    }

    function test_sweepDonations_excludesOwed() public {
        _startCircle(3, 0, 10_000);
        _payAll(1, _everyone());
        usdc.blacklist(slots[0]);
        circle.settleRound(); // 100 queued for slot 1
        usdc.mint(address(circle), 1e6);
        circle.sweepDonations();
        assertEq(usdc.balanceOf(treasury), 1e6);
        assertEq(usdc.balanceOf(address(circle)), circle.trackedAssets() + circle.owedTotal());
    }

    function test_sweepResidual_reverts() public {
        _startCircle(3, 0, 10_000);
        vm.expectRevert(IMHCircle.NotEnded.selector); // Active
        circle.sweepResidual();

        _pay(slots[0], 1);
        _afterCure(1);
        circle.cancelStalled();
        vm.expectRevert(IMHCircle.NotEnded.selector); // a claim is outstanding
        circle.sweepResidual();
        _claimAll();
        vm.expectRevert(IMHCircle.NothingToClaim.selector); // exact split: no residual
        circle.sweepResidual();
    }

    function test_sweepResidual_completedHasNothing() public {
        _startCircle(2, 0, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepResidual();
    }

    // ================================================================ views

    function test_paid_settledRoundsCountForEveryMember() public {
        _startCircle(3, 0, 10_000);
        assertFalse(circle.paid(1, slots[0]));
        _pay(slots[1], 1);
        assertTrue(circle.paid(1, slots[1]));
        assertFalse(circle.paid(1, slots[0]));
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, _everyone()); // slot 1 owes nothing and is drawn by settlement, which writes no flag
        assertFalse(circle.paid(2, slots[0]));
        circle.settleRound();
        assertTrue(circle.paid(2, slots[0]), "settled round");
        assertTrue(circle.paid(1, slots[2]));
        assertFalse(circle.paid(3, slots[0]));
        assertFalse(circle.paid(0, slots[0]));
        assertFalse(circle.paid(1, attacker), "non-member");
    }

    function test_amountsAreRangeChecked() public {
        _create(_params(3, 0, 10_000));
        uint256 huge = uint256(type(uint80).max) + 1;
        _fund(slots[0], huge);
        bytes32 terms = circle.termsHash();
        vm.prank(slots[0]);
        vm.expectRevert(abi.encodeWithSignature("SafeCastOverflowedUintDowncast(uint8,uint256)", 80, huge));
        circle.join(terms, huge);
    }

    function test_views_roundClock() public {
        _create(_params(3, 0, 10_000));
        assertEq(circle.currentRound(), 0);
        assertEq(circle.roundDeadline(1), 0);
        for (uint256 i; i < 3; ++i) {
            _join(slots[i], 0);
        }
        uint256 start = circle.startTime();
        vm.warp(start);
        assertEq(circle.currentRound(), 1);
        assertEq(circle.roundDeadline(1), start + ROUND);
        assertEq(circle.roundDeadline(3), start + 3 * ROUND);
        vm.warp(start + ROUND - 1);
        assertEq(circle.currentRound(), 1);
        vm.warp(start + ROUND);
        assertEq(circle.currentRound(), 2);
        vm.warp(start + 10 * ROUND);
        assertEq(circle.currentRound(), 3, "capped at totalRounds");
    }

    function test_views_requiredSecurity() public {
        _startCircle(3, 0, 10_000);
        assertEq(circle.requiredSecurity(slots[0]), 200e6, "S_1");
        assertEq(circle.requiredSecurity(slots[1]), 100e6, "S_2");
        assertEq(circle.requiredSecurity(slots[2]), 0, "S_3");
        assertEq(circle.requiredSecurity(attacker), 0);
        _payAll(1, _everyone());
        circle.settleRound();
        assertEq(circle.requiredSecurity(slots[0]), 200e6, "paid 1 of 3");
        _openRound(2);
        _payAll(2, _everyone());
        circle.settleRound();
        assertEq(circle.requiredSecurity(slots[0]), 100e6, "paid 2 of 3");
        assertEq(circle.trackedAssets(), circle.secTotal() + circle.potTotal() + circle.feeEscrow());
    }
}
