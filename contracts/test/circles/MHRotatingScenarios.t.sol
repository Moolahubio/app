// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { RotatingFixture } from "./RotatingFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.4 worked example and default scenarios D1–D4 with the spec's exact numbers, the §4.7 regressions
///         R1, R4 and R8, the n = 50 gas bound, and fuzzed §4.7 rotating properties. n = 6, c = $100, fee 2%
///         (gross $600, fee $12) unless stated otherwise. Expected values were derived independently with an
///         integer Python model of the same rules.
contract MHRotatingScenariosTest is RotatingFixture {
    uint256 internal constant N = 6;
    uint16 internal constant FEE = 200;
    int256 internal constant MINUS_FEE = -12e6;

    // ================================================================ Worked example (spec §4.4 table)

    /// @dev Runs a full honest circle; returns the cash each slot received at payout and checks what each paid
    ///      member's wallet owes per round afterwards.
    function _runWorkedExample(uint16 sigma, uint256[] memory collateral, uint256 walletAfterPayout)
        internal
        returns (uint256[] memory cash)
    {
        _startCircle(N, FEE, sigma, collateral);
        cash = new uint256[](N);
        for (uint256 r = 1; r <= N; ++r) {
            _openRound(r);
            for (uint256 k = 1; k < r; ++k) {
                assertEq(circle.amountDue(slots[k - 1], r), walletAfterPayout, "wallet pays after payout");
            }
            _payAll(r, _everyone());
            uint256 before = usdc.balanceOf(slots[r - 1]);
            circle.settleRound();
            cash[r - 1] = usdc.balanceOf(slots[r - 1]) - before;
            _assertBuckets();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        _withdrawAllSecurity();
        circle.flushFees();
        _assertBuckets();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), MINUS_FEE, "every honest member ends at -$12");
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        assertEq(usdc.balanceOf(treasury), 72e6, "6 fees of $12");
        assertEq(usdc.balanceOf(address(circle)), 0, "nothing left behind");
    }

    function test_workedExample_sigma100_noCollateral() public {
        uint256[] memory cash = _runWorkedExample(10_000, new uint256[](0), 0);
        uint256[6] memory expected = [uint256(88e6), 188e6, 288e6, 388e6, 488e6, 588e6];
        for (uint256 i; i < N; ++i) {
            assertEq(cash[i], expected[i]);
        }
    }

    function test_workedExample_sigma100_slot1Posts500() public {
        uint256[] memory col = new uint256[](1);
        col[0] = 500e6;
        uint256[] memory cash = _runWorkedExample(10_000, col, 0);
        uint256[6] memory expected = [uint256(588e6), 188e6, 288e6, 388e6, 488e6, 588e6];
        for (uint256 i; i < N; ++i) {
            assertEq(cash[i], expected[i]);
        }
    }

    function test_workedExample_sigma50() public {
        uint256[] memory cash = _runWorkedExample(5_000, new uint256[](0), 50e6);
        uint256[6] memory expected = [uint256(338e6), 388e6, 438e6, 488e6, 538e6, 588e6];
        for (uint256 i; i < N; ++i) {
            assertEq(cash[i], expected[i]);
        }
    }

    // ================================================================ Default scenarios

    /// @dev Bitmap of every slot except `slot` (1-based).
    function _allBut(uint256 slot) internal pure returns (uint256) {
        // forge-lint: disable-next-line(incorrect-shift)
        return type(uint256).max ^ (1 << (slot - 1));
    }

    /// @dev D1: σ=100%; slot 1 stops after its payout. Nothing to stop: its security pays rounds 2–6 by draws, no
    ///      strikes, everyone ends at −$12.
    function test_D1_sigma100_slot1StopsAfterPayout() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        for (uint256 r = 2; r <= N; ++r) {
            _openRound(r);
            assertEq(circle.amountDue(slots[0], r), 0, "slot 1 owes nothing");
            _payAll(r, _allBut(1));
            circle.settleRound(); // settles before grace: nothing is missing after draws
            _assertBuckets();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        _withdrawAllSecurity();
        circle.flushFees();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), MINUS_FEE);
            assertEq(reputation.strikeCount(slots[i]), 0, "no strikes");
        }
    }

    /// @dev D2: σ=50%; slot 1 stops after its payout. Rounds 2–3 are covered from its holdback, round 4 is short
    ///      and the circle cancels: $786 of $1,200 recovered (65.5%); slots 1/2/3 end +$238/+$88/+$88. Slot 1's E
    ///      is 0, so no penalty applies. Audit 2 R1-03 (spec amendment): slot 4's own round-4 payment is circular,
    ///      so it is refunded at par and slot 4's E is 300 (not 400); the shortfall is shared by E, so slot 4 ends
    ///      at −$112.909091 and slots 5 and 6 at −$150.545455 (were −$138 each). Audit 2 R1-02: the written-off
    ///      positions of slots 1–3 are flagged.
    function test_D2_sigma50_slot1StopsAfterPayout() public {
        _startCircle(N, FEE, 5_000);
        _payAll(1, _everyone());
        circle.settleRound(); // slot 1: cash 338, holdback 250
        for (uint256 r = 2; r <= 3; ++r) {
            _openRound(r);
            _payAll(r, _allBut(1));
            vm.expectRevert(IMHCircle.RoundShort.selector);
            circle.settleRound();
            _afterGrace(r);
            circle.settleRound(); // covered in full from slot 1's security
            assertTrue(reputation.struck(slots[0], address(circle), r, IMHReputation.Reason.COVERED));
        }
        assertEq(circle.memberState(slots[0]).sec, 50e6, "250 - 100 - 100");
        _openRound(4);
        _payAll(4, _allBut(1));
        _afterGrace(4);
        vm.expectRevert(IMHCircle.RoundShort.selector); // 50 < 100: no partial cover
        circle.settleRound();
        _afterCure(4);

        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.PositionWrittenOff(slots[0], 4, 250e6);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.PositionWrittenOff(slots[1], 4, 100e6);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.PositionWrittenOff(slots[2], 4, 100e6);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCancelled(IMHRotatingCircle.CancelReason.Stalled, 786e6, 1);
        circle.cancelStalled();

        uint256[6] memory claims = [uint256(0), 0, 0, 287_090_909, 249_454_545, 249_454_545];
        int256[6] memory nets = [int256(238e6), 88e6, 88e6, -112_909_091, -150_545_455, -150_545_455];
        for (uint256 i; i < N; ++i) {
            assertEq(circle.memberState(slots[i]).claim, claims[i], "claim");
        }
        assertEq(
            circle.claimTotal() + circle.residual(), 786e6, "$786 of the creditors' $1,200 recovered (65.5%)"
        );
        _claimAll();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), nets[i], "net");
        }
        assertEq(reputation.strikeCount(slots[0]), 3, "COVERED r2, r3 and DEFAULT r4");
        assertTrue(reputation.struck(slots[0], address(circle), 4, IMHReputation.Reason.DEFAULT));
        assertEq(usdc.balanceOf(treasury), 0, "fees went back into recovery");
        _assertBuckets();
    }

    /// @dev D3: σ=100%; slot 5 stops at round 3. Slot 5 ends at −$100 (its min(E, c) penalty). Audit R1-02 (spec
    ///      amendment): slots 1 and 2 were paid out and nobody is short at σ = 100%, so their $24 of fees stay for
    ///      the treasury and they end at −$12 as on completion. Audit 2 R1-03 (spec amendment): slot 3's own
    ///      round-3 payment is circular and refunded at par, so its E is 200 and the $100 penalty is split 2:3:3
    ///      among slots 3, 4 and 6: +$25, +$37.50, +$37.50 (were +$33.33 each), whether or not slot 3 paid.
    function test_D3_sigma100_slot5StopsAtRound3() public {
        _startCircle(N, FEE, 10_000);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _openRound(3);
        _payAll(3, _allBut(5)); // slots 1 and 2 owe nothing and do not even call
        _afterCure(3);

        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.Defaulted(slots[4], 3, 100e6);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHRotatingCircle.CircleCancelled(IMHRotatingCircle.CancelReason.Stalled, 1_100e6, 0);
        circle.cancelStalled();
        assertEq(circle.feeEscrow(), 24e6, "the paid-out slots' fees stay for the treasury");

        uint256[6] memory claims = [uint256(0), 0, 325e6, 337_500_000, 100_000_000, 337_500_000];
        int256[6] memory nets = [int256(-12e6), -12e6, 25e6, 37_500_000, -100e6, 37_500_000];
        int256 creditorsGain;
        for (uint256 i; i < N; ++i) {
            assertEq(circle.memberState(slots[i]).claim, claims[i], "claim");
        }
        _claimAll();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), nets[i], "net");
            if (i >= 2 && i != 4) creditorsGain += nets[i];
        }
        assertEq(creditorsGain, 100e6, "the three creditors share the $100 penalty");
        assertEq(reputation.strikeCount(slots[4]), 1);
        assertTrue(reputation.struck(slots[4], address(circle), 3, IMHReputation.Reason.DEFAULT));

        // The kept fees reach the treasury (no rounding residual is left this time).
        circle.flushFees();
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepResidual();
        assertEq(usdc.balanceOf(treasury), 24e6);
        assertEq(usdc.balanceOf(address(circle)), 0);
        _assertBuckets();
    }

    /// @dev D4: σ=50%; slot 5 stops at round 3. Slots 1 and 2 (paid out, E = 0) keep +$138 (their written-off
    ///      positions are flagged, audit 2 R1-02). Audit 2 R1-03 (spec amendment): slot 3's own round-3 payment is
    ///      circular and refunded at par, so its E is 200 (not 300) whether or not it paid; slot 5's $100 penalty
    ///      is shared 2:3:3 and the haircut by E: slot 3 ends at −$37.10, slots 4 and 6 at −$55.65 and slot 5 at
    ///      −$127.60 (were −$50.30, −$50.30, −$50.30 and −$125.09, which a recipient could move by skipping).
    function test_D4_sigma50_slot5StopsAtRound3() public {
        _startCircle(N, FEE, 5_000);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _openRound(3);
        _payAll(3, _allBut(5));
        _afterCure(3);

        vm.recordLogs();
        circle.cancelStalled();
        (uint256 assets, uint256[] memory e) = _cancelData(vm.getRecordedLogs());
        assertEq(assets, 824e6);
        uint256[6] memory expectedE = [uint256(0), 0, 200e6, 300e6, 200e6, 300e6];
        uint256 sumE;
        for (uint256 i; i < N; ++i) {
            assertEq(e[i], expectedE[i], "net position");
            sumE += e[i];
        }
        assertEq(sumE, 1_000e6);

        // Slot 3's claim includes the at-par refund of its own round-3 payment ($100).
        uint256[6] memory claims = [uint256(0), 0, 262_900_000, 244_350_000, 72_400_000, 244_350_000];
        int256[6] memory nets = [int256(138e6), 138e6, -37_100_000, -55_650_000, -127_600_000, -55_650_000];
        for (uint256 i; i < N; ++i) {
            assertEq(circle.memberState(slots[i]).claim, claims[i], "claim");
        }

        _claimAll();
        for (uint256 i; i < N; ++i) {
            assertEq(_net(slots[i]), nets[i], "net");
        }
        assertEq(circle.residual(), 0);
        _assertBuckets();
    }

    // ================================================================ Regressions

    /// @dev R1 (legacy n=3 counterexample: slot 2 gained $144 while creditor slot 3 lost $150). Unwinding by net
    ///      position: slot 1 (paid, then defaulted) keeps its +$94. Slot 2, a past recipient that kept paying,
    ///      gains nothing: it pays its $6 fee as on completion (audit R1-02), and because the creditor is short the
    ///      $12 of escrowed fees go back into recovery, so creditor slot 3 bears exactly the defaulter's gain less
    ///      those fees.
    function test_R1_cancellationUnwindsByNetPosition() public {
        _startCircle(3, FEE, 5_000); // S_1 = 100, S_2 = 50; gross 300, fee 6
        _payAll(1, _everyone());
        circle.settleRound(); // slot 1: holdback 100, cash 194
        _openRound(2);
        _payAll(2, _allBut(1));
        _afterGrace(2);
        circle.settleRound(); // slot 1 covered from its 100; slot 2: holdback 50, cash 244
        _openRound(3);
        _payAll(3, _allBut(1)); // slot 2 draws 50 and pays 50; slot 3 pays 100
        _afterCure(3);
        circle.cancelStalled();

        assertEq(circle.memberState(slots[0]).claim, 0);
        assertEq(circle.memberState(slots[1]).claim, 0, "slot 2's position net of its fee is 0");
        assertEq(circle.memberState(slots[2]).claim, 212e6, "pool 200 + the 12 of fees folded back");
        assertEq(circle.feeEscrow(), 0, "every fee went back into recovery (shortfall 100 > 12)");
        _claimAll();
        assertEq(_net(slots[0]), 94e6, "the defaulter's gain");
        assertEq(_net(slots[1]), -6e6, "slot 2 gains nothing (legacy: +$144): its fee, as on completion");
        assertEq(_net(slots[2]), -88e6, "creditor slot 3 (legacy: -$150)");
        assertEq(_net(slots[1]) + _net(slots[2]), -94e6, "losses = the defaulter's gain");
        _assertBuckets();
    }

    /// @dev R4: a Guardian cancel after a payout would strand contributors, so it is refused; the circle carries on.
    function test_R4_guardianCannotCancelAfterAPayout() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.guardianCancel();
        for (uint256 r = 2; r <= N; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
            vm.prank(guardian);
            vm.expectRevert(r == N ? IMHCircle.NotActive.selector : IMHCircle.BadRound.selector);
            circle.guardianCancel();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
    }

    /// @dev R8: no try/catch and no low-level `_pay`, so a call given too little gas reverts as a whole. Sweeps the
    ///      gas limit up to the first success and checks that every failure left no partial state.
    function test_R8_outOfGasIsAtomic() public {
        uint256[] memory col = new uint256[](2);
        col[1] = 400e6; // slot 2 (S_2 = 400) can be covered
        _startCircle(N, FEE, 10_000, col);
        _payAll(1, _allBut(2));
        _afterGrace(1);
        _gasSweep(attacker, abi.encodeCall(MHRotatingCircle.settleRound, ())); // cover + strike + payout
        assertEq(circle.nextSettle(), 2);

        _openRound(2);
        _fund(slots[2], C);
        _gasSweep(slots[2], abi.encodeCall(MHRotatingCircle.contribute, (2, C)));

        _payAll(2, _allBut(4));
        _afterCure(2);
        _gasSweep(attacker, abi.encodeCall(MHRotatingCircle.cancelStalled, ())); // unwind + strikes
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        _gasSweep(slots[2], abi.encodeCall(MHRotatingCircle.claim, ()));
        _assertBuckets();
    }

    function _probe() internal view returns (bytes32) {
        uint256 strikes;
        for (uint256 i; i < N; ++i) {
            strikes += reputation.strikeCount(slots[i]);
        }
        return keccak256(
            abi.encode(
                circle.nextSettle(),
                circle.status(),
                circle.trackedAssets(),
                circle.owedTotal(),
                circle.claimTotal(),
                usdc.balanceOf(address(circle)),
                strikes
            )
        );
    }

    function _gasSweep(address caller, bytes memory data) internal returns (uint256) {
        bytes32 before = _probe();
        for (uint256 g = 21_000; g < 2_000_000; g += 1_500) {
            vm.prank(caller);
            (bool ok,) = address(circle).call{ gas: g }(data);
            if (ok) return g;
            assertEq(_probe(), before, "partial state after running out of gas");
        }
        revert("never succeeded");
    }

    // ================================================================ Gas at n = 50 (spec §4.7 invariant 8)

    uint256 internal constant GAS_CAP = 5_000_000;

    /// @dev Worst case for `settleRound`: slots 1–49 post exactly S_k, so none is drawn and each owes c; slot 50
    ///      (S = 0) posts c and is drawn. Nobody pays from a wallet. The recipient (slot 1) has its own part netted
    ///      from its payout (audit R1-07, no strike); slots 2–49 are covered (48 covers + 48 strikes).
    function test_gas_n50_settleRoundWith48CoversAndNetting() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        for (uint256 k = 1; k <= n; ++k) {
            col[k - 1] = k == n ? C : (n - k) * C;
        }
        _startCircle(n, FEE, 10_000, col);
        _afterGrace(1);
        uint256 g = gasleft();
        circle.settleRound();
        g -= gasleft();
        emit log_named_uint("settleRound, 48 covers + 48 strikes + 1 netting, n=50", g);
        assertLt(g, GAS_CAP);
        assertEq(reputation.strikeCount(slots[0]), 0, "the recipient is netted, not covered");
        assertEq(reputation.strikeCount(slots[1]), 1);
        assertEq(reputation.strikeCount(slots[48]), 1);
        assertEq(reputation.strikeCount(slots[49]), 0, "drawn, not covered");
        _assertBuckets();
    }

    /// @dev Worst case for `cancelStalled`: all 50 members default on round 1 (each posted c − 1 cent, too little
    ///      to cover), yet each has a positive position (its collateral), so every member gets a DEFAULT strike, a
    ///      security reset and a claim; and it is called once all 50 rounds have opened. (Since audit 2 R1-11 a
    ///      member cannot pay round 2 before round 1.)
    function test_gas_n50_cancelStalledWith50Defaulters() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            col[k] = C - K.CENT;
        }
        _startCircle(n, FEE, 10_000, col);
        _openRound(n); // called late, once all 50 rounds have opened
        uint256 g = gasleft();
        circle.cancelStalled();
        g -= gasleft();
        emit log_named_uint("cancelStalled, 50 DEFAULT strikes + 50 claims, n=50", g);
        assertLt(g, GAS_CAP);
        // No penalty moves (nobody else has a positive position), so every claim is the member's own position.
        for (uint256 k; k < n; ++k) {
            assertEq(circle.memberState(slots[k]).claim, C - K.CENT, "own position");
        }
        _assertBuckets();
    }

    function test_gas_n50_guardianCancelAndClaims() public {
        uint256 n = 50;
        _startCircle(n, FEE, 10_000);
        _payAll(1, _everyone());
        vm.prank(guardian);
        uint256 g = gasleft();
        circle.guardianCancel();
        g -= gasleft();
        emit log_named_uint("guardianCancel, n=50", g);
        assertLt(g, GAS_CAP);
        _claimAll();
        for (uint256 i; i < n; ++i) {
            assertEq(_net(slots[i]), 0);
        }
    }

    /// @dev Boundary of the "cash never underflows" argument: n = 50, fee 2%, σ = 100%, no collateral. Slot 1's
    ///      holdback is 49c = gross − fee, so its cash is exactly 0.
    function test_n50_maxFee_slot1CashIsZeroNotNegative() public {
        _startCircle(50, FEE, 10_000);
        _payAll(1, _everyone());
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHRotatingCircle.RoundSettled(1, slots[0], 5_000e6, 100e6, 4_900e6, 0);
        circle.settleRound();
        _assertBuckets();
    }

    // ================================================================ Fuzz (spec §4.7 invariant 5)

    function _customStart(uint256 n, uint256 c, uint16 fee, uint256 seed)
        internal
        returns (uint256[] memory col)
    {
        RotatingParams memory p = _params(n, fee, 10_000);
        p.config.contribution = c;
        col = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            p.securityBps[i] = uint16(bound(h, K.MIN_SECURITY_BPS, K.MAX_SECURITY_BPS));
            col[i] = (h >> 32) % 3 == 0 ? bound(h >> 64, 0, n * c) : 0;
        }
        _create(p);
        for (uint256 i; i < n; ++i) {
            _join(slots[i], col[i]);
        }
        vm.warp(circle.startTime());
    }

    /// @dev No defaults, any sigmas, collateral, fee and payment timing within grace: every member nets exactly
    ///      −fee and the treasury gets n fees; no strikes; nothing is left behind.
    function testFuzz_noDefaults_everyMemberNetsMinusFee(
        uint256 nSeed,
        uint256 cSeed,
        uint16 feeSeed,
        uint256 seed
    ) public {
        uint256 n = bound(nSeed, 2, 10);
        uint256 c = bound(cSeed, 1, 1e5) * K.CENT;
        if (c < K.MIN_CONTRIBUTION) c = K.MIN_CONTRIBUTION;
        uint16 fee = uint16(bound(feeSeed, 0, K.MAX_ROTATING_FEE_BPS));
        _customStart(n, c, fee, seed);
        for (uint256 r = 1; r <= n; ++r) {
            // Pay at a random moment between the round's opening and the end of its grace (never late).
            uint256 t = circle.startTime() + (r - 1) * ROUND
                + bound(uint256(keccak256(abi.encode(seed, "t", r))), 0, ROUND + GRACE);
            // forge-lint: disable-next-line(block-timestamp)
            if (t > block.timestamp) vm.warp(t);
            _payAll(r, _everyone());
            circle.settleRound();
            _assertBuckets();
        }
        _withdrawAllSecurity();
        if (fee != 0) circle.flushFees();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 feeEach = int256(n * c * fee / K.BPS); // < 2^60
        for (uint256 i; i < n; ++i) {
            assertEq(_net(slots[i]), -feeEach, "net = -fee");
            assertEq(reputation.strikeCount(slots[i]), 0);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(usdc.balanceOf(treasury), uint256(feeEach) * n);
        assertEq(usdc.balanceOf(address(circle)), 0);
    }

    /// @dev σ = 100%: one member stops paying its wallet portion from some round on. Whether the circle completes
    ///      (its security covers it) or is cancelled, no honest member ends below −fee; on a cancellation an honest
    ///      member that was not paid out loses nothing, and one that was paid out pays exactly its fee (audit
    ///      R1-02: at σ = 100% nobody is short, so the fees stay for the treasury).
    function testFuzz_sigma100_defaultsNeverCostHonestMembers(
        uint256 nSeed,
        uint16 feeSeed,
        uint256 defaulterSeed,
        uint256 stopSeed,
        uint256 seed
    ) public {
        uint256 n = bound(nSeed, 2, 10);
        uint16 fee = uint16(bound(feeSeed, 0, K.MAX_ROTATING_FEE_BPS));
        uint256 d = bound(defaulterSeed, 0, n - 1);
        uint256 stop = bound(stopSeed, 1, n);
        RotatingParams memory p = _params(n, fee, 10_000);
        _create(p);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            _join(slots[i], h % 2 == 0 ? bound(h >> 8, 0, n * C) : 0);
        }
        vm.warp(circle.startTime());

        bool cancelled;
        for (uint256 r = 1; r <= n && !cancelled; ++r) {
            _openRound(r);
            _payAll(r, r >= stop ? _allBut(d + 1) : _everyone());
            (bool ok,) = address(circle).call(abi.encodeCall(MHRotatingCircle.settleRound, ()));
            if (!ok) {
                _afterGrace(r);
                (ok,) = address(circle).call(abi.encodeCall(MHRotatingCircle.settleRound, ()));
            }
            if (!ok) {
                _afterCure(r);
                circle.cancelStalled();
                cancelled = true;
            }
            _assertBuckets();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 feeEach = int256(n * C * fee / K.BPS); // < 2^40
        if (cancelled) {
            _claimAll();
            for (uint256 i; i < n; ++i) {
                if (i == d) continue;
                int256 floor_ = circle.memberState(slots[i]).received ? -feeEach : int256(0);
                assertGe(_net(slots[i]), floor_, "an honest member lost money");
            }
            if (circle.feeEscrow() != 0) circle.flushFees();
        } else {
            _withdrawAllSecurity();
            for (uint256 i; i < n; ++i) {
                assertEq(_net(slots[i]), -feeEach, "completed: every member nets -fee");
            }
        }
        _assertBuckets();
    }

    /// @dev Why the spec's rounding directions on `S_k` (ceil) and the fee (floor) never bite: contributions are
    ///      whole cents (1e4 units) and BPS is 1e4, so both products are exact. Mutating either direction is an
    ///      equivalent mutant; this pins the assumption so a change to CENT or BPS is noticed.
    function testFuzz_securityAndFeeAreExactForWholeCents(
        uint256 cents,
        uint16 sigma,
        uint8 units,
        uint16 fee
    ) public pure {
        uint256 c = bound(cents, K.MIN_CONTRIBUTION / K.CENT, K.MAX_CONTRIBUTION / K.CENT) * K.CENT;
        uint256 s = bound(sigma, K.MIN_SECURITY_BPS, K.MAX_SECURITY_BPS);
        uint256 u = bound(units, 0, K.MAX_MEMBERS);
        uint256 f = bound(fee, 0, K.MAX_ROTATING_FEE_BPS);
        assertEq(s * u * c % K.BPS, 0);
        assertEq(u * c * f % K.BPS, 0);
    }

    // ================================================================ Helpers

    /// @dev Reads `CircleCancelled.assets` and every `ClaimAssigned.netPosition` from the logs.
    function _cancelData(Vm.Log[] memory logs) internal view returns (uint256 assets, uint256[] memory e) {
        e = new uint256[](N);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(circle)) continue;
            if (logs[i].topics[0] == IMHRotatingCircle.ClaimAssigned.selector) {
                address m = address(uint160(uint256(logs[i].topics[1])));
                (uint256 net,) = abi.decode(logs[i].data, (uint256, uint256));
                e[circle.slotOf(m) - 1] = net;
            } else if (logs[i].topics[0] == IMHRotatingCircle.CircleCancelled.selector) {
                (assets,) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }
}
