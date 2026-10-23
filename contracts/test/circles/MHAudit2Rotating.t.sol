// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { RotatingFixture } from "./RotatingFixture.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Audit 2, round 1: regressions for `MHRotatingCircle` built from the verifier PoCs in
///         `scratchpad/audit/r1-verify-R1-{02,03,11,12}-*`. Each PoC scenario is replayed and asserts the fixed outcome;
///         acknowledged findings pin the accepted behaviour. n = 6, c = $100, fee 2% unless stated.
contract MHAudit2RotatingTest is RotatingFixture {
    uint256 internal constant N = 6;
    uint16 internal constant FEE = 200;
    address internal keeper = makeAddr("keeper");

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

    function _claims() internal view returns (uint256[] memory c) {
        address[] memory m = circle.members();
        c = new uint256[](m.length);
        for (uint256 i; i < m.length; ++i) {
            c[i] = circle.memberState(m[i]).claim;
        }
    }

    function _honest(uint256 throughRound) internal {
        for (uint256 r = 1; r <= throughRound; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
    }

    /// @dev Pays `round` for every member in `payers` as the app does (`amountDue` only: a recipient's own netted
    ///      round is not paid).
    function _payAllApp(uint256 round, uint256 payers) internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if ((payers >> i) & 1 == 0 || circle.paid(round, m[i])) continue;
            _payApp(m[i], round);
        }
    }

    function _writeOffs(Vm.Log[] memory logs)
        internal
        view
        returns (address[] memory who, uint256[] memory amt)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(circle)
                    && logs[i].topics[0] == IMHRotatingCircle.PositionWrittenOff.selector
            ) {
                ++n;
            }
        }
        who = new address[](n);
        amt = new uint256[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(circle)
                    || logs[i].topics[0] != IMHRotatingCircle.PositionWrittenOff.selector
            ) {
                continue;
            }
            who[n] = address(uint160(uint256(logs[i].topics[1])));
            amt[n++] = abi.decode(logs[i].data, (uint256));
        }
    }

    // ================================================================ R1-02: write-off on a creditor's stall

    /// @dev PoC R1-02 `test_v1_n20_collusion_slot1_plus900_noStrike` (acknowledged; mitigated by the flag): n = 20,
    ///      σ = 50%, fee 0. Slot 1 (paid out in round 1) keeps paying; accomplice slot 20 skips round 2. The cancel
    ///      still writes off slot 1's unsecured $900 without a strike (a wind-down or continuation is a founder
    ///      decision), but `PositionWrittenOff(slot 1, 2, $900)` now flags it for the Trusted-tier gate. The
    ///      creditors' numbers follow audit 2 R1-03 (slot 2's own round-2 payment is refunded at par).
    function test_A2R1_02_n20Collusion_writeOffIsFlagged() public {
        uint256 n = 20;
        _startCircle(n, 0, 5_000);
        _honest(1);
        assertEq(circle.memberState(slots[0]).sec, 950e6, "holdback S_1 = 950");
        _openRound(2);
        assertEq(circle.amountDue(slots[0], 2), 50e6, "slot 1 wallet owes 50 in round 2");
        _payAll(2, _allBut(n));
        _afterCure(2);
        vm.recordLogs();
        vm.prank(keeper);
        circle.cancelStalled();
        (address[] memory who, uint256[] memory amt) = _writeOffs(vm.getRecordedLogs());
        assertEq(who.length, 1, "one written-off position");
        assertEq(who[0], slots[0]);
        assertEq(amt[0], 900e6, "slot 1's unsecured $900");
        _claimAll();
        assertEq(_net(slots[0]), 900e6, "accepted: slot 1 +$900 (pinned)");
        assertEq(reputation.strikeCount(slots[0]), 0, "no strike: the flag is an event");
        assertEq(_net(slots[n - 1]), -100e6, "accomplice -$100");
        assertTrue(reputation.struck(slots[n - 1], address(circle), 2, IMHReputation.Reason.DEFAULT));
        int256 creditors;
        for (uint256 i = 1; i < n - 1; ++i) {
            creditors += _net(slots[i]);
            assertLt(_net(slots[i]), 0, "honest creditors lose (pinned)");
        }
        assertApproxEqAbs(creditors + _net(slots[0]) + _net(slots[n - 1]), 0, 20, "zero-sum at fee 0");
        _assertBuckets();
    }

    /// @dev PoC R1-02 `test_v1_n20_midCircle_fee2`: slot 20 skips round 10; slots 1–9 each keep +$460 with no strike
    ///      (pinned) and each is flagged.
    function test_A2R1_02_midCircle_everyBeneficiaryFlagged() public {
        uint256 n = 20;
        _startCircle(n, FEE, 5_000);
        _honest(9);
        _openRound(10);
        _payAll(10, _allBut(n));
        _afterCure(10);
        vm.recordLogs();
        circle.cancelStalled();
        (address[] memory who,) = _writeOffs(vm.getRecordedLogs());
        assertEq(who.length, 9, "slots 1-9 flagged");
        for (uint256 i; i < 9; ++i) {
            assertEq(who[i], slots[i]);
        }
        _claimAll();
        for (uint256 i; i < 9; ++i) {
            assertEq(_net(slots[i]), 460e6, "pinned");
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        _assertBuckets();
    }

    /// @dev Honest completion leaves everyone at −fee and flags nobody.
    function test_A2R1_02_completion_noWriteOff() public {
        _startCircle(N, FEE, 5_000);
        vm.recordLogs();
        _honest(N);
        (address[] memory who,) = _writeOffs(vm.getRecordedLogs());
        assertEq(who.length, 0);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
    }

    // ================================================================ R1-03: the recipient's own round is circular

    /// @dev σ = 100%; round 1 settled; round 2: slot 3 pays, slots 4–6 never pay; slot 2 (round 2's recipient) pays its
    ///      own round or not.
    function _s2(bool recipientPays) internal {
        _startCircle(N, FEE, 10_000);
        _honest(1);
        _openRound(2);
        _payAll(2, _bit(3) | (recipientPays ? _bit(2) : 0));
        assertEq(circle.paid(2, slots[1]), recipientPays);
        _afterCure(2);
    }

    /// @dev PoC R1-03 `test_sigma100_s2_threeWays` / `test_v1_sigma100_jitEqualsOnTimePayment`: withholding, a
    ///      flash-funded JIT deposit + cancel + claim, and paying on time used to give slot 2 +$100, +$150 and +$150
    ///      (slot 3: +$200, +$150, +$150). All three are now identical: slot 2 +$100, slot 3 +$200.
    function test_A2R1_03_sigma100_recipientsChoiceNoLongerMovesMoney() public {
        uint256 snap = vm.snapshotState();
        int256[][3] memory runs;
        for (uint256 way; way < 3; ++way) {
            _s2(way == 2);
            if (way == 1) {
                _fund(slots[1], C);
                vm.startPrank(slots[1]);
                circle.depositCollateral(C);
                circle.cancelStalled();
                circle.claim();
                vm.stopPrank();
                assertEq(reputation.strikeCount(slots[1]), 0);
            } else {
                vm.prank(keeper);
                circle.cancelStalled();
            }
            _claimAll();
            runs[way] = _nets(N);
            _assertBuckets();
            vm.revertToState(snap);
        }
        for (uint256 i; i < N; ++i) {
            assertEq(runs[1][i], runs[0][i], "JIT deposit == withholding");
            assertEq(runs[2][i], runs[0][i], "paying on time == withholding");
        }
        assertEq(runs[0][1], 100e6, "slot 2");
        assertEq(runs[0][2], 200e6, "slot 3 keeps its larger penalty share");
    }

    /// @dev PoC R1-03 `test_v5_R1_01_propertyBrokenForRecipient` and `test_v3_jitLeverCappedAtC`: the prior-audit R1-01
    ///      property (a JIT deposit changes nobody else's claim) now holds for the stalled round's recipient too, for
    ///      any deposit size.
    function test_A2R1_03_recipientJitDeposit_movesNoOtherClaim() public {
        _s2(false);
        uint256 snap = vm.snapshotState();
        circle.cancelStalled();
        uint256[] memory base = _claims();
        vm.revertToState(snap);
        uint256[2] memory sizes = [C, 10 * C];
        for (uint256 k; k < 2; ++k) {
            _fund(slots[1], sizes[k]);
            vm.prank(slots[1]);
            circle.depositCollateral(sizes[k]);
            circle.cancelStalled();
            uint256[] memory after_ = _claims();
            for (uint256 i; i < N; ++i) {
                assertEq(
                    after_[i],
                    i == 1 ? base[i] + sizes[k] : base[i],
                    "only its own claim moves, by the deposit"
                );
            }
            vm.revertToState(snap);
        }
    }

    /// @dev PoC R1-03 `test_sigma50_D4_recipientPaysVsSkips`, `test_sigma50_D2_recipientPaysVsSkips` and
    ///      `test_sigma50_D4_skipThenJitEqualsPaid`: at σ = 50% paying, skipping, or skipping and then depositing c
    ///      give the same outcome (the amended D4/D2 numbers).
    function test_A2R1_03_sigma50_D4_D2_payOrSkipIdentical() public {
        uint256 snap = vm.snapshotState();
        int256[][3] memory d4;
        for (uint256 way; way < 3; ++way) {
            _startCircle(N, FEE, 5_000);
            _honest(2);
            _openRound(3);
            _payAll(3, way == 0 ? _allBut(5) : _allBut(5) ^ _bit(3));
            _afterCure(3);
            if (way == 2) {
                _fund(slots[2], C);
                vm.prank(slots[2]);
                circle.depositCollateral(C);
            }
            vm.prank(keeper);
            circle.cancelStalled();
            _claimAll();
            d4[way] = _nets(N);
            assertEq(reputation.strikeCount(slots[2]), 0);
            vm.revertToState(snap);
        }
        int256[6] memory spec = [int256(138e6), 138e6, -37_100_000, -55_650_000, -127_600_000, -55_650_000];
        for (uint256 i; i < N; ++i) {
            assertEq(d4[0][i], spec[i], "D4 (amended) when slot 3 pays");
            assertEq(d4[1][i], spec[i], "D4 when slot 3 skips");
            assertEq(d4[2][i], spec[i], "D4 when slot 3 skips then deposits c");
        }

        int256[][2] memory d2;
        for (uint256 way; way < 2; ++way) {
            _startCircle(N, FEE, 5_000);
            _payAll(1, _everyone());
            circle.settleRound();
            for (uint256 r = 2; r <= 3; ++r) {
                _openRound(r);
                _payAll(r, _allBut(1));
                _afterGrace(r);
                circle.settleRound();
            }
            _openRound(4);
            _payAll(4, way == 0 ? _allBut(1) : _allBut(1) ^ _bit(4));
            _afterCure(4);
            vm.prank(keeper);
            circle.cancelStalled();
            _claimAll();
            d2[way] = _nets(N);
            vm.revertToState(snap);
        }
        for (uint256 i; i < N; ++i) {
            assertEq(d2[1][i], d2[0][i], "D2: paying or skipping round 4 is the same for everyone");
        }
        assertEq(d2[0][3], -112_909_091, "D2 (amended) slot 4");
        assertEq(d2[0][4], -150_545_455, "D2 (amended) slot 5");
    }

    /// @dev Extension of the prior-audit `testFuzz_R1_01_jitMovesNoOtherClaim` asked for by R1-03: the stalled
    ///      round's recipient may withhold or pay its own round, and the actor may be that recipient. Any deposit,
    ///      free-security withdrawal or later-round prepayment by any non-defaulter changes nobody else's claim.
    function testFuzz_A2R1_03_recipientActionsMoveNoOtherClaim(
        uint256 nSeed,
        uint256 stallSeed,
        uint256 actorSeed,
        uint256 actionSeed,
        uint256 amountSeed,
        uint256 colSeed
    ) public {
        (uint256 n, uint256 s) = _fuzzStall(nSeed, stallSeed, colSeed);
        // The actor: the recipient half the time, otherwise any other non-defaulter.
        uint256 j = actorSeed % 2 == 0 ? s - 1 : bound(actorSeed >> 1, 0, n - 2);
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(circle).call(abi.encodeCall(circle.cancelStalled, ()));
        vm.assume(ok);
        uint256[] memory base = _claims();
        vm.revertToState(snap);

        (bool acted, int256 moved) = _fuzzAct(j, s, actionSeed % 3, amountSeed, n);
        if (!acted) return;
        circle.cancelStalled();
        uint256[] memory after_ = _claims();
        for (uint256 i; i < n; ++i) {
            if (i == j) {
                assertEq(
                    int256(after_[i]) - int256(base[i]), moved, "the actor's claim moves by what it moved"
                );
            } else {
                assertEq(after_[i], base[i], "another member's claim moved");
            }
        }
        _assertBuckets();
    }

    /// @dev σ = 100%, n in [3, 8], random free collateral; rounds before `s` settle; round `s` is paid by everyone but
    ///      slot n (no collateral: the defaulter), the recipient paying its own round or not; time past the cure.
    function _fuzzStall(uint256 nSeed, uint256 stallSeed, uint256 colSeed)
        internal
        returns (uint256 n, uint256 s)
    {
        n = bound(nSeed, 3, 8);
        s = bound(stallSeed, 2, n - 1);
        _create(_params(n, FEE, 10_000));
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(colSeed, i)));
            _join(slots[i], i + 1 < n && h % 3 == 0 ? bound(h >> 8, 1, n * 100) * K.CENT * 100 : 0);
        }
        vm.warp(circle.startTime());
        _honest(s - 1);
        _openRound(s);
        _payAll(s, colSeed % 2 == 0 ? _allBut(n) : _allBut(n) ^ _bit(s));
        _afterCure(s);
    }

    /// @dev Member `j` deposits collateral, withdraws free security, or prepays round s + 1 (paying round s first
    ///      unless it is its own). Returns whether it acted and the USDC it moved in (+) or out (−).
    function _fuzzAct(uint256 j, uint256 s, uint256 action, uint256 amountSeed, uint256 n)
        internal
        returns (bool acted, int256 moved)
    {
        address a = slots[j];
        if (action == 0) {
            uint256 y = bound(amountSeed, 1, 10 * n * C);
            _fund(a, y);
            vm.prank(a);
            circle.depositCollateral(y);
            // forge-lint: disable-next-line(unsafe-typecast)
            return (true, int256(y));
        }
        if (action == 1) {
            uint256 sec = circle.memberState(a).sec;
            uint256 req = circle.requiredSecurity(a);
            if (sec <= req) return (false, 0);
            uint256 w = bound(amountSeed, 1, sec - req);
            vm.prank(a);
            (bool ok,) = address(circle).call(abi.encodeCall(circle.withdrawSecurity, (w)));
            // forge-lint: disable-next-line(unsafe-typecast)
            return (ok, -int256(w)); // not ok: the R1-06 lock (unpaid past grace)
        }
        uint256 r = s + 1;
        if (r > circle.currentRound() || circle.paid(r, a)) return (false, 0);
        if (!circle.paid(s, a) && j + 1 != s) moved = int256(_pay(a, s));
        moved += int256(_pay(a, r));
        return (true, moved);
    }

    // ================================================================ R1-19: amountDue and the LATE strike

    /// @dev R1-19: nothing is due on a recipient's own netted round, and paying it anyway after grace records no LATE
    ///      strike (the payment is circular). A recipient that cannot be netted (slot 1 at σ = 100% with a fee and no
    ///      collateral) is asked for its part and struck if late, as before.
    function test_A2R1_19_ownRound_nothingDue_noLateStrike() public {
        _startCircle(N, FEE, 10_000);
        _honest(1);
        _openRound(2);
        assertEq(circle.amountDue(slots[1], 2), 0, "slot 2's own round is netted");
        assertEq(circle.amountDue(slots[2], 2), C);
        _payAll(2, _allBut(2));
        _afterGrace(2);
        _fund(slots[1], C);
        vm.prank(slots[1]);
        circle.contribute(2, C); // a late, voluntary payment of its own round
        assertEq(reputation.strikeCount(slots[1]), 0, "no LATE strike");
        circle.settleRound();
        assertEq(circle.nextSettle(), 3);

        _startCircle(3, FEE, 10_000);
        assertEq(circle.amountDue(slots[0], 1), C, "slot 1 cannot be netted (94 < 100): its part is due");
        _afterGrace(1);
        _fund(slots[0], C);
        vm.prank(slots[0]);
        circle.contribute(1, C);
        assertTrue(reputation.struck(slots[0], address(circle), 1, IMHReputation.Reason.LATE));
    }

    // ================================================================ R1-11: rounds are paid in order

    function _toRound4Open(uint16 sigma) internal {
        _startCircle(N, 0, sigma);
        _honest(2);
        _openRound(3);
        _payAll(3, _allBut(6));
        _openRound(4);
    }

    /// @dev PoC R1-11 `test_A_findingReproduces`: slot 6 used to book its $100 to round 4 instead of round 3, stall the
    ///      circle and take a DEFAULT strike with its money still in the circle. The out-of-order payment is now
    ///      refused (and `amountDue` reports 0 for it), so the app pays round 3 first and the circle continues.
    function test_A2R1_11_laterRoundBeforeTheSettlingOne_isRefused() public {
        _toRound4Open(10_000);
        assertEq(circle.nextSettle(), 3);
        assertEq(circle.amountDue(slots[5], 3), C);
        assertEq(circle.amountDue(slots[5], 4), 0, "round 4 is not payable before round 3");
        _fund(slots[5], C);
        vm.prank(slots[5]);
        vm.expectRevert(IMHRotatingCircle.OutOfOrder.selector);
        circle.contribute(4, C);
        _payApp(slots[5], 3);
        assertEq(circle.amountDue(slots[5], 4), C, "now round 4 is due");
        _payApp(slots[5], 4);
        circle.settleRound();
        assertEq(circle.nextSettle(), 4);
        assertEq(reputation.strikeCount(slots[5]), 0);
        _payAllApp(4, _everyone());
        circle.settleRound();
        assertEq(circle.nextSettle(), 5, "its round-4 payment counted");
    }

    /// @dev PoC R1-11 `test_D_cureInsideCure_lateOnly`: a late payment of round 3 (LATE strike) then round 4.
    function test_A2R1_11_latePaymentThenNextRound() public {
        _toRound4Open(10_000);
        _afterGrace(3);
        _payApp(slots[5], 3);
        assertTrue(reputation.struck(slots[5], address(circle), 3, IMHReputation.Reason.LATE));
        _payApp(slots[5], 4);
        circle.settleRound();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
    }

    /// @dev PoC R1-11 `test_F_sigma50_collateralDamage`: at σ = 50% the mis-booking can no longer happen; a member that
    ///      really does not pay round 3 is the defaulter, with nothing of its own in a later pot.
    function test_A2R1_11_sigma50_defaulterHasNothingInLaterPots() public {
        _toRound4Open(5_000);
        _fund(slots[5], C);
        vm.prank(slots[5]);
        vm.expectRevert(IMHRotatingCircle.OutOfOrder.selector);
        circle.contribute(4, C);
        _afterCure(3);
        circle.cancelStalled();
        assertEq(circle.memberState(slots[5]).paidRounds, 2, "the defaulter paid exactly the settled rounds");
        assertTrue(reputation.struck(slots[5], address(circle), 3, IMHReputation.Reason.DEFAULT));
    }

    /// @dev The order rule skips a member's own round when `settleRound` can net it, and a fully drawn round is
    ///      satisfied with a zero pull: explicitly, or (audit 2 R2-03) by `contribute` for the next round, which
    ///      draws it first.
    function test_A2R1_11_ownRoundSkipped_fullyDrawnZeroPull() public {
        _startCircle(N, 0, 10_000);
        _honest(1); // slot 1 paid out, σ = 100%: its later rounds are drawn from its holdback
        _openRound(2);
        _openRound(3); // round 2 still in grace, round 3 open
        // Slot 2 (round 2's recipient) prepays round 3 without paying its own round 2.
        _payApp(slots[1], 3);
        assertTrue(circle.paid(3, slots[1]));
        // Slot 1 is fully drawn for round 2: an explicit zero pull satisfies it.
        assertEq(circle.amountDue(slots[0], 2), 0);
        vm.prank(slots[0]);
        assertEq(circle.contribute(2, 0), 0, "zero pull");
        // Slot 3 (not paid out, no collateral) owes c from its wallet for round 2, so round 3 stays out of order
        // for it until round 2 is paid.
        assertEq(circle.amountDue(slots[2], 3), 0);
        vm.prank(slots[2]);
        vm.expectRevert(IMHRotatingCircle.OutOfOrder.selector);
        circle.contribute(3, C);
        // Slot 1 then pays round 3 (round 2 is satisfied).
        vm.prank(slots[0]);
        assertEq(circle.contribute(3, 0), 0);

        // Audit 2 R2-03: slot 1 of a fresh circle pays round 3 without the zero-pull call for round 2.
        _startCircle(N, 0, 10_000);
        _honest(1);
        _openRound(3);
        assertEq(circle.amountDue(slots[0], 2), 0, "fully drawn");
        assertEq(circle.amountDue(slots[0], 3), 0, "fully drawn as well, after round 2's draw");
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Contributed(slots[0], 2, 0, C, false); // round 2 drawn first
        vm.prank(slots[0]);
        assertEq(circle.contribute(3, 0), 0);
        assertTrue(circle.paid(2, slots[0]) && circle.paid(3, slots[0]));
    }

    // ================================================================ R1-12: round-2 fixes, ported regressions

    /// @dev Kills mutant R06 (`_required` R2-05 line removed). σ = 50%, slot 1 posts $500, its round-1 part is drawn
    ///      (sec 400), it is paid out and has not paid round 2: the requirement is ceil(σ·4·c) + c = $300.
    function test_A2R1_12_R2_05_paidOutRequirementIncludesOpenRound() public {
        uint256[] memory col = new uint256[](1);
        col[0] = 500e6;
        _startCircle(N, FEE, 5_000, col);
        _payAll(1, _everyone());
        circle.settleRound();
        assertEq(circle.memberState(slots[0]).sec, 400e6);
        assertEq(circle.requiredSecurity(slots[0]), 300e6, "R2-05 requirement");
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(101e6);
        vm.prank(slots[0]);
        circle.withdrawSecurity(100e6);
    }

    /// @dev Kills mutant R04 (R2-13 reverted): a Guardian extension does not lift the R1-06 withdrawal lock.
    function test_A2R1_12_R2_13_extensionDoesNotLiftWithdrawLock() public {
        uint256[] memory col = new uint256[](3);
        col[2] = 150e6; // slot 3, S_3 = 0
        _startCircle(3, FEE, 10_000, col);
        _payAll(1, 3); // slots 1 and 2 pay round 1; slot 3 does not
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        vm.warp(circle.startTime() + ROUND + GRACE + 1); // past the un-extended grace end only
        vm.prank(slots[2]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(60e6);
    }

    /// @dev Kills mutant R08 (R2-08 removed): on a stall cancellation a coverable non-defaulter gets COVERED, the
    ///      uncoverable member DEFAULT.
    function test_A2R1_12_R2_08_cancelStalledStrikesCoveredMember() public {
        uint256[] memory col = new uint256[](4);
        col[1] = 250e6; // slot 2: S_2 = 200, draw 50 < c, sec 250 >= c: coverable
        _startCircle(4, FEE, 10_000, col);
        _payAll(1, 5); // slots 1 and 3 pay; slots 2 and 4 do not
        _afterCure(1);
        circle.cancelStalled();
        assertTrue(reputation.struck(slots[3], address(circle), 1, IMHReputation.Reason.DEFAULT));
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.COVERED));
        assertFalse(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.DEFAULT));
        _assertBuckets();
    }

    /// @dev Kills mutant A06 (R2-11 removed): while USDC blacklists the circle nobody can pay it, so no stall runs.
    function test_A2R1_12_R2_11_blacklistedCircle_noStall() public {
        _startCircle(3, FEE, 10_000);
        _payAll(1, 3);
        usdc.setBlacklisted(address(circle), true);
        _afterCure(1);
        vm.expectRevert(IMHCircle.CircleBlacklisted.selector);
        circle.cancelStalled();
        assertEq(reputation.strikeCount(slots[2]), 0);
        usdc.setBlacklisted(address(circle), false);
        circle.cancelStalled();
        assertTrue(reputation.struck(slots[2], address(circle), 1, IMHReputation.Reason.DEFAULT));
    }

    // ================================================================ R1-20: acknowledged (pinned)

    /// @dev R1-20 (acknowledged): a round-1 stall costs the staller only a strike (E = 0, penalty 0) and freezes
    ///      everyone's money for round + grace + cure; the Guardian can end it early while `nextSettle == 1`.
    function test_A2R1_20_pinned_round1Stall_freeExceptTheStrike() public {
        uint256[] memory col = new uint256[](1);
        col[0] = 500e6;
        uint256 snap = vm.snapshotState();
        _startCircle(N, FEE, 10_000, col);
        _payAll(1, _allBut(6));
        _afterGrace(1);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelStalled();
        _afterCure(1);
        circle.cancelStalled();
        _claimAll();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), 0, "nobody gains or loses");
        }
        assertEq(reputation.strikeCount(slots[5]), 1, "the staller's only cost");
        vm.revertToState(snap);

        _startCircle(N, FEE, 10_000, col);
        _payAll(1, _allBut(6));
        _afterGrace(1);
        vm.prank(guardian);
        circle.guardianCancel(); // runbook: end the freeze as soon as the gap cannot be covered
        _claimAll();
        assertEq(_net(slots[0]), 0);
    }
}
