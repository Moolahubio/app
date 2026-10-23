// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RotatingFixture } from "./RotatingFixture.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Closing review of the internal audit closeout, rotating circle. Finding 1 (informational, fixed): a late
///         collateral deposit that pays several overlapping rounds is struck LATE for each of them, as `contribute`
///         would strike them, whatever the keeper's timing. Finding 2 (informational, acknowledged): a partially
///         drawn paid-out member at σ < 100% keeps its wallet part by skipping a stalled round (pinned). Each was
///         first reproduced on the unfixed code with the reviewer's PoC.
contract MHClosingReviewRotatingTest is RotatingFixture {
    uint64 internal constant LONG_ROUND = 14 days;

    function _late(address who, uint256 round) internal view returns (bool) {
        return reputation.struck(who, address(circle), round, IMHReputation.Reason.LATE);
    }

    function _openLong(uint256 round) internal {
        uint256 t = circle.startTime() + (round - 1) * LONG_ROUND;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < t) vm.warp(t);
    }

    /// @dev The reviewer's overlap: n = 4, σ = 100%, no fee, 14-day rounds, a 20-day cure. Slot 4 (S_4 = 0, no
    ///      collateral) skips rounds 1 and 2; time is past round 2's grace while round 1 is still in its cure.
    function _overlap() internal {
        RotatingParams memory p = _params(4, 0, 10_000);
        p.config.roundDuration = LONG_ROUND;
        p.config.cure = 20 days;
        _create(p);
        for (uint256 i; i < 4; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
        _payApp(slots[1], 1);
        _payApp(slots[2], 1);
        _openLong(2);
        _payApp(slots[0], 2);
        _payApp(slots[2], 2);
        vm.warp(_graceEnd(2) + 1);
        assertLt(block.timestamp, _graceEnd(1) + circle.cure(), "round 1 is still in its cure");
    }

    function _deposit(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        circle.depositCollateral(amount);
    }

    // ================================================================ Finding 1: every round a deposit pays

    /// @dev Reviewer PoC `test_ZZ_lateCollateral_onlySettlingRoundStruck`, asserting the fixed outcome: one deposit of
    ///      2c pays rounds 1 and 2, both past grace: LATE for each (it was round 1 only), exactly the strikes of the
    ///      `contribute` path (`test_ZZ_contributePath_strikesBoth`). Both settlements then draw in full: no cover,
    ///      no second strike.
    function test_CR_01_oneDepositPaysTwoRounds_bothStruckLate() public {
        _overlap();
        uint256 snap = vm.snapshotState();
        _payApp(slots[3], 1);
        _payApp(slots[3], 2);
        uint256 viaContribute = reputation.strikeCount(slots[3]);
        assertEq(viaContribute, 2);
        vm.revertToState(snap);

        _deposit(slots[3], 2 * C);
        assertTrue(_late(slots[3], 1), "round 1 LATE");
        assertTrue(_late(slots[3], 2), "round 2 LATE (closing review)");
        assertEq(reputation.strikeCount(slots[3]), viaContribute, "same strikes as paying through contribute");
        circle.settleRound();
        circle.settleRound();
        assertEq(circle.nextSettle(), 3);
        assertEq(reputation.strikeCount(slots[3]), 2, "drawn in full at settlement: never struck twice");
        _assertBuckets();
    }

    /// @dev The strikes no longer depend on the keeper's timing: paying the two rounds with two deposits, round 1
    ///      settled in between (round 2 then is the settling round), gives the same strikes as one deposit.
    function test_CR_01_sameStrikes_whateverTheKeeperTiming() public {
        _overlap();
        uint256 snap = vm.snapshotState();
        _deposit(slots[3], C); // pays round 1 only: round 2 is still short after it
        assertTrue(_late(slots[3], 1));
        assertFalse(_late(slots[3], 2), "a deposit that does not complete round 2 does not pay it");
        circle.settleRound();
        _deposit(slots[3], C);
        assertTrue(_late(slots[3], 2));
        uint256 split = reputation.strikeCount(slots[3]);
        vm.revertToState(snap);

        _deposit(slots[3], 2 * C);
        assertEq(reputation.strikeCount(slots[3]), split);
        assertEq(split, 2);
    }

    /// @dev The settling round is paid (round 1 waits for another member in its cure) and the deposit pays round 2
    ///      late: struck for round 2 (the B-R2-05 check looked only at the settling round and missed it).
    function test_CR_01_settlingRoundPaid_laterRoundPaidByCollateral_isStruck() public {
        RotatingParams memory p = _params(4, 0, 10_000);
        p.config.roundDuration = LONG_ROUND;
        p.config.cure = 20 days;
        _create(p);
        for (uint256 i; i < 4; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
        _payApp(slots[1], 1);
        _payApp(slots[3], 1); // slot 4 pays round 1 on time; slot 3 (S_3 = c, no security) does not
        _openLong(2);
        _payApp(slots[0], 2); // slot 4 skips round 2
        vm.warp(_graceEnd(2) + 1);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();

        _deposit(slots[3], C);
        assertTrue(_late(slots[3], 2), "round 2 paid late by the deposit");
        assertEq(reputation.strikeCount(slots[3]), 1);

        _payApp(slots[2], 1); // slot 3 pays rounds 1 and 2 late
        _payApp(slots[2], 2);
        circle.settleRound();
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[3]), 1, "no cover for round 2: drawn in full");
        _assertBuckets();
    }

    /// @dev Only rounds past their grace end are late: a deposit after round 1's grace that also completes the
    ///      open round 2 (still in its window) is struck for round 1 only, and round 2 is paid on time.
    function test_CR_01_roundStillInItsWindow_notStruck() public {
        _startCircle(4, 0, 10_000);
        _payApp(slots[1], 1);
        _payApp(slots[2], 1); // slot 4 skips round 1
        _afterGrace(1);
        assertEq(circle.currentRound(), 2, "round 2 open, in its window");
        _deposit(slots[3], 2 * C);
        assertTrue(_late(slots[3], 1));
        assertFalse(_late(slots[3], 2), "round 2 is paid on time");
        circle.settleRound();
        _payApp(slots[0], 2);
        _payApp(slots[2], 2);
        _afterGrace(2);
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[3]), 1);
    }

    /// @dev A deposit pays only the rounds it completes: 1.5c pays round 1 (LATE); round 2 stays short, so the member
    ///      still owes $50 for it and is struck LATE once when it pays, never twice for a round.
    function test_CR_01_partialDeposit_paysOnlyTheRoundsItCompletes() public {
        _overlap();
        _deposit(slots[3], 150e6);
        assertTrue(_late(slots[3], 1));
        assertFalse(_late(slots[3], 2));
        circle.settleRound(); // round 1 drawn in full
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();
        assertEq(circle.amountDue(slots[3], 2), 50e6);
        _payApp(slots[3], 2);
        assertTrue(_late(slots[3], 2));
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[3]), 2);
        _assertBuckets();
    }

    /// @dev The caller's own round inside the walk is skipped when `settleRound` can net it, as `contribute` skips
    ///      it: slot 2 (S_2 = 2c, no collateral) skips round 1; rounds 1, 2 (its own) and 3 are past grace (30-day
    ///      cure). One deposit of 4c pays rounds 1 and 3 late (round 2 is netted from its payout): the strikes of
    ///      the `contribute` path, and no settlement strikes it again.
    function test_CR_01_ownNettableRoundInTheWalk_skipped() public {
        RotatingParams memory p = _params(4, 0, 10_000);
        p.config.roundDuration = LONG_ROUND;
        p.config.cure = 30 days;
        _create(p);
        for (uint256 i; i < 4; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
        for (uint256 r = 1; r <= 3; ++r) {
            _openLong(r);
            for (uint256 i; i < 4; ++i) {
                if (i != 1) _payApp(slots[i], r);
            }
        }
        vm.warp(_graceEnd(3) + 1);
        assertLt(block.timestamp, _graceEnd(1) + circle.cure(), "round 1 is still in its cure");

        uint256 snap = vm.snapshotState();
        _payApp(slots[1], 1);
        _payApp(slots[1], 3);
        assertTrue(_late(slots[1], 1) && _late(slots[1], 3) && !_late(slots[1], 2));
        uint256 viaContribute = reputation.strikeCount(slots[1]);
        vm.revertToState(snap);

        _deposit(slots[1], 4 * C);
        assertTrue(_late(slots[1], 1), "round 1 LATE");
        assertFalse(_late(slots[1], 2), "own round: netted from the payout");
        assertTrue(_late(slots[1], 3), "round 3 LATE");
        assertEq(reputation.strikeCount(slots[1]), viaContribute);
        circle.settleRound();
        circle.settleRound();
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[1]), 2, "no settlement strike");
        _assertBuckets();
    }

    /// @dev A 4-member, 14-day-round, 20-day-cure circle at σ = 100% with no fee, where slot 3 (S_3 = c, no
    ///      security) skips round 1, so round 1 cannot settle; `collateral` is posted by slot `slot`.
    function _blockedRoundOne(uint256 slot, uint256 collateral) internal {
        RotatingParams memory p = _params(4, 0, 10_000);
        p.config.roundDuration = LONG_ROUND;
        p.config.cure = 20 days;
        _create(p);
        for (uint256 i; i < 4; ++i) {
            _join(slots[i], i + 1 == slot ? collateral : 0);
        }
        vm.warp(circle.startTime());
    }

    /// @dev Before the deposit, a round the caller's security already covers in full is consumed, so the next round is
    ///      judged on what is left: slot 4 ($100 collateral, S_4 = 0) is drawn in full for round 1 and skips round 2;
    ///      a $100 deposit after round 2's grace pays round 2 late (and round 1 stays unstruck).
    function test_CR_01_roundAlreadyDrawnBeforeTheDeposit_nextRoundJudgedOnWhatIsLeft() public {
        _blockedRoundOne(4, C);
        _payApp(slots[1], 1);
        assertEq(circle.amountDue(slots[3], 1), 0, "round 1 drawn in full from security");
        _openLong(2);
        _payApp(slots[0], 2);
        vm.warp(_graceEnd(2) + 1);
        assertEq(circle.amountDue(slots[3], 2), C, "round 2 owed from the wallet");

        _deposit(slots[3], C);
        assertFalse(_late(slots[3], 1), "round 1 was paid on time, from security");
        assertTrue(_late(slots[3], 2), "round 2 paid late by the deposit");
        assertEq(reputation.strikeCount(slots[3]), 1);
        _payApp(slots[2], 1);
        _payApp(slots[2], 2);
        circle.settleRound();
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[3]), 1, "both drawn in full at settlement");
        _assertBuckets();
    }

    /// @dev The caller's own nettable round at the start of the walk is skipped before anything is owed: slot 1 (no
    ///      security; round 1 is its own, netted from its payout) skips round 2; a deposit of 4c after round 2's
    ///      grace pays round 2 late and never strikes its own round 1, as `contribute(2)` would.
    function test_CR_01_ownRoundFirstInTheWalk_notStruck() public {
        _blockedRoundOne(0, 0);
        _payApp(slots[1], 1);
        _payApp(slots[3], 1);
        assertEq(circle.amountDue(slots[0], 1), 0, "own round: netted");
        _openLong(2);
        _payApp(slots[3], 2);
        vm.warp(_graceEnd(2) + 1);

        uint256 snap = vm.snapshotState();
        _payApp(slots[0], 2);
        assertTrue(_late(slots[0], 2) && !_late(slots[0], 1));
        vm.revertToState(snap);

        _deposit(slots[0], 4 * C);
        assertFalse(_late(slots[0], 1), "own round: never struck");
        assertTrue(_late(slots[0], 2), "round 2 paid late by the deposit");
        assertEq(reputation.strikeCount(slots[0]), 1);
        _payApp(slots[2], 1);
        _payApp(slots[2], 2);
        circle.settleRound();
        circle.settleRound();
        assertEq(reputation.strikeCount(slots[0]), 1);
        _assertBuckets();
    }

    /// @dev Differential fuzz: slot n (S_n = 0) skips rounds 1..k while the others pay on time; past round k's grace
    ///      (round 1 still in its 30-day cure), one deposit of k·c (+ less than c) gives exactly the strikes that
    ///      paying rounds 1..k through `contribute` gives, and settling the k rounds adds none.
    function testFuzz_CR_01_lateCollateral_matchesTheContributePath(
        uint256 nSeed,
        uint256 kSeed,
        uint16 fee,
        uint256 extra
    ) public {
        uint256 n = bound(nSeed, 3, 6);
        uint256 k = bound(kSeed, 1, n - 1 < 4 ? n - 1 : 4); // (k − 1)·7 days < 30 days: round 1 still in its cure
        RotatingParams memory p = _params(n, uint16(bound(fee, 0, 200)), 10_000);
        p.config.roundDuration = 7 days;
        p.config.grace = 2 days;
        p.config.cure = 30 days;
        _create(p);
        for (uint256 i; i < n; ++i) {
            _join(slots[i], 0);
        }
        address late = slots[n - 1];
        for (uint256 r = 1; r <= k; ++r) {
            vm.warp(circle.startTime() + (r - 1) * 7 days);
            for (uint256 i; i + 1 < n; ++i) {
                _payApp(slots[i], r);
            }
        }
        vm.warp(_graceEnd(k) + 1);

        uint256 snap = vm.snapshotState();
        for (uint256 r = 1; r <= k; ++r) {
            _payApp(late, r);
        }
        uint256 viaContribute = reputation.strikeCount(late);
        assertEq(viaContribute, k);
        vm.revertToState(snap);

        _deposit(late, k * C + bound(extra, 0, C - 1));
        assertEq(
            reputation.strikeCount(late), viaContribute, "one deposit: the strikes of the contribute path"
        );
        for (uint256 r = 1; r <= k; ++r) {
            assertTrue(_late(late, r));
            circle.settleRound();
        }
        assertEq(reputation.strikeCount(late), k, "settling adds no strike");
        _assertBuckets();
    }

    // ================================================================ Finding 2: acknowledged, pinned

    /// @dev Reviewer PoC `test_ZZ_partiallyDrawnDebtor_skipsAndCreditorsLose`, pinned (acknowledged: σ < 100%
    ///      economics, audit 2 R1-02 / A-R2-15, founder decision). Slot 1 (σ = 50%, $150 security after its payout)
    ///      owes $50 of round 2 from its wallet. If slot 3's default stalls round 2, slot 1 keeps the $50 by
    ///      skipping (one COVERED strike, its shortfall written off); paying it moves the $50 to the creditors.
    ///      A member drawn in full (A-R2-05) has no such choice.
    function test_CR_02_partiallyDrawnDebtor_skipKeepsTheWalletPart_pinned() public {
        uint256[4] memory skip = _debtorOutcome(false);
        uint256[4] memory pays = _debtorOutcome(true);
        assertEq(skip[0], 0);
        assertEq(pays[0], 0);
        assertApproxEqAbs(
            pays[1] + pays[3], skip[1] + skip[3] + 50e6, 2, "creditors recover the $50 only if paid"
        );
    }

    function _debtorOutcome(bool slot1Pays) internal returns (uint256[4] memory claims) {
        uint256 snap = vm.snapshotState();
        RotatingParams memory p = _params(4, 0, 10_000);
        p.securityBps[0] = 5_000; // slot 1: S_1 = ceil(50% x 3 x $100) = $150
        _create(p);
        _join(slots[0], 0);
        _join(slots[1], 0);
        _join(slots[2], 0);
        _join(slots[3], 900e6);
        vm.warp(circle.startTime());
        for (uint256 i; i < 4; ++i) {
            _payApp(slots[i], 1);
        }
        circle.settleRound(); // slot 1 netted, holdback $150
        _openRound(2);
        assertEq(circle.amountDue(slots[0], 2), 50e6, "partly drawn: $50 from the wallet");
        if (slot1Pays) _payApp(slots[0], 2);
        _afterCure(2);
        circle.cancelStalled(); // slot 3 defaults
        for (uint256 i; i < 4; ++i) {
            claims[i] = circle.memberState(slots[i]).claim;
        }
        assertEq(
            reputation.struck(slots[0], address(circle), 2, IMHReputation.Reason.COVERED),
            !slot1Pays,
            "COVERED only when it skipped"
        );
        vm.revertToState(snap);
    }
}
