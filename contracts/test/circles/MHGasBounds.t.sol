// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RotatingFixture } from "./RotatingFixture.sol";
import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";

/// @notice Spec §4.7 invariant 8, measured cold: every top-level call runs as its own transaction (isolation), so
///         storage and accounts are cold exactly as on chain. The n = 50 worst cases of the loop-heavy functions
///         stay under 5M gas. `_measure` returns the call's gas as the harness sees it (execution of the clone
///         call, before refunds).
/// forge-config: default.isolate = true
contract MHRotatingGasBoundsTest is RotatingFixture {
    uint256 internal constant GAS_CAP = 5_000_000;

    /// @dev Audit 2 R1-24: the smallest gas limit with which `data` succeeds as its own (cold) transaction, found by
    ///      binary search, plus the intrinsic cost (21,000 and the calldata), i.e. the transaction gas limit a
    ///      keeper must send. Every probe is reverted.
    function _minTxGas(bytes memory data) internal returns (uint256) {
        uint256 lo = 21_000;
        uint256 hi = 16_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(attacker);
            (bool ok,) = address(circle).call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        return hi + intrinsic;
    }

    /// @dev Since audit 2 R1-11 (rounds are paid in order) a defaulter can no longer have contributions sitting in
    ///      later pots, so the step-4 "every pot full" stall (50 defaulters that each paid rounds 2–50) cannot
    ///      happen. The worst cases for `cancelStalled` at n = 50 are now: 50 DEFAULT strikes (each member posted
    ///      c − 1 cent; called once round 50 is open), 2 DEFAULT + 48 COVERED strikes (R1-24's case, which costs
    ///      more per member), and 1 DEFAULT with 49 members that prepaid every round (the longest refund path).
    ///      Each is asserted on the minimum transaction gas limit, cold.
    function test_gas_n50_cancelStalled_50Defaults_cold() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            col[k] = C - K.CENT;
        }
        _startCircle(n, 200, 10_000, col);
        _openRound(n);
        uint256 tx_ = _minTxGas(abi.encodeCall(circle.cancelStalled, ()));
        emit log_named_uint("cancelStalled, n=50, 50 DEFAULT strikes: min tx gas (cold)", tx_);
        assertLt(tx_, GAS_CAP);
        vm.prank(attacker);
        circle.cancelStalled();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        assertEq(reputation.strikeCount(slots[49]), 1);
        _assertBuckets();
        _claimAll();
        assertLt(usdc.balanceOf(address(circle)), n, "only rounding residual left");
    }

    /// @dev Audit 2 R1-24: slots 1 and 50 cannot be covered (c − 1 cent; slot 1 at a 2% fee cannot be netted),
    ///      slots 2–49 hold `max(c, S_k)` so they are covered at the cancellation (COVERED strikes, cover + keep
    ///      path in `_refund`).
    function test_gas_n50_cancelStalled_2Default48Covered_cold() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        for (uint256 k = 1; k <= n; ++k) {
            uint256 sk = (n - k) * C;
            col[k - 1] = k == 1 || k == n ? C - K.CENT : (sk > C ? sk : C);
        }
        _startCircle(n, 200, 10_000, col);
        _afterCure(1);
        uint256 tx_ = _minTxGas(abi.encodeCall(circle.cancelStalled, ()));
        emit log_named_uint("cancelStalled, n=50, 2 DEFAULT + 48 COVERED: min tx gas (cold)", tx_);
        assertLt(tx_, GAS_CAP);
        vm.prank(attacker);
        circle.cancelStalled();
        assertTrue(reputation.struck(slots[0], address(circle), 1, IMHReputation.Reason.DEFAULT));
        assertTrue(reputation.struck(slots[49], address(circle), 1, IMHReputation.Reason.DEFAULT));
        assertTrue(reputation.struck(slots[1], address(circle), 1, IMHReputation.Reason.COVERED));
        assertTrue(reputation.struck(slots[48], address(circle), 1, IMHReputation.Reason.COVERED));
        _assertBuckets();
    }

    /// @dev Slot 50 (S = 0, c − 1 cent) never pays round 1; the 49 others pay every round 1–50 in order while round
    ///      1 cannot settle, so every later pot holds 49 contributions that `_refund` returns at par.
    function test_gas_n50_cancelStalled_1Default49Prepaid_cold() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        col[n - 1] = C - K.CENT;
        _startCircle(n, 200, 10_000, col);
        for (uint256 r = 1; r <= n; ++r) {
            _openRound(r);
            _payAll(r, type(uint256).max >> 1 & ~(uint256(1) << (n - 1)));
        }
        assertGt(circle.pot(n), 0);
        uint256 tx_ = _minTxGas(abi.encodeCall(circle.cancelStalled, ()));
        emit log_named_uint("cancelStalled, n=50, 1 DEFAULT + 49 prepaid every round: min tx gas (cold)", tx_);
        assertLt(tx_, GAS_CAP);
        vm.prank(attacker);
        circle.cancelStalled();
        for (uint256 r = 1; r <= n; ++r) {
            assertEq(circle.pot(r), 0, "pots read 0 once cancelled");
        }
        _assertBuckets();
        _claimAll();
        assertLt(usdc.balanceOf(address(circle)), n, "only rounding residual left");
    }

    /// @dev Closeout B-R2-03: the worst case of `contribute`'s catch-up. Round 1 stays short (slot 1 cannot be netted
    ///      and never pays; nobody cancels) while 49 more rounds open; slot 50, holding $5,000 of collateral, pays
    ///      round 50 and its 49 earlier rounds are each drawn in full first (49 iterations, the bound). Cold.
    function test_gas_n50_contribute_catchUp49Rounds_cold() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        col[n - 1] = n * C;
        _startCircle(n, 200, 10_000, col);
        _openRound(n);
        assertEq(circle.nextSettle(), 1);
        assertEq(circle.amountDue(slots[n - 1], n), 0, "every round drawn in full");
        bytes memory data = abi.encodeCall(circle.contribute, (n, 0));
        uint256 lo = 21_000;
        uint256 hi = 16_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(slots[n - 1]);
            (bool ok,) = address(circle).call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("contribute, n=50, catch-up of 49 rounds: min tx gas (cold)", hi + intrinsic);
        assertLt(hi + intrinsic, GAS_CAP);
        vm.prank(slots[n - 1]);
        circle.contribute(n, 0);
        for (uint256 r = 1; r <= n; ++r) {
            assertTrue(circle.paid(r, slots[n - 1]));
        }
    }

    /// @dev Closing review (finding 1): the worst case of `depositCollateral`'s late-round walk. Slot 50 (S = 0, no
    ///      collateral) skips rounds 1–49 while the others pay them (round 1 cannot settle; nobody cancels); past
    ///      round 49's grace one deposit of 49c pays all 49 rounds: 49 iterations and 49 LATE strikes. Cold.
    function test_gas_n50_depositCollateral_49LateRounds_cold() public {
        uint256 n = 50;
        _startCircle(n, 200, 10_000);
        for (uint256 r = 1; r < n; ++r) {
            _openRound(r);
            _payAll(r, type(uint256).max >> 1 & ~(uint256(1) << (n - 1)));
        }
        _afterGrace(n - 1);
        assertEq(circle.nextSettle(), 1);
        address late = slots[n - 1];
        _fund(late, (n - 1) * C);
        bytes memory data = abi.encodeCall(circle.depositCollateral, ((n - 1) * C));
        uint256 lo = 21_000;
        uint256 hi = 16_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(late);
            (bool ok,) = address(circle).call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("depositCollateral, n=50, 49 rounds paid late: min tx gas (cold)", hi + intrinsic);
        assertLt(hi + intrinsic, GAS_CAP);
        vm.prank(late);
        circle.depositCollateral((n - 1) * C);
        assertEq(reputation.strikeCount(late), n - 1);
        for (uint256 r = 1; r < n; ++r) {
            assertTrue(reputation.struck(late, address(circle), r, IMHReputation.Reason.LATE));
        }
    }

    /// @dev The worst case since audit R1-07: the recipient (slot 1) has its own part netted from its payout (a
    ///      recipient with sec ≥ c is always nettable, so it is never covered), slots 2–49 are covered with 48
    ///      COVERED strikes, and slot 50 is drawn; cold.
    function test_gas_n50_settleRound_48CoversAndNetting_cold() public {
        uint256 n = 50;
        uint256[] memory col = new uint256[](n);
        for (uint256 k = 1; k <= n; ++k) {
            col[k - 1] = k == n ? C : (n - k) * C;
        }
        _startCircle(n, 200, 10_000, col);
        _afterGrace(1);
        vm.prank(attacker);
        uint256 g = gasleft();
        circle.settleRound();
        g -= gasleft();
        emit log_named_uint("settleRound, n=50, 48 covers + strikes + 1 netting (cold)", g);
        assertLt(g, GAS_CAP);
        assertEq(reputation.strikeCount(slots[0]), 0, "the recipient is netted, not covered");
        assertEq(reputation.strikeCount(slots[48]), 1);
    }
}

/// forge-config: default.isolate = true
contract MHAccumulationGasBoundsTest is AccumulationFixture {
    uint256 internal constant GAS_CAP = 5_000_000;

    function test_gas_n50_flagRound_50Strikes_cold() public {
        _start(50, 2, 0, address(morpho), false);
        _openRound(2);
        _afterCure(1);
        vm.prank(attacker);
        uint256 g = gasleft();
        circle.flagRound(1);
        g -= gasleft();
        emit log_named_uint("flagRound, n=50, 50 MISSED strikes (cold)", g);
        assertLt(g, GAS_CAP);
    }

    function test_gas_n50_finalize_49Caps_cold() public {
        _start(50, 2, 1_000, address(morpho), false);
        _pay(people[0], 1);
        _openRound(2);
        _payAll(2, _everyone());
        circle.deployIdle();
        morpho.mockYield(51e6);
        _mature();
        vm.prank(attacker);
        uint256 g = gasleft();
        circle.finalize();
        g -= gasleft();
        emit log_named_uint("finalize, n=50, 49 caps (cold)", g);
        assertLt(g, GAS_CAP);
    }

    function test_gas_n50_guardianCancel_cold() public {
        _start(50, 12, 1_000, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        vm.prank(people[0]);
        circle.exitEarly();
        vm.prank(guardian);
        uint256 g = gasleft();
        circle.guardianCancel();
        g -= gasleft();
        emit log_named_uint("guardianCancel, n=50 (cold)", g);
        assertLt(g, GAS_CAP);
    }
}
