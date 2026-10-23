// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { CircleStatus, AccumulationConfig, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

import { MockVaultV2, MockAdapterV2 } from "../mocks/MockVaultV2.sol";

/// @notice The governance stack of `CircleFixture` with the real `MHAccumulationCircle` implementation behind the
///         factory, a mock Morpho Vault V2 allowlisted through the Timelock, and helpers that act like the app and
///         the keeper: exact approvals, `contribute(round, contribution)`, `deployIdle` after each round, and time
///         travel to the round gates.
abstract contract AccumulationFixture is CircleFixture {
    uint256 internal constant C = 100e6; // $100
    uint64 internal constant ROUND = 30 days;
    uint64 internal constant GRACE = 48 hours;
    uint64 internal constant CURE = 72 hours;
    uint256 internal constant VS = 1e6; // circle virtual shares

    /// @dev Up to 51 member addresses.
    address[] internal people;
    /// @dev USDC minted to each address by the helpers, for net-position assertions.
    mapping(address account => uint256 amount) internal minted;

    MockVaultV2 internal morpho;
    /// @dev The mock vault's one market adapter (Gauntlet shape: `burnShares` timelocked 3 days), the target of
    ///      the Guardian's `forceExit` (audit 2 R1-01).
    MockAdapterV2 internal liqAdapter;
    MHAccumulationCircle internal circle;
    uint256 private _idNonce;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i; i < 51; ++i) {
            people.push(makeAddr(string.concat("saver", vm.toString(i + 1))));
        }
        morpho = new MockVaultV2(address(usdc), makeAddr("curator"));
        liqAdapter = new MockAdapterV2();
        morpho.mockAddAdapter(address(liqAdapter));
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(morpho))));
        assertTrue(registry.isAllowedVault(address(morpho)));
    }

    function _deployAccumulationImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        override
        returns (address)
    {
        return address(new MHAccumulationCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    // ---------------------------------------------------------------- Creation

    function _params(uint256 n, uint32 rounds, uint16 fee, address v, bool lock)
        internal
        returns (AccumulationParams memory p)
    {
        p.config = AccumulationConfig({
            circleId: keccak256(abi.encode("accumulation", ++_idNonce)),
            contribution: C,
            feeBps: fee,
            roundDuration: ROUND,
            grace: GRACE,
            cure: CURE,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            totalRounds: rounds,
            vault: v,
            lockUntilMaturity: lock
        });
        p.members = new address[](n);
        for (uint256 i; i < n; ++i) {
            p.members[i] = people[i];
        }
    }

    function _create(AccumulationParams memory p) internal returns (MHAccumulationCircle c) {
        vm.prank(operator);
        c = MHAccumulationCircle(factory.createAccumulation(p));
        circle = c;
    }

    /// @dev Creates a circle, every member joins and time moves to the start of round 1.
    function _start(uint256 n, uint32 rounds, uint16 fee, address v, bool lock)
        internal
        returns (MHAccumulationCircle c)
    {
        c = _create(_params(n, rounds, fee, v, lock));
        for (uint256 i; i < n; ++i) {
            _join(people[i]);
        }
        assertEq(uint8(c.status()), uint8(CircleStatus.Active), "active");
        vm.warp(c.startTime());
    }

    /// @dev The default yield circle: n members, 12 rounds, the mock vault, no lock.
    function _startYield(uint256 n, uint16 fee) internal returns (MHAccumulationCircle) {
        return _start(n, 12, fee, address(morpho), false);
    }

    // ---------------------------------------------------------------- Member and keeper actions

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        minted[who] += amount;
        vm.prank(who);
        usdc.approve(address(circle), amount);
    }

    function _join(address who) internal {
        bytes32 terms = circle.termsHash();
        vm.prank(who);
        circle.join(terms, 0);
    }

    /// @dev `[approve(exact), contribute(round, contribution)]`.
    function _pay(address who, uint256 round) internal returns (uint256 shares) {
        _fund(who, C);
        vm.prank(who);
        shares = circle.contribute(round, C);
    }

    /// @dev Every member in `payers` (bitmap over member indices) pays `round` if it still can.
    function _payAll(uint256 round, uint256 payers) internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if ((payers >> i) & 1 == 0 || circle.amountDue(m[i], round) == 0) continue;
            _pay(m[i], round);
        }
    }

    function _everyone() internal pure returns (uint256) {
        return type(uint256).max;
    }

    function _allBut(uint256 index) internal pure returns (uint256) {
        // forge-lint: disable-next-line(incorrect-shift)
        return type(uint256).max ^ (1 << index);
    }

    /// @dev The keeper's `deployIdle`, when there is something to deploy and the registry considers the vault safe
    ///      (audit 2 R2-01: otherwise `deployIdle` reverts `VaultUnsafe`, or, closing review, delists a vault that
    ///      fails the live check and returns).
    function _deploy() internal {
        if (
            circle.status() != CircleStatus.Active || circle.vault() == address(0) || circle.yieldOff()
                || circle.idleAssets() < K.MIN_DEPLOY || !registry.vaultSafe(circle.vault())
        ) return;
        circle.deployIdle();
    }

    /// @dev Runs rounds 1..N: everyone in `payers` pays, except `skipper` (member index) in rounds whose bit is set
    ///      in `skipRounds`; the keeper deploys after each round.
    function _runRounds(uint256 payers, uint256 skipper, uint256 skipRounds) internal {
        uint256 n = circle.totalRounds();
        for (uint256 r = 1; r <= n; ++r) {
            _openRound(r);
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 who = (skipRounds >> r) & 1 == 1 ? payers & ~(uint256(1) << skipper) : payers;
            _payAll(r, who);
            _deploy();
        }
    }

    function _settleAll() internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if (circle.memberState(m[i]).settled) continue;
            circle.settleMember(m[i]);
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

    /// @dev Past round `round`'s grace + cure: from here anyone may flag it (audit 2 R1-08).
    function _afterCure(uint256 round) internal {
        vm.warp(_graceEnd(round) + circle.cure() + 1);
    }

    /// @dev Past the last round's grace + cure: `finalize` is open (audit 2 R1-08).
    function _mature() internal {
        _afterCure(circle.totalRounds());
    }

    // ---------------------------------------------------------------- Accounting

    /// @dev Wallet net of `who`: USDC held or queued for it plus vault shares held (at their redeem value), minus
    ///      what it was given.
    function _net(address who) internal view returns (int256) {
        uint256 held = usdc.balanceOf(who) + circle.owed(who) + morpho.convertToAssets(morpho.balanceOf(who));
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(held) - int256(minted[who]); // test amounts are far below 2^255
    }

    function _toAssets(uint256 shares) internal view returns (uint256) {
        return Math.mulDiv(shares, circle.nav() + 1, circle.totalShares() + VS);
    }

    /// @dev Spec §4.2 accumulation invariants, checked exactly: share buckets sum to `totalShares`, per-member sums
    ///      match the totals, tracked counters equal the balances (no donations), and Σ toAssets(bucket) ≤ NAV
    ///      (§4.7 invariant 3).
    function _assertBuckets() internal view {
        address[] memory m = circle.members();
        uint256 acc;
        uint256 claims;
        uint256 valueSum;
        for (uint256 i; i < m.length; ++i) {
            IMHAccumulationCircle.MemberState memory st = circle.memberState(m[i]);
            acc += st.accShares;
            claims += st.claimShares;
            valueSum += _toAssets(st.accShares) + _toAssets(st.claimShares);
        }
        valueSum += _toAssets(circle.forfeitShares()) + _toAssets(circle.residualShares());
        assertEq(circle.accTotal(), acc, "accTotal");
        assertEq(circle.claimTotal(), claims, "claimTotal");
        assertEq(
            acc + claims + circle.forfeitShares() + circle.residualShares(),
            circle.totalShares(),
            "share buckets"
        );
        assertEq(usdc.balanceOf(address(circle)), circle.idleAssets() + circle.owedTotal(), "usdc tracked");
        assertEq(morpho.balanceOf(address(circle)), circle.vaultShares(), "vault shares tracked");
        assertLe(valueSum, circle.nav(), "sum of claims <= NAV");
        // Audit A-R2-20: against the holdings valued at the vault's own price, independently of the circle's NAV.
        uint256 held = usdc.balanceOf(address(circle)) - circle.owedTotal();
        uint256 shares = morpho.balanceOf(address(circle)) - circle.owedSharesTotal();
        if (shares != 0) held += morpho.convertToAssets(shares);
        assertLe(valueSum, held, "sum of claims <= value of the holdings");
    }
}
