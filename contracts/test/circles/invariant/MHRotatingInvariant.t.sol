// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";

import { RotatingFixture } from "../RotatingFixture.sol";
import { RotatingHandler } from "./RotatingHandler.sol";
import { MHRotatingCircle } from "../../../src/circles/MHRotatingCircle.sol";
import { IMHRotatingCircle } from "../../../src/circles/interfaces/IMHRotatingCircle.sol";
import { CircleStatus } from "../../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.7 invariants 1–5, 7 and 8 for the rotating circle, handler-based with a ghost ledger. Local runs
///         use the default profile; CI runs `FOUNDRY_PROFILE=ci` (10,000 runs at depth 200).
///         After every call: exact solvency, bucket sums, per-member USDC flows equal `cashIn`/`cashOut`, USDC only
///         ever leaves to members and the treasury, the treasury only receives fees (after completion, or the
///         paid-out members' fees a cancellation did not need for recovery), cancellation residual and donations,
///         a completed circle nets every member −fee, and the cancellation bounds hold.
///         After every run: the circle is driven to an end state with time and permissionless calls only, every
///         claim is paid, and the circle ends empty (invariant 7).
contract MHRotatingInvariantTest is RotatingFixture {
    uint256 internal constant GAS_CAP = 5_000_000;

    RotatingHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RotatingHandler(
            usdc, factory, registry, gov, address(timelock), guardian, operator, treasury, attacker
        );
        bytes4[] memory s = new bytes4[](22);
        s[0] = RotatingHandler.joinAll.selector;
        s[1] = RotatingHandler.join.selector;
        s[2] = RotatingHandler.depositCollateral.selector;
        s[3] = RotatingHandler.contribute.selector;
        s[4] = RotatingHandler.payReliable.selector;
        s[5] = RotatingHandler.withdrawSecurity.selector;
        s[6] = RotatingHandler.claim.selector;
        s[7] = RotatingHandler.claimOwed.selector;
        s[8] = RotatingHandler.settleRound.selector;
        s[9] = RotatingHandler.cancelStalled.selector;
        s[10] = RotatingHandler.cancelUnjoined.selector;
        s[11] = RotatingHandler.flushFees.selector;
        s[12] = RotatingHandler.sweepDonations.selector;
        s[13] = RotatingHandler.sweepResidual.selector;
        s[14] = RotatingHandler.guardianCancel.selector;
        s[15] = RotatingHandler.extendDeadline.selector;
        s[16] = RotatingHandler.advance.selector;
        s[17] = RotatingHandler.warp.selector;
        s[18] = RotatingHandler.donate.selector;
        s[19] = RotatingHandler.toggleUsdcPause.selector;
        s[20] = RotatingHandler.toggleBlacklist.selector;
        s[21] = RotatingHandler.adminPoke.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: s }));
    }

    function invariant_rotating() public view {
        _check();
    }

    /// @dev Invariant 7 (liveness), then every invariant again on the end state.
    function afterInvariant() public virtual {
        handler.driveToEnd();
        _check();
    }

    // ================================================================ Checks

    function _check() internal view {
        MHRotatingCircle c = handler.circle();
        if (address(c) == address(0)) return;
        address[] memory m = c.members();
        (uint256 cashIn, uint256 cashOut) = _checkMembers(c, m);
        _checkBuckets(c, m.length);
        _checkTreasury(c, m.length);
        // Member flows explain every unit: net member inflow is still tracked or went to the treasury as fees or
        // residual (donations are neither).
        assertEq(
            cashIn - cashOut,
            c.trackedAssets() + handler.ghostFees() + handler.ghostResidual(),
            "conservation"
        );
        CircleStatus st = c.status();
        if (st == CircleStatus.Completed) _checkCompleted(c, m);
        if (st == CircleStatus.Cancelled) _checkCancelled(c, m);
        assertLt(handler.ghostMaxGas(), GAS_CAP, "a call used more than 5M gas");
    }

    /// @dev Invariant 4 per member: what USDC says moved equals what the circle says moved.
    function _checkMembers(MHRotatingCircle c, address[] memory m)
        internal
        view
        returns (uint256 cashIn, uint256 cashOut)
    {
        for (uint256 i; i < m.length; ++i) {
            IMHRotatingCircle.MemberState memory st = c.memberState(m[i]);
            assertEq(usdc.received(address(c), m[i]), st.cashIn, "cashIn == USDC pulled from the member");
            assertEq(usdc.sent(address(c), m[i]) + c.owed(m[i]), st.cashOut, "cashOut == USDC paid or queued");
            cashIn += st.cashIn;
            cashOut += st.cashOut;
        }
    }

    /// @dev Invariants 1 and 2: exact solvency and bucket sums.
    function _checkBuckets(MHRotatingCircle c, uint256 n) internal view {
        address[] memory m = c.members();
        uint256 sec;
        uint256 claims;
        for (uint256 i; i < n; ++i) {
            IMHRotatingCircle.MemberState memory st = c.memberState(m[i]);
            sec += st.sec;
            claims += st.claim;
        }
        uint256 pots;
        for (uint256 r = 1; r <= n; ++r) {
            pots += c.pot(r);
        }
        assertEq(c.secTotal(), sec, "secTotal");
        assertEq(c.claimTotal(), claims, "claimTotal");
        assertEq(c.potTotal(), pots, "potTotal");
        assertEq(
            usdc.balanceOf(address(c)),
            c.trackedAssets() + c.owedTotal() + handler.ghostDonated() - handler.ghostDonSwept(),
            "balance == buckets + owed + unswept donations"
        );
        CircleStatus status = c.status();
        if (status == CircleStatus.Cancelled) {
            assertEq(c.secTotal() + c.potTotal(), 0, "cancelled: only claims, residual and kept fees");
        } else {
            assertEq(c.claimTotal() + c.residual(), 0, "claims only after a cancellation");
        }
        if (status == CircleStatus.Completed) assertEq(c.potTotal(), 0, "completed: no pot left");
    }

    /// @dev Invariant 4: USDC leaves only to members and the treasury; the treasury receives only fees after
    ///      completion, cancellation residual and donations.
    function _checkTreasury(MHRotatingCircle c, uint256 n) internal view {
        address[] memory rec = usdc.recipientsOf(address(c));
        for (uint256 i; i < rec.length; ++i) {
            assertTrue(c.slotOf(rec[i]) != 0 || rec[i] == treasury, "USDC left to a non-member");
        }
        address[] memory admins = handler.admins();
        for (uint256 i; i < admins.length; ++i) {
            if (admins[i] == treasury) continue;
            assertEq(usdc.sent(address(c), admins[i]) + c.owed(admins[i]), 0, "an admin received USDC");
        }
        assertEq(handler.ghostUnexpected(), 0, "the treasury received USDC outside fees/residual/donations");
        assertEq(
            usdc.sent(address(c), treasury) + c.owed(treasury),
            handler.ghostFees() + handler.ghostResidual() + handler.ghostDonSwept(),
            "treasury inflow by category"
        );
        assertLe(handler.ghostDonSwept(), handler.ghostDonated(), "swept more than was donated");
        assertLt(handler.ghostResidual(), n, "residual is claim-rounding dust (< 1 unit per member)");
        if (c.status() == CircleStatus.Completed) {
            assertLe(handler.ghostFees(), n * handler.feeEach(), "fees above n x fee");
        } else if (c.status() == CircleStatus.Cancelled) {
            assertLe(
                handler.ghostFees() + c.feeEscrow(),
                handler.paidOutAtCancel() * handler.feeEach(),
                "cancelled: fees above the paid-out members' fees"
            );
        } else {
            assertEq(handler.ghostFees(), 0, "fees reach the treasury only once ended");
        }
    }

    /// @dev Invariant 5a: once every round is settled, every member nets exactly −fee after taking its security.
    function _checkCompleted(MHRotatingCircle c, address[] memory m) internal view {
        uint256 fee = handler.feeEach();
        for (uint256 i; i < m.length; ++i) {
            IMHRotatingCircle.MemberState memory st = c.memberState(m[i]);
            assertEq(st.cashIn, st.cashOut + st.sec + fee, "completed: net == -fee");
        }
    }

    /// @dev Invariant 5b and the D2/D3/D4 bounds on a cancellation. `net = cashOut + claim − cashIn`.
    ///      - Unjoined or Guardian cancellation (before any payout): every member is refunded exactly.
    ///      - The circle struck exactly the defaulters the handler predicted from public state (audit R1-31).
    ///      - σ = 100% everywhere (audit R1-02: a paid-out member's fee is kept): a non-defaulter loses at most its
    ///        own fee, and nothing if it was not paid out; a defaulter never gains and loses at most min(E, c) plus
    ///        its fee, and in any case at most c plus its fee (bounds independent of the circle's events).
    ///      - Any σ: a paid member never gains more than its uncollateralised credit (n−k)·c − S_k plus the
    ///        penalties redistributed (D2/D4); an unpaid member never gains more than the penalties.
    function _checkCancelled(MHRotatingCircle c, address[] memory m) internal view {
        if (!handler.cancelled()) return;
        uint256 n = m.length;
        uint256 cc = handler.contribution();
        uint8 reason = handler.cancelReason();
        assertEq(handler.defaulterMismatches(), 0, "DEFAULT strikes differ from the independent prediction");
        assertEq(handler.blacklistedStalls(), 0, "a stall cancellation ran while USDC blacklisted the circle");
        assertEq(handler.prepaidDefaulters(), 0, "a defaulter had paid a round after the stalled one");
        for (uint256 i; i < n; ++i) {
            IMHRotatingCircle.MemberState memory st = c.memberState(m[i]);
            int256 net = int256(st.cashOut + st.claim) - int256(st.cashIn);
            if (reason != uint8(IMHRotatingCircle.CancelReason.Stalled)) {
                assertEq(net, 0, "unjoined/guardian cancel: exact refund");
                continue;
            }
            uint256 e = handler.cancelE(m[i]);
            int256 p = int256(e < cc ? e : cc);
            int256 ownFee = st.received ? int256(handler.feeEach()) : int256(0);
            bool d = handler.expectedDefaulter(m[i]);
            if (handler.allSigma100()) {
                if (d) {
                    assertGe(net, -p - ownFee, "sigma 100%: a defaulter loses at most min(E, c) + its fee");
                    // forge-lint: disable-next-line(unsafe-typecast)
                    assertGe(net, -int256(cc) - ownFee, "sigma 100%: a defaulter loses at most c + its fee");
                    assertLe(net, 0, "sigma 100%: a defaulter never gains");
                } else {
                    assertGe(net, -ownFee, "sigma 100%: an honest member loses at most its own fee");
                }
            }
            uint256 credit;
            if (st.received) {
                uint256 units = n - st.slot;
                credit = units * cc - (st.securityBps * units * cc + 9_999) / 10_000;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            assertLe(net, int256(credit + handler.penaltyTotal() + n), "gain above credit + penalties");
        }
    }
}
