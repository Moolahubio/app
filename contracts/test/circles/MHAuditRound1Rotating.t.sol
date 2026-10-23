// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RotatingFixture } from "./RotatingFixture.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Audit round 1 regressions for `MHRotatingCircle`, built from the verifiers' PoCs (scratchpad
///         `audit/r1-verify-R1-0{1,2,6,7}-*`). Each PoC scenario is replayed and now asserts the fixed outcome.
///         Spec D3/D4 setup unless stated: n = 6, c = $100, fee 2% (fee $12 per payout). Expected numbers were
///         derived independently with an integer Python model of the amended rules (`scratchpad/sim/rot_r1.py`).
contract MHAuditRound1RotatingTest is RotatingFixture {
    uint256 internal constant N = 6;
    uint16 internal constant FEE = 200;
    address internal keeper = makeAddr("keeper");

    function _allBut(uint256 slot) internal pure returns (uint256) {
        // forge-lint: disable-next-line(incorrect-shift)
        return type(uint256).max ^ (1 << (slot - 1));
    }

    /// @dev D3 up to the stall: rounds 1–2 settled, round 3 paid by all but slot 5, time inside the cure window.
    function _d3ToCure(uint16 sigma, uint256[] memory collateral) internal {
        _startCircle(N, FEE, sigma, collateral);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _openRound(3);
        _payAll(3, _allBut(5));
        _afterGrace(3);
    }

    function _deposit(address who, uint256 amount) internal {
        _fund(who, amount);
        vm.prank(who);
        circle.depositCollateral(amount);
    }

    function _claims() internal view returns (uint256[] memory c) {
        address[] memory m = circle.members();
        c = new uint256[](m.length);
        for (uint256 i; i < m.length; ++i) {
            c[i] = circle.memberState(m[i]).claim;
        }
    }

    function _nets() internal view returns (int256[6] memory nets) {
        for (uint256 i; i < N; ++i) {
            nets[i] = _net(slots[i]);
        }
    }

    // ================================================================ R1-01: free security never moves claims

    /// @dev Baseline (amended D3, audit 2 R1-03: slot 3's own round-3 payment is refunded at par and its E is 200,
    ///      so the penalty splits 2:3:3): the claims every JIT test below compares against.
    function _d3Claims() internal pure returns (uint256[6] memory) {
        return [uint256(0), 0, 325_000_000, 337_500_000, 100_000_000, 337_500_000];
    }

    /// @dev PoC R1-01 (verifier 2) `test_V_jitCollateral_duringCure_noBatching`: slot 6 parks $1,000 of free
    ///      collateral during the cure window, a keeper cancels. Before the fix slot 6 took +$67.57 and slots 3/4
    ///      fell to +$15.59. Now the deposit comes back at par outside the pool and every other claim is unchanged.
    function test_R1_01_jitCollateralDuringCure_isRefundedAtPar_othersUnchanged() public {
        _d3ToCure(10_000, new uint256[](0));
        _deposit(slots[5], 1_000e6);
        _afterCure(3);
        vm.prank(keeper);
        circle.cancelStalled();
        uint256[6] memory base = _d3Claims();
        for (uint256 i; i < N; ++i) {
            assertEq(circle.memberState(slots[i]).claim, i == 5 ? base[i] + 1_000e6 : base[i], "claim");
        }
        _claimAll();
        assertEq(_net(slots[5]), 37_500_000, "slot 6: its honest +$37.50, nothing more");
        assertEq(_net(slots[2]), 25_000_000, "slot 3 keeps its compensation");
        assertEq(_net(slots[4]), -100e6, "the defaulter pays $100");
        _assertBuckets();
    }

    /// @dev PoC R1-01 `test_sniping_atomic_sameBlock_returnsPrincipal` / `test_V_jitCollateral_sameTx_largeCapital`:
    ///      $1M of flash capital deposited, cancel, claim in one frame now returns only slot 6's own position.
    function test_R1_01_flashCollateralSameTx_earnsOnlyOwnPosition() public {
        _d3ToCure(10_000, new uint256[](0));
        _afterCure(3);
        uint256 y = 1_000_000e6;
        _fund(slots[5], y);
        uint256 before = usdc.balanceOf(slots[5]);
        vm.startPrank(slots[5]);
        circle.depositCollateral(y);
        circle.cancelStalled();
        circle.claim();
        vm.stopPrank();
        assertEq(
            usdc.balanceOf(slots[5]) - before, 337_500_000, "deposit back at par + its honest claim only"
        );
        _claimAll();
        assertEq(_net(slots[2]), 25_000_000, "slot 3 untouched (was +$0.03 before the fix)");
        assertEq(_net(slots[0]), -12e6, "slot 1: its fee, as on completion");
        _assertBuckets();
    }

    /// @dev PoC R1-01 `test_sybil_pairRecyclesPenalty` / `test_V_sybilPair`: defaulter slot 5 + accomplice slot 6
    ///      net −$62.50 together, as with no accomplice (was −$0.06).
    function test_R1_01_sybilPairCannotRecyclePenalty() public {
        _d3ToCure(10_000, new uint256[](0));
        _afterCure(3);
        _fund(slots[5], 1_000_000e6);
        vm.startPrank(slots[5]);
        circle.depositCollateral(1_000_000e6);
        circle.cancelStalled();
        vm.stopPrank();
        _claimAll();
        assertEq(
            _net(slots[4]) + _net(slots[5]), -100e6 + 37_500_000, "pair: the full penalty, less its share"
        );
    }

    /// @dev PoC R1-01 `test_haircut_*` / `test_V_haircut_*` (σ = 50%, D4 + slot 6 joined with $1,000): before the
    ///      fix the keeper-first and withdraw-first orders differed by about $50 per creditor. Now both give the
    ///      D4 numbers for everyone, slot 6 included.
    function test_R1_01_haircut_independentOfWithdrawOrder() public {
        uint256[] memory col = new uint256[](N);
        col[5] = 1_000e6;
        // D4 as amended by audit 2 R1-03.
        int256[6] memory expected =
            [int256(138e6), 138e6, -37_100_000, -55_650_000, -127_600_000, -55_650_000];
        uint256 snap = vm.snapshotState();
        for (uint256 order; order < 2; ++order) {
            _d3ToCure(5_000, col);
            assertEq(circle.memberState(slots[5]).sec, 800e6, "$800 still held");
            if (order == 1) {
                vm.prank(slots[5]);
                circle.withdrawSecurity(700e6);
            }
            _afterCure(3);
            vm.prank(keeper);
            circle.cancelStalled();
            _claimAll();
            int256[6] memory nets = _nets();
            for (uint256 i; i < N; ++i) {
                assertEq(nets[i], expected[i], order == 0 ? "keeper first" : "withdraw first");
            }
            _assertBuckets();
            vm.revertToState(snap);
        }
    }

    /// @dev PoC R1-01 `test_V_sigma100_honestFreeCollateralSkewsPenalty`: slot 6 posted $1,000 at join (S_6 = 0,
    ///      all free). It used to take a 4.6× share of the penalty; now its free collateral comes back at par and the
    ///      penalty splits by contributions only.
    function test_R1_01_honestFreeCollateralAtJoin_doesNotSkewPenalty() public {
        uint256[] memory col = new uint256[](N);
        col[5] = 1_000e6;
        _d3ToCure(10_000, col);
        _afterCure(3);
        circle.cancelStalled();
        assertEq(circle.memberState(slots[5]).claim, 700e6 + 337_500_000, "free $700 at par + D3 claim");
        assertEq(circle.memberState(slots[2]).claim, 325_000_000);
        _claimAll();
        assertEq(_net(slots[5]), 37_500_000);
        assertEq(_net(slots[2]), 25_000_000);
    }

    /// @dev A creditor prepaying the next open round just before the cancel no longer moves the penalty weights:
    ///      the prepayment is returned to its security and refunded at par.
    function test_R1_01_prepaymentBeforeCancel_isRefundedAtPar_othersUnchanged() public {
        _d3ToCure(10_000, new uint256[](0));
        _afterCure(3);
        assertEq(circle.currentRound(), 4, "round 4 is open");
        _pay(slots[2], 4);
        circle.cancelStalled();
        uint256[6] memory base = _d3Claims();
        for (uint256 i; i < N; ++i) {
            assertEq(circle.memberState(slots[i]).claim, i == 2 ? base[i] + C : base[i], "claim");
        }
        _claimAll();
        assertEq(_net(slots[2]), 25_000_000);
        _assertBuckets();
    }

    /// @dev Fuzz (σ = 100%): any non-defaulter depositing collateral, withdrawing free security or prepaying a later
    ///      round right before `cancelStalled` changes nobody else's claim by a single unit, and its own claim by
    ///      exactly the USDC it moved.
    function testFuzz_R1_01_jitMovesNoOtherClaim(
        uint256 nSeed,
        uint256 stallSeed,
        uint256 actorSeed,
        uint256 actionSeed,
        uint256 amountSeed,
        uint256 colSeed
    ) public {
        uint256 n = bound(nSeed, 3, 8);
        uint256 s = bound(stallSeed, 1, n - 1); // stalled round; slot n (pre-payout, no collateral) defaults
        RotatingParams memory p = _params(n, FEE, 10_000);
        _create(p);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(colSeed, i)));
            _join(slots[i], i + 1 < n && h % 3 == 0 ? bound(h >> 8, 1, n * 100) * K.CENT * 100 : 0);
        }
        vm.warp(circle.startTime());
        for (uint256 r = 1; r < s; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _openRound(s);
        _payAll(s, _allBut(n));
        _afterCure(s);

        uint256 j = bound(actorSeed, 0, n - 2); // never the defaulter
        address a = slots[j];
        uint256 snap = vm.snapshotState();
        circle.cancelStalled();
        uint256[] memory base = _claims();
        vm.revertToState(snap);

        int256 moved; // USDC the actor moved into (+) or out of (−) the circle
        uint256 action = actionSeed % 3;
        if (action == 0) {
            uint256 y = bound(amountSeed, 1, 10 * n * C);
            _deposit(a, y);
            // forge-lint: disable-next-line(unsafe-typecast)
            moved = int256(y); // y <= 10·n·C < 2^255
        } else if (action == 1) {
            uint256 sec = circle.memberState(a).sec;
            uint256 req = circle.requiredSecurity(a);
            if (sec <= req) return;
            uint256 w = bound(amountSeed, 1, sec - req);
            vm.prank(a);
            circle.withdrawSecurity(w);
            // forge-lint: disable-next-line(unsafe-typecast)
            moved = -int256(w); // w <= sec < 2^80
        } else {
            uint256 r = s + 1;
            if (r > circle.currentRound() || circle.paid(r, a)) return;
            // Audit 2 R1-11: rounds in order. A fully drawn member satisfies round s first with a zero pull
            // (which `cancelStalled` would have covered anyway).
            if (!circle.paid(s, a)) moved = int256(_pay(a, s));
            moved += int256(_pay(a, r));
        }
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

    // ================================================================ R1-02: fees on engineered defaults

    function _startC(uint256 n, uint256 c) internal {
        RotatingParams memory p = _params(n, FEE, 10_000);
        p.config.contribution = c;
        _create(p);
        for (uint256 i; i < n; ++i) {
            _join(slots[i], 0);
        }
        vm.warp(circle.startTime());
    }

    /// @dev PoC R1-02 `test_lastRoundStall_voidsAllFees_*` / `test_exploit_*`: slot n skipping round n used to
    ///      cancel the circle and refund every fee (group $0, treasury $0). Its own part is now netted from its
    ///      payout (R1-07), the circle completes, and the treasury gets every fee.
    function test_R1_02_lastRoundSkip_isNetted_treasuryGetsEveryFee() public {
        uint256[2] memory ns = [uint256(6), 20];
        uint256[2] memory cs = [uint256(100e6), 500e6];
        uint256 snap = vm.snapshotState();
        for (uint256 k; k < 2; ++k) {
            uint256 n = ns[k];
            uint256 c = cs[k];
            uint256 fee = n * c * FEE / K.BPS;
            _startC(n, c);
            for (uint256 r = 1; r < n; ++r) {
                _openRound(r);
                _payAll(r, _everyone());
                circle.settleRound();
            }
            _openRound(n);
            assertEq(circle.amountDue(slots[n - 1], n), 0, "slot n owes nothing: netted (audit 2 R1-19)");
            vm.expectEmit(true, true, false, true, address(circle));
            emit IMHRotatingCircle.OwnContributionNetted(slots[n - 1], n, c);
            circle.settleRound();
            assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
            _withdrawAllSecurity();
            circle.flushFees();
            for (uint256 i; i < n; ++i) {
                // forge-lint: disable-next-line(unsafe-typecast)
                assertEq(_net(slots[i]), -int256(fee), "every member nets -fee");
                assertEq(reputation.strikeCount(slots[i]), 0, "no strike");
            }
            assertEq(usdc.balanceOf(treasury), n * fee, "treasury: every fee");
            assertEq(usdc.balanceOf(address(circle)), 0);
            vm.revertToState(snap);
        }
    }

    /// @dev An engineered stall one round earlier (slot 6 stops at round 5) keeps the four paid-out members' fees
    ///      for the treasury; they end at −$12 as on completion. Before the fix every fee went back to the group.
    function test_R1_02_engineeredStall_paidOutFeesReachTreasury() public {
        _startCircle(N, FEE, 10_000);
        for (uint256 r = 1; r <= 4; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _openRound(5);
        _payAll(5, _allBut(6));
        _afterCure(5);
        circle.cancelStalled();
        assertEq(circle.feeEscrow(), 48e6, "4 fees kept");
        _claimAll();
        circle.flushFees();
        int256[6] memory expected = [int256(-12e6), -12e6, -12e6, -12e6, 100e6, -100e6];
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), expected[i]);
        }
        assertEq(usdc.balanceOf(treasury), 48e6);
        _assertBuckets();
    }

    /// @dev Fees fold back only up to the creditors' shortfall: at σ = 98% the two paid-out debtors are $6 short
    ///      each, so $12 of the $24 escrow covers them and $12 stays for the treasury; creditors are made whole.
    function test_R1_02_feesFoldBackOnlyUpToTheShortfall() public {
        _d3ToCure(9_800, new uint256[](0));
        _afterCure(3);
        circle.cancelStalled();
        assertEq(circle.feeEscrow(), 12e6, "half the escrow covered the shortfall");
        _claimAll();
        circle.flushFees();
        // Audit 2 R1-03: slot 3's own round-3 payment is refunded at par; the penalty splits 2:3:3.
        int256[6] memory expected = [int256(-6e6), -6e6, 25e6, 37_500_000, -100e6, 37_500_000];
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), expected[i]);
        }
        assertEq(usdc.balanceOf(treasury), 12e6);
    }

    // ================================================================ R1-06: defaulter's penalty base

    function _stallRound1(uint16 sigma, uint256 defaulterSlot, uint256 collateral) internal {
        _startCircle(N, FEE, sigma);
        _deposit(slots[defaulterSlot - 1], collateral);
        _openRound(1);
        _payAll(1, _allBut(defaulterSlot));
    }

    /// @dev PoC R1-06 `test_R106_reproduce`: σ = 100%, slot 6 posts $90 and never pays round 1. After grace it can
    ///      no longer pull its security out, so the creditors get the $90 penalty. Audit 2 R1-03: slot 1's own
    ///      round-1 payment is circular (refunded at par, E = 0), so slots 2–5 share it: +$22.50 each.
    function test_R1_06_defaulterCannotWithdrawAfterGrace() public {
        _stallRound1(10_000, 6, 90e6);
        assertEq(circle.requiredSecurity(slots[5]), 0, "all of it is free");
        _afterGrace(1);
        vm.prank(slots[5]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(90e6);
        vm.prank(slots[5]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(1);
        _afterCure(1);
        vm.prank(slots[5]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(90e6);
        circle.cancelStalled();
        _claimAll();
        assertEq(_net(slots[5]), -90e6, "the defaulter loses min(E, c) = $90");
        assertEq(_net(slots[0]), 0, "the recipient's own round is not a credit");
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(_net(slots[i]), 22_500_000, "each creditor +$22.50");
        }
        assertEq(reputation.strikesByReason(slots[5], IMHReputation.Reason.DEFAULT), 1);
        _assertBuckets();
    }

    /// @dev PoC R1-06 `test_R106_sigma50_slotNminus1_partial`: σ = 50%, slot 5 (S_5 = $50) posts $90; the $40
    ///      above S_5 can no longer be withdrawn after grace, so the penalty stays $90.
    function test_R1_06_sigma50_partialWithdrawBlocked() public {
        _stallRound1(5_000, 5, 90e6);
        assertEq(circle.requiredSecurity(slots[4]), 50e6);
        _afterCure(1);
        vm.prank(slots[4]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(40e6);
        circle.cancelStalled();
        _claimAll();
        assertEq(_net(slots[4]), -90e6);
        assertEq(_net(slots[0]), 0, "the recipient's own round is not a credit (audit 2 R1-03)");
        for (uint256 i = 1; i < N; ++i) {
            if (i != 4) assertEq(_net(slots[i]), 22_500_000);
        }
    }

    /// @dev The restriction is narrow: before grace, after paying the round, or while staying at or above c, free
    ///      security still comes out at par.
    function test_R1_06_withdrawStillAllowedWhenNotADefaulter() public {
        _startCircle(N, FEE, 10_000);
        _deposit(slots[5], 300e6); // S_6 = 0: all free
        _openRound(1);
        vm.prank(slots[5]);
        circle.withdrawSecurity(50e6); // inside round 1: fine
        _afterGrace(1);
        vm.prank(slots[5]);
        circle.withdrawSecurity(150e6); // unpaid but keeps sec == c: fine
        assertEq(circle.memberState(slots[5]).sec, C);
        vm.prank(slots[5]);
        vm.expectRevert(IMHCircle.InsufficientSecurity.selector);
        circle.withdrawSecurity(1);
        _deposit(slots[5], 50e6);
        _pay(slots[5], 1); // pays round 1 (draw c): now it may empty its security
        vm.prank(slots[5]);
        circle.withdrawSecurity(50e6);
        assertEq(circle.memberState(slots[5]).sec, 0);
    }

    // ================================================================ R1-07: recipient that cannot pay its round

    /// @dev PoC R1-07 `test_blacklistBeforeOwnRound_forcesCancel`: slot 3 is blacklisted before paying round 3.
    ///      Its own part is now netted from its payout (queued, since it is blacklisted); the circle completes and
    ///      everyone nets −$12, with no strike. Before the fix the circle was cancelled and slot 3 lost $100.
    function test_R1_07_blacklistedRecipient_isNetted_circleCompletes() public {
        _startCircle(N, FEE, 10_000);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        usdc.blacklist(slots[2]);
        _openRound(3);
        _payAll(3, _allBut(3));
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.OwnContributionNetted(slots[2], 3, C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.RoundSettled(3, slots[2], 600e6, 12e6, 300e6, 188e6);
        circle.settleRound();
        assertEq(circle.owed(slots[2]), 188e6, "payout net of its own $100, queued");
        for (uint256 r = 4; r <= N; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        _withdrawAllSecurity();
        circle.flushFees();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), -12e6, "everyone nets -fee");
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        usdc.unBlacklist(slots[2]);
        vm.prank(slots[2]);
        circle.claimOwed();
        _assertBuckets();
    }

    /// @dev PoC R1-07 `test_blacklistSlot1BeforeRound1_*`: slot 1 can be netted only when its payout covers c. At
    ///      fee 0, n = 3, σ = 100% it does (300 − 200 holdback = 100); at fee 2% it does not (94 < 100), so without
    ///      collateral the round still stalls and the Guardian or `cancelStalled` unwinds it (documented limit).
    function test_R1_07_slot1_nettedOnlyIfItsPayoutCoversC() public {
        uint256 snap = vm.snapshotState();
        _startCircle(3, 0, 10_000);
        usdc.blacklist(slots[0]);
        _payAll(1, _allBut(1));
        circle.settleRound();
        assertEq(circle.nextSettle(), 2, "netted: 100 - 100 = 0 cash");
        vm.revertToState(snap);

        _startCircle(3, FEE, 10_000);
        usdc.blacklist(slots[0]);
        _payAll(1, _allBut(1));
        _afterGrace(1);
        vm.expectRevert(IMHCircle.RoundShort.selector);
        circle.settleRound();
        _afterCure(1);
        circle.cancelStalled();
        assertTrue(reputation.struck(slots[0], address(circle), 1, IMHReputation.Reason.DEFAULT));
    }

    // ================================================================ R1-32: test gap

    /// @dev Mutant R47 (depositCollateral allowed once ended) survived the suite; this kills it.
    function test_R1_32_depositCollateral_revertsOnceEnded() public {
        _startCircle(2, 0, 10_000);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        _fund(slots[0], 1e6);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.depositCollateral(1e6);

        _startCircle(2, 0, 10_000);
        vm.prank(guardian);
        circle.guardianCancel();
        _fund(slots[0], 1e6);
        vm.prank(slots[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.depositCollateral(1e6);
    }
}
