// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CircleFixture } from "./CircleFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { CircleStatus, RotatingConfig, RotatingParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice The governance stack of `CircleFixture` with the real `MHRotatingCircle` implementation behind the
///         factory, plus helpers that act like the app: exact approvals, `amountDue`, and time travel to the
///         round gates.
abstract contract RotatingFixture is CircleFixture {
    uint256 internal constant C = 100e6; // $100
    uint64 internal constant ROUND = 30 days;
    uint64 internal constant GRACE = 48 hours;
    uint64 internal constant CURE = 72 hours;

    /// @dev Up to 51 member addresses, `slots[i]` is slot i+1 when used in order.
    address[] internal slots;
    /// @dev USDC minted to each address by the helpers, for net-position assertions.
    mapping(address account => uint256 amount) internal minted;

    MHRotatingCircle internal circle;
    uint256 private _idNonce;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i; i < 51; ++i) {
            slots.push(makeAddr(string.concat("slot", vm.toString(i + 1))));
        }
    }

    function _deployRotatingImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        override
        returns (address)
    {
        return address(new MHRotatingCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    // ---------------------------------------------------------------- Creation

    function _params(uint256 n, uint16 fee, uint16 sigma) internal returns (RotatingParams memory p) {
        p.config = RotatingConfig({
            circleId: keccak256(abi.encode("rotating", ++_idNonce)),
            contribution: C,
            feeBps: fee,
            roundDuration: ROUND,
            grace: GRACE,
            cure: CURE,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            // forge-lint: disable-next-line(unsafe-typecast)
            totalRounds: uint32(n)
        });
        p.members = new address[](n);
        p.securityBps = new uint16[](n);
        for (uint256 i; i < n; ++i) {
            p.members[i] = slots[i];
            p.securityBps[i] = sigma;
        }
    }

    function _create(RotatingParams memory p) internal returns (MHRotatingCircle c) {
        vm.prank(operator);
        c = MHRotatingCircle(factory.createRotating(p));
        circle = c;
    }

    /// @dev Creates a circle, every member joins (with `collateral[i]` for the first entries) and time moves to
    ///      the start of round 1.
    function _startCircle(uint256 n, uint16 fee, uint16 sigma, uint256[] memory collateral)
        internal
        returns (MHRotatingCircle c)
    {
        c = _create(_params(n, fee, sigma));
        for (uint256 i; i < n; ++i) {
            _join(slots[i], i < collateral.length ? collateral[i] : 0);
        }
        assertEq(uint8(c.status()), uint8(CircleStatus.Active), "active");
        vm.warp(c.startTime());
    }

    function _startCircle(uint256 n, uint16 fee, uint16 sigma) internal returns (MHRotatingCircle) {
        return _startCircle(n, fee, sigma, new uint256[](0));
    }

    // ---------------------------------------------------------------- Member actions (as the app batches them)

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        minted[who] += amount;
        vm.prank(who);
        usdc.approve(address(circle), amount);
    }

    function _join(address who, uint256 collateral) internal {
        if (collateral != 0) _fund(who, collateral);
        bytes32 terms = circle.termsHash();
        vm.prank(who);
        circle.join(terms, collateral);
    }

    /// @dev `[approve(exact due), contribute(round, due)]`. The recipient of `round` also pays its own round, as
    ///      the spec's worked examples assume: `amountDue` reports 0 for it once `settleRound` can net it (audit 2
    ///      R1-03/R1-19, `_payApp` follows that), but a voluntary payment is circular (it comes back in the payout,
    ///      and at a cancellation it is refunded at par), so every completion number is unchanged. It pulls at most c.
    function _pay(address who, uint256 round) internal returns (uint256 due) {
        due = circle.amountDue(who, round);
        if (due == 0 && circle.slotOf(who) == round) {
            uint256 c = circle.contribution();
            _fund(who, c);
            vm.prank(who);
            return circle.contribute(round, c);
        }
        if (due != 0) _fund(who, due);
        vm.prank(who);
        circle.contribute(round, due);
    }

    /// @dev Exactly what the app does: pays `amountDue` and nothing when it is 0 (a recipient's own netted round).
    function _payApp(address who, uint256 round) internal returns (uint256 due) {
        due = circle.amountDue(who, round);
        if (due == 0) return 0;
        _fund(who, due);
        vm.prank(who);
        circle.contribute(round, due);
    }

    /// @dev Every member in `payers` (bitmap over slot indices) pays `round`, skipping members whose wallet owes
    ///      nothing (their draw is taken by `settleRound`).
    function _payAll(uint256 round, uint256 payers) internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if ((payers >> i) & 1 == 0 || circle.paid(round, m[i])) continue;
            if (circle.amountDue(m[i], round) == 0 && i + 1 != round) continue;
            _pay(m[i], round);
        }
    }

    function _everyone() internal pure returns (uint256) {
        return type(uint256).max;
    }

    function _withdrawAllSecurity() internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            uint256 s = circle.memberState(m[i]).sec;
            if (s == 0) continue;
            vm.prank(m[i]);
            circle.withdrawSecurity(s);
        }
    }

    function _claimAll() internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if (circle.memberState(m[i]).claim == 0) continue;
            vm.prank(m[i]);
            circle.claim();
        }
    }

    // ---------------------------------------------------------------- Time

    /// @dev Moves time forward to the opening of `round` (never backwards).
    function _openRound(uint256 round) internal {
        uint256 t = circle.startTime() + (round - 1) * ROUND;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < t) vm.warp(t);
    }

    function _graceEnd(uint256 round) internal view returns (uint256) {
        return circle.roundDeadline(round) + circle.grace();
    }

    function _afterGrace(uint256 round) internal {
        vm.warp(_graceEnd(round) + 1);
    }

    function _afterCure(uint256 round) internal {
        vm.warp(_graceEnd(round) + circle.cure() + 1);
    }

    // ---------------------------------------------------------------- Accounting

    /// @dev Wallet net of `who`: what it holds (plus anything queued for it) minus what it was given.
    function _net(address who) internal view returns (int256) {
        return int256(usdc.balanceOf(who) + circle.owed(who)) - int256(minted[who]);
    }

    /// @dev Spec §4.2 rotating invariant, checked exactly: the tracked buckets equal their per-member and
    ///      per-round sums, and with no donations the balance equals the buckets plus `owedTotal`.
    function _assertBuckets() internal view {
        address[] memory m = circle.members();
        uint256 sec;
        uint256 claims;
        uint256 cashIn;
        uint256 cashOut;
        for (uint256 i; i < m.length; ++i) {
            IMHRotatingCircle.MemberState memory st = circle.memberState(m[i]);
            sec += st.sec;
            claims += st.claim;
            cashIn += st.cashIn;
            cashOut += st.cashOut;
        }
        uint256 pots;
        for (uint256 r = 1; r <= m.length; ++r) {
            pots += circle.pot(r);
        }
        assertEq(circle.secTotal(), sec, "secTotal");
        assertEq(circle.claimTotal(), claims, "claimTotal");
        assertEq(circle.potTotal(), pots, "potTotal");
        assertEq(usdc.balanceOf(address(circle)), circle.trackedAssets() + circle.owedTotal(), "solvency");
        // Member flows explain every unit: what members put in net of what they got is either still tracked or
        // went to the treasury (fees after completion, cancellation dust). Valid in tests without donations.
        assertEq(
            cashIn - cashOut,
            circle.trackedAssets() + usdc.balanceOf(treasury) + circle.owed(treasury),
            "conservation"
        );
    }
}
