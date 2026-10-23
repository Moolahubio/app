// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { RotatingFixture } from "./RotatingFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.7 fuzz for the rotating circle: n, c, σ (all 100%, all 50% or mixed), fee, collateral, payment
///         timing, lateness, mid-life security withdrawals and any set of defaulters with any stop round. Asserts the
///         properties behind D1–D4 (the exact D1–D4 numbers are unit-tested in `MHRotatingScenarios`):
///         - every outcome conserves money exactly (members + treasury net to zero);
///         - a completed circle nets every member exactly −fee and the treasury n fees (D1: at σ = 100% a member
///           that stops after its payout is carried by its own security, with no strike);
///         - on a cancellation (audit R1-02) a paid-out member's fee is kept unless the creditors are short; at
///           σ = 100% no honest member loses more than its own fee (nothing if it was not paid out) and a defaulter
///           loses at most min(E, c) (D3); at any σ a paid member gains at most its uncollateralised credit
///           (n−k)·c − S_k plus redistributed penalties, and the total loss is bounded by the credit extended plus
///           the fees kept (D2/D4);
///         - strikes: LATE exactly for wallet payments made after grace, COVERED only for members that did not
///           pay, DEFAULT only on a stall, and never a strike for a member whose wallet owed nothing.
contract MHRotatingFuzzTest is RotatingFixture {
    struct Run {
        uint256 n;
        uint256 c;
        uint16 fee;
        uint256 mode;
        uint256 seed;
        bool cancelled;
    }

    Run internal run;
    /// @dev Defaulter stop round per member index (0 = honest).
    mapping(uint256 index => uint256 round) internal stopAt;
    mapping(address member => mapping(uint256 round => bool late)) internal lateExpected;
    mapping(address member => uint256 e) internal cancelE;
    mapping(address member => bool d) internal defaulted;
    uint256 internal penaltyTotal;
    bool internal anyLatePayment;

    function testFuzz_rotating_defaultPatterns(
        uint256 nSeed,
        uint256 cSeed,
        uint16 feeSeed,
        uint256 modeSeed,
        uint256 seed
    ) public {
        run.n = bound(nSeed, 2, 12);
        run.c = bound(cSeed, K.MIN_CONTRIBUTION / K.CENT, 1_000_000) * K.CENT; // $1 … $10,000
        run.fee = uint16(bound(feeSeed, 0, K.MAX_ROTATING_FEE_BPS));
        run.mode = modeSeed % 3; // 0: all σ = 100%, 1: all σ = 50%, 2: mixed
        run.seed = seed;
        _setUpRun();
        for (uint256 r = 1; r <= run.n && !run.cancelled; ++r) {
            _playRound(r);
            _assertBuckets();
        }
        _finish();
    }

    // ================================================================ Setup

    function _setUpRun() internal {
        RotatingParams memory p = _params(run.n, run.fee, 10_000);
        p.config.contribution = run.c;
        for (uint256 i; i < run.n; ++i) {
            uint256 h = _h("sigma", i);
            if (run.mode == 1) p.securityBps[i] = 5_000;
            else if (run.mode == 2) p.securityBps[i] = uint16(bound(h, 5_000, 10_000));
            // ~1 in 4 members is a defaulter, stopping its wallet payments from a random round on.
            if (_h("defaulter", i) % 4 == 0) stopAt[i] = bound(_h("stop", i), 1, run.n);
        }
        _create(p);
        for (uint256 i; i < run.n; ++i) {
            uint256 h = _h("collateral", i);
            // A third of the members post collateral, in whole cents, up to S_k + c.
            uint256 col = h % 3 == 0 ? bound(h >> 8, 0, (run.n - i) * run.c / K.CENT) * K.CENT : 0;
            _join(slots[i], col);
        }
        vm.warp(circle.startTime());
    }

    // ================================================================ One round

    function _playRound(uint256 r) internal {
        _openRound(r);
        // On-time payments at a random moment between the opening and the end of grace.
        uint256 onTime = circle.startTime() + (r - 1) * ROUND + bound(_h("t", r), 0, ROUND + GRACE);
        // forge-lint: disable-next-line(block-timestamp)
        if (onTime > block.timestamp) vm.warp(onTime);
        _payers(r, false);
        if (_trySettle()) {
            _afterSettle(r);
            return;
        }
        // Late payers pay after grace, before the cure runs out; then gaps are covered or the round stalls.
        uint256 late = _graceEnd(r) + 1 + bound(_h("late", r), 0, CURE - 1);
        // forge-lint: disable-next-line(block-timestamp)
        if (late > block.timestamp) vm.warp(late);
        _payers(r, true);
        if (_trySettle()) {
            _afterSettle(r);
            return;
        }
        _afterCure(r);
        vm.recordLogs();
        circle.cancelStalled();
        _recordCancel(vm.getRecordedLogs());
        run.cancelled = true;
    }

    /// @dev Members that still pay (not stopped) and whose lateness matches `latePhase` pay round `r` from their
    ///      wallet. Members whose wallet owes nothing never call (their draw is taken at settlement).
    function _payers(uint256 r, bool latePhase) internal {
        for (uint256 i; i < run.n; ++i) {
            if (stopAt[i] != 0 && r >= stopAt[i]) continue;
            bool isLate = _h("isLate", i * 100 + r) % 6 == 0;
            if (isLate != latePhase) continue;
            address m = slots[i];
            if (circle.paid(r, m) || circle.amountDue(m, r) == 0) continue;
            uint256 pulled = _pay(m, r);
            // forge-lint: disable-next-line(block-timestamp)
            if (pulled != 0 && block.timestamp > _graceEnd(r)) {
                lateExpected[m][r] = true;
                anyLatePayment = true;
            }
        }
    }

    function _trySettle() internal returns (bool ok) {
        (ok,) = address(circle).call(abi.encodeCall(MHRotatingCircle.settleRound, ()));
    }

    /// @dev After a payout, some members withdraw everything above their requirement (exercises the requirement).
    function _afterSettle(uint256 r) internal {
        address m = slots[r - 1];
        if (_h("withdraw", r) % 4 != 0 || circle.status() != CircleStatus.Active) return;
        uint256 sec = circle.memberState(m).sec;
        uint256 req = circle.requiredSecurity(m);
        if (sec <= req) return;
        vm.prank(m);
        circle.withdrawSecurity(sec - req);
    }

    function _recordCancel(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(circle)) continue;
            address m = address(uint160(uint256(logs[i].topics.length > 1 ? logs[i].topics[1] : bytes32(0))));
            if (logs[i].topics[0] == IMHRotatingCircle.ClaimAssigned.selector) {
                (cancelE[m],) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].topics[0] == IMHRotatingCircle.Defaulted.selector) {
                defaulted[m] = true;
                penaltyTotal += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    // ================================================================ End state

    function _finish() internal {
        uint256 n = run.n;
        if (run.cancelled) _claimAll();
        else _withdrawAllSecurity();
        if (circle.feeEscrow() != 0) circle.flushFees();
        if (circle.residual() != 0) circle.sweepResidual();
        assertEq(usdc.balanceOf(address(circle)), 0, "the circle ends empty");
        _assertBuckets();

        int256 sum;
        for (uint256 i; i < n; ++i) {
            sum += _net(slots[i]);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(sum + int256(usdc.balanceOf(treasury)), 0, "money is conserved");
        _checkStrikes();
        if (run.cancelled) _checkCancelled();
        else _checkCompleted();
        // D1: at σ = 100%, members that only stop after their own payout never stall the circle.
        if (run.mode == 0) {
            bool onlyAfterPayout = true;
            for (uint256 i; i < n; ++i) {
                if (stopAt[i] != 0 && stopAt[i] <= i + 1) onlyAfterPayout = false;
            }
            if (onlyAfterPayout) assertFalse(run.cancelled, "D1: stopping after the payout never stalls");
        }
    }

    function _checkCompleted() internal view {
        uint256 feeEach = run.n * run.c * run.fee / K.BPS;
        for (uint256 i; i < run.n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(_net(slots[i]), -int256(feeEach), "completed: every member nets -fee");
            assertEq(reputation.strikesByReason(slots[i], IMHReputation.Reason.DEFAULT), 0);
        }
        assertEq(usdc.balanceOf(treasury), run.n * feeEach, "treasury: n fees");
    }

    function _checkCancelled() internal view {
        uint256 n = run.n;
        uint256 feeEach = n * run.c * run.fee / K.BPS;
        uint256 creditTotal;
        uint256 losses;
        uint256 paidOut;
        for (uint256 i; i < n; ++i) {
            (uint256 credit, uint256 loss, bool received) = _checkCancelledMember(slots[i], feeEach);
            creditTotal += credit;
            losses += loss;
            if (received) ++paidOut;
        }
        assertLe(
            losses,
            creditTotal + penaltyTotal + paidOut * feeEach + n,
            "D2/D4: total loss bounded by the credit extended (+ fees kept)"
        );
        assertLe(
            usdc.balanceOf(treasury),
            paidOut * feeEach + n,
            "cancellation: at most the paid-out fees + residual"
        );
    }

    function _checkCancelledMember(address m, uint256 feeEach)
        internal
        view
        returns (uint256 credit, uint256 loss, bool received)
    {
        uint256 n = run.n;
        uint256 c = run.c;
        IMHRotatingCircle.MemberState memory st = circle.memberState(m);
        received = st.received;
        int256 net = _net(m);
        uint256 e = cancelE[m];
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 p = int256(e < c ? e : c);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ownFee = received ? int256(feeEach) : int256(0);
        if (received) {
            uint256 units = n - st.slot;
            credit = units * c - (uint256(st.securityBps) * units * c + K.BPS - 1) / K.BPS;
        }
        if (run.mode == 0) {
            if (defaulted[m]) {
                assertGe(net, -p - ownFee, "D3: a defaulter loses at most min(E, c) (+ its own fee)");
                assertLe(net, 0, "D3: a defaulter never gains");
            } else {
                assertGe(net, -ownFee, "sigma 100%: an honest member loses at most its own fee");
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(net, int256(credit + penaltyTotal + n), "D2/D4: gain bounded by credit + penalties");
        // forge-lint: disable-next-line(unsafe-typecast)
        if (net < 0) loss = uint256(-net);
    }

    /// @dev LATE exactly for wallet payments after grace; COVERED only for members that did not pay; DEFAULT only
    ///      on a stall. D1: at σ = 100%, a member that only stopped after its payout has no strike at all.
    function _checkStrikes() internal view {
        address c = address(circle);
        for (uint256 i; i < run.n; ++i) {
            address m = slots[i];
            for (uint256 r = 1; r <= run.n; ++r) {
                assertEq(
                    reputation.struck(m, c, r, IMHReputation.Reason.LATE), lateExpected[m][r], "LATE strike"
                );
                if (reputation.struck(m, c, r, IMHReputation.Reason.COVERED)) {
                    assertTrue(stopAt[i] != 0 && r >= stopAt[i], "COVERED only for a member that did not pay");
                }
            }
            if (!run.cancelled) {
                assertEq(reputation.strikesByReason(m, IMHReputation.Reason.DEFAULT), 0, "no DEFAULT");
            }
            if (run.mode == 0 && stopAt[i] > i + 1) {
                // D1: stopped after its own payout (slot i + 1): its security pays every later round.
                assertEq(
                    reputation.strikesByReason(m, IMHReputation.Reason.COVERED)
                        + reputation.strikesByReason(m, IMHReputation.Reason.DEFAULT),
                    0,
                    "D1: carried by its own security"
                );
            }
        }
    }

    function _h(string memory tag, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(run.seed, tag, i)));
    }
}
