// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Vm } from "forge-std/Vm.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleTerms } from "../../src/circles/MHCircleTerms.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { CircleMode, CircleStatus, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

import { MockVaultV2 } from "../mocks/MockVaultV2.sol";

/// @notice Unit tests for `MHAccumulationCircle`: every function, revert and event (spec §4.3, §4.5, §4.7).
contract MHAccumulationCircleTest is AccumulationFixture {
    uint256 internal constant SHARES_PER_C = 100e6 * 1e6; // first mint: c·(0+1e6)/(0+1)

    // ================================================================ Implementation

    function test_implementation_isInertAndWired() public {
        MHAccumulationCircle impl = MHAccumulationCircle(accumulationImpl);
        assertEq(uint8(impl.circleMode()), uint8(CircleMode.Accumulation));
        assertEq(address(impl.USDC()), address(usdc));
        assertEq(address(impl.REGISTRY()), address(registry));
        assertEq(address(impl.REPUTATION()), address(reputation));
        AccumulationParams memory p = _params(3, 12, 0, address(0), false);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    function test_constructor_revertsOnZero() public {
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHAccumulationCircle(IUSDC(address(0)), registry, reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHAccumulationCircle(IUSDC(address(usdc)), IMHCircleRegistry(address(0)), reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MHAccumulationCircle(IUSDC(address(usdc)), registry, IMHReputation(address(0)));
    }

    // ================================================================ initialize

    function test_initialize_storesTerms() public {
        AccumulationParams memory p = _params(4, 24, 1_000, address(morpho), true);
        MHAccumulationCircle c = _create(p);

        assertTrue(factory.isCircle(address(c)));
        assertEq(c.circleId(), p.config.circleId);
        assertEq(c.contribution(), C);
        assertEq(c.feeBps(), 1_000);
        assertEq(c.roundDuration(), ROUND);
        assertEq(c.grace(), GRACE);
        assertEq(c.cure(), CURE);
        assertEq(c.joinDeadline(), p.config.joinDeadline);
        assertEq(c.plannedStart(), p.config.plannedStart);
        assertEq(c.totalRounds(), 24);
        assertEq(c.vault(), address(morpho));
        assertTrue(c.lockUntilMaturity());
        assertEq(uint8(c.status()), uint8(CircleStatus.Pending));
        assertEq(c.joinedCount(), 0);
        assertEq(c.settledCount(), 0);
        assertEq(c.startTime(), 0);
        assertEq(c.extension(), 0);
        assertFalse(c.yieldOff());
        assertEq(c.totalShares(), 0);
        assertEq(c.nav(), 0);
        assertEq(c.members(), p.members);
        for (uint256 i; i < 4; ++i) {
            assertEq(c.slotOf(p.members[i]), i + 1);
            assertEq(c.memberState(p.members[i]).slot, i + 1);
            assertFalse(c.memberState(p.members[i]).joined);
        }
        assertEq(c.slotOf(attacker), 0);
        assertEq(
            c.termsHash(),
            MHCircleTerms.accumulation(block.chainid, address(c), p.config, p.members),
            "terms hash"
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        c.initialize(p);
    }

    function test_initialize_rejectsEveryBadConfig() public {
        for (uint256 k; k < 23; ++k) {
            AccumulationParams memory p = _badParams(k);
            vm.prank(operator);
            vm.expectRevert(IMHCircle.BadConfig.selector);
            factory.createAccumulation(p);
        }
    }

    function test_initialize_acceptsBoundaries() public {
        AccumulationParams memory p =
            _params(50, uint32(K.MAX_ROUNDS), uint16(K.MAX_ACCUMULATION_FEE_BPS), address(0), false);
        p.config.contribution = K.MIN_CONTRIBUTION;
        p.config.roundDuration = uint64(K.MAX_ROUND);
        p.config.grace = uint64(K.MAX_ROUND - 1);
        p.config.cure = uint64(K.MAX_CURE);
        p.config.joinDeadline = uint64(block.timestamp + K.MAX_JOIN_WINDOW);
        p.config.plannedStart = uint64(block.timestamp + K.MAX_JOIN_WINDOW + K.MAX_START_DELAY);
        _create(p);

        p = _params(2, 1, 0, address(morpho), false);
        // forge-lint: disable-next-line(divide-before-multiply)
        p.config.contribution = (K.MAX_CONTRIBUTION / K.CENT) * K.CENT;
        p.config.roundDuration = uint64(K.MIN_ROUND);
        p.config.grace = uint64(K.MIN_GRACE);
        p.config.cure = uint64(K.MIN_CURE);
        p.config.joinDeadline = uint64(block.timestamp + 1);
        p.config.plannedStart = 0;
        _create(p);
    }

    function _badParams(uint256 k) internal returns (AccumulationParams memory p) {
        p = _params(3, 12, 0, address(morpho), false);
        if (k == 0) {
            p.config.circleId = bytes32(0);
        } else if (k == 1) {
            p = _params(1, 12, 0, address(0), false);
        } else if (k == 2) {
            p = _params(51, 12, 0, address(0), false);
        } else if (k == 3) {
            p.config.totalRounds = 0;
        } else if (k == 4) {
            p.config.totalRounds = uint32(K.MAX_ROUNDS + 1);
        } else if (k == 5) {
            p.config.contribution = K.MIN_CONTRIBUTION - K.CENT;
        } else if (k == 6) {
            p.config.contribution = C + 1;
        } else if (k == 7) {
            p.config.contribution = (K.MAX_CONTRIBUTION / K.CENT + 1) * K.CENT;
        } else if (k == 8) {
            p.config.feeBps = uint16(K.MAX_ACCUMULATION_FEE_BPS + 1);
        } else if (k == 9) {
            p.config.roundDuration = 7 days - 1;
        } else if (k == 10) {
            p.config.roundDuration = 92 days + 1;
        } else if (k == 11) {
            p.config.grace = 48 hours - 1;
        } else if (k == 12) {
            p.config.grace = ROUND;
        } else if (k == 13) {
            p.config.cure = 72 hours - 1;
        } else if (k == 14) {
            p.config.cure = 30 days + 1;
        } else if (k == 15) {
            p.config.joinDeadline = uint64(block.timestamp);
        } else if (k == 16) {
            p.config.joinDeadline = uint64(block.timestamp + 30 days + 1);
        } else if (k == 17) {
            p.config.plannedStart = p.config.joinDeadline + 30 days + 1;
        } else if (k == 18) {
            p.members[1] = address(0);
        } else if (k == 19) {
            p.members[2] = p.members[0];
        } else if (k == 20) {
            p.config.vault = address(new MockVaultV2(address(usdc), address(this))); // not allowed
        } else if (k == 21) {
            // Allowlisted, but its asset is no longer USDC.
            MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
            _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(v))));
            v.mockSetAsset(address(0xbeef));
            p = _params(3, 12, 0, address(v), false);
        } else if (k == 22) {
            // Delisted by the Guardian before creation.
            vm.prank(guardian);
            registry.disallowVault(address(morpho));
        }
    }

    // ================================================================ join

    function test_join_activatesOnLastJoin() public {
        AccumulationParams memory p = _params(3, 12, 0, address(morpho), false);
        _create(p);
        bytes32 terms = circle.termsHash();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.Joined(people[0]);
        vm.prank(people[0]);
        circle.join(terms, 0);
        assertEq(circle.joinedCount(), 1);
        assertTrue(circle.memberState(people[0]).joined);
        _join(people[1]);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Pending));

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.Joined(people[2]);
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.Activated(p.config.plannedStart);
        vm.prank(people[2]);
        circle.join(terms, 0);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
        assertEq(circle.startTime(), p.config.plannedStart);
        assertFalse(circle.yieldOff());
        assertEq(circle.currentRound(), 0, "not open before plannedStart");
        assertEq(circle.roundDeadline(1), p.config.plannedStart + ROUND);
    }

    function test_join_startIsNowWhenPlannedStartHasPassed() public {
        AccumulationParams memory p = _params(2, 12, 0, address(0), false);
        p.config.plannedStart = uint64(block.timestamp + 1 days);
        _create(p);
        _join(people[0]);
        vm.warp(block.timestamp + 3 days);
        _join(people[1]);
        assertEq(circle.startTime(), block.timestamp);
        assertEq(circle.currentRound(), 1);
    }

    function test_join_reverts() public {
        _create(_params(2, 12, 0, address(0), false));
        bytes32 terms = circle.termsHash();

        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.BadTerms.selector);
        circle.join(bytes32(uint256(terms) ^ 1), 0);

        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.BadTerms.selector); // accumulation circles take no collateral
        circle.join(terms, 1);

        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.join(terms, 0);

        _join(people[0]);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.AlreadyJoined.selector);
        circle.join(terms, 0);

        uint256 snap = vm.snapshotState();
        vm.warp(circle.joinDeadline() + 1);
        vm.prank(people[1]);
        vm.expectRevert(IMHCircle.JoinClosed.selector);
        circle.join(terms, 0);
        vm.revertToState(snap);

        vm.warp(circle.joinDeadline()); // still open at the deadline itself
        _join(people[1]);
        vm.prank(people[1]);
        vm.expectRevert(IMHCircle.NotPending.selector);
        circle.join(terms, 0);
    }

    /// @dev Audit 2 R2-01 (was: the activating join latched `yieldOff`): a vault delisted before activation pauses
    ///      deposits (`deployIdle` reverts `VaultUnsafe`) but latches nothing.
    function test_join_lastJoinWithDelistedVault_pausesDepositsWithoutLatch() public {
        _create(_params(2, 12, 0, address(morpho), false));
        _join(people[0]);
        vm.prank(guardian);
        registry.disallowVault(address(morpho));

        bytes32 terms = circle.termsHash();
        vm.prank(people[1]);
        circle.join(terms, 0);
        assertFalse(circle.yieldOff(), "nothing latched at activation");

        vm.warp(circle.startTime());
        _pay(people[0], 1); // saving continues, idle only
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        circle.deployIdle();
        assertEq(circle.idleAssets(), C);

        // Gov re-allows the vault: deposits resume.
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(morpho))));
        circle.deployIdle();
        assertEq(circle.idleAssets(), 0);
        assertGt(circle.vaultShares(), 0);
    }

    // ================================================================ cancelUnjoined

    function test_cancelUnjoined() public {
        _create(_params(3, 12, 0, address(morpho), false));
        _join(people[0]);
        _join(people[1]);

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
        emit IMHAccumulationCircle.CircleCancelled(IMHAccumulationCircle.CancelReason.Unjoined, 0, 0);
        circle.cancelUnjoined();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        assertEq(reputation.strikeCount(people[2]), 0, "no strikes");

        vm.expectRevert(IMHCircle.NotPending.selector);
        circle.cancelUnjoined();
        vm.expectRevert(IMHCircle.NothingToClaim.selector); // nothing was ever held
        circle.sweepResidual();
    }

    // ================================================================ contribute

    function test_contribute_mintsSharesAndEmits() public {
        _startYield(3, 0);
        _fund(people[0], C);
        vm.expectEmit(true, true, false, true, address(circle));
        emit IMHAccumulationCircle.Contributed(people[0], 1, C, 0, false);
        vm.prank(people[0]);
        uint256 shares = circle.contribute(1, C);
        assertEq(shares, SHARES_PER_C, "first mint c*(0+1e6)/(0+1)");
        // Second mint at NAV = 100e6, T = 1e14: exactly the same price.
        assertEq(_pay(people[1], 1), SHARES_PER_C);

        IMHAccumulationCircle.MemberState memory st = circle.memberState(people[0]);
        assertEq(st.principal, C);
        assertEq(st.accShares, SHARES_PER_C);
        assertEq(st.paidRounds, 1);
        assertEq(st.cashOut, 0);
        assertTrue(circle.paid(1, people[0]));
        assertFalse(circle.paid(1, people[2]));
        assertEq(circle.idleAssets(), 2 * C);
        assertEq(circle.vaultShares(), 0, "contribute never deploys");
        assertEq(circle.accTotal(), 2 * SHARES_PER_C);
        assertEq(circle.totalShares(), 2 * SHARES_PER_C);
        assertEq(circle.nav(), 2 * C);
        assertEq(usdc.balanceOf(people[0]), 0);
        assertEq(usdc.allowance(people[0], address(circle)), 0, "exact approval consumed");
        _assertBuckets();
    }

    function test_contribute_mintsAgainstCurrentNav() public {
        _startYield(2, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        morpho.mockYield(20e6); // vault 200 → 220
        _openRound(2);
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 expected = Math.mulDiv(C, total + VS, nav + 1);
        assertEq(_pay(people[0], 2), expected, "floor(c*(T+1e6)/(NAV+1))");
        assertLt(expected, SHARES_PER_C, "later money buys fewer shares after yield");
        _assertBuckets();
    }

    function test_contribute_window() public {
        _create(_params(3, 3, 0, address(0), false));
        for (uint256 i; i < 3; ++i) {
            _join(people[i]);
        }
        // Active, but round 1 has not opened.
        _fund(people[0], C);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(1, C);
        assertEq(circle.amountDue(people[0], 1), 0);

        vm.warp(circle.startTime());
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(0, C);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(2, C); // not open yet
        assertEq(circle.amountDue(people[0], 1), C);

        // Round 2 open: round 1 still payable until its deadline + grace, inclusive.
        _openRound(2);
        assertEq(circle.currentRound(), 2);
        vm.warp(_graceEnd(1));
        _pay(people[0], 1);
        vm.warp(_graceEnd(1) + 1);
        _fund(people[1], C);
        vm.prank(people[1]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(1, C);
        assertEq(circle.amountDue(people[1], 1), 0);

        // The Guardian's extension pushes the grace gate, so round 1 reopens until it is flagged.
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        assertEq(circle.amountDue(people[1], 1), C);
        _pay(people[1], 1);
        _afterCure(1);
        circle.flagRound(1);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        assertLe(block.timestamp, _graceEnd(1), "inside the extended grace");
        _fund(people[2], C);
        vm.prank(people[2]);
        vm.expectRevert(IMHCircle.BadRound.selector); // flagged rounds stay closed
        circle.contribute(1, C);

        // Two rounds back is never payable (without extension); the last round is capped.
        _openRound(3);
        vm.warp(block.timestamp + 365 days);
        assertEq(circle.currentRound(), 3, "capped at totalRounds");
        vm.prank(people[2]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(3, C);
        vm.prank(people[2]);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.contribute(4, C);
    }

    function test_contribute_reverts() public {
        _create(_params(2, 12, 0, address(0), false));
        _fund(people[0], 2 * C);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.contribute(1, C);

        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.contribute(1, C);

        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.ExceedsMaxPull.selector);
        circle.contribute(1, C - 1);

        vm.prank(people[0]);
        circle.contribute(1, C);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.AlreadyPaid.selector);
        circle.contribute(1, C);
        assertEq(circle.amountDue(people[0], 1), 0, "already paid");

        vm.prank(people[0]);
        circle.exitEarly();
        _openRound(2);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.AlreadySettled.selector);
        circle.contribute(2, C);
        assertEq(circle.amountDue(people[0], 2), 0, "exited");
        assertEq(circle.amountDue(attacker, 2), 0, "not a member");
        assertEq(circle.amountDue(people[1], 2), C);
        assertEq(circle.amountDue(people[1], 3), 0, "not open");
    }

    // ================================================================ deployIdle

    function test_deployIdle_depositsExactAmount() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        uint256 expectedShares = morpho.previewDeposit(3 * C);

        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.IdleDeployed(3 * C, expectedShares);
        vm.prank(attacker); // permissionless
        circle.deployIdle();

        assertEq(circle.idleAssets(), 0);
        assertEq(circle.vaultShares(), expectedShares);
        assertEq(morpho.balanceOf(address(circle)), expectedShares);
        assertEq(usdc.allowance(address(circle), address(morpho)), 0, "exact approval, nothing left");
        assertEq(circle.nav(), 3 * C);
        assertEq(circle.memberValue(people[0]), C);
        _assertBuckets();
    }

    function test_deployIdle_reverts() public {
        _create(_params(2, 12, 0, address(morpho), false));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.deployIdle();
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());

        vm.expectRevert(IMHAccumulationCircle.NothingToDeploy.selector);
        circle.deployIdle();

        _payAll(1, _everyone());
        morpho.mockSetDepositsBlocked(true);
        vm.expectRevert(bytes("MockVaultV2: deposits gated")); // the vault's revert bubbles up
        circle.deployIdle();
        assertEq(circle.idleAssets(), 2 * C, "rolled back");
        assertEq(usdc.allowance(address(circle), address(morpho)), 0, "rolled back");
        morpho.mockSetDepositsBlocked(false);

        vm.prank(guardian);
        circle.emergencyExit(0);
        vm.expectRevert(IMHAccumulationCircle.NoYield.selector);
        circle.deployIdle();

        _start(2, 12, 0, address(0), false);
        _payAll(1, _everyone());
        vm.expectRevert(IMHAccumulationCircle.NoYield.selector);
        circle.deployIdle();
    }

    // ================================================================ NAV and donations

    function test_nav_ignoresDonations() public {
        _startYield(2, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _pay(people[0], 2);
        uint256 nav = circle.nav();
        uint256 value = circle.memberValue(people[0]);
        assertEq(nav, 3 * C);

        usdc.mint(address(circle), 50e6); // USDC donation
        usdc.mint(attacker, 10e6); // vault-share donation
        vm.startPrank(attacker);
        usdc.approve(address(morpho), 10e6);
        uint256 donated = morpho.deposit(10e6, address(circle));
        vm.stopPrank();

        assertEq(circle.nav(), nav, "tracked counters only");
        assertEq(circle.memberValue(people[0]), value);
        assertEq(circle.vaultShares() + donated, morpho.balanceOf(address(circle)));
    }

    // ================================================================ exitEarly

    function test_exitEarly_withGain_paysPrincipalAndForfeitsTheRest() public {
        _startYield(3, 1_500);
        _runFirstRounds(2);
        morpho.mockYield(60e6); // 600 → 660
        address m = people[0];
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 acc = circle.memberState(m).accShares;
        uint256 burn = Math.mulDiv(2 * C, total + VS, nav + 1, Math.Rounding.Ceil);
        uint256 vsBefore = circle.vaultShares();
        uint256 withdrawShares = morpho.previewWithdraw(2 * C); // idle is 0: the whole amount comes from the vault

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ExitedEarly(m, 2 * C, 2 * C, acc - burn);
        vm.prank(m);
        uint256 amount = circle.exitEarly();

        assertEq(amount, 2 * C, "min(principal, value) = principal");
        assertEq(usdc.balanceOf(m), 2 * C);
        assertEq(_net(m), 0, "principal back, no fee");
        assertEq(usdc.balanceOf(treasury), 0, "no fee on exits");
        assertEq(circle.forfeitShares(), acc - burn);
        assertEq(circle.totalShares(), total - burn);
        assertEq(circle.vaultShares(), vsBefore - withdrawShares, "withdrew exactly the shortfall");
        assertEq(circle.idleAssets(), 0);
        assertEq(circle.settledCount(), 1);
        IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
        assertTrue(st.exited);
        assertTrue(st.settled);
        assertEq(st.exitRound, 2);
        assertEq(st.accShares, 0);
        assertEq(st.cashOut, 2 * C);
        assertFalse(st.compliant);
        _assertBuckets();

        vm.prank(m);
        vm.expectRevert(IMHCircle.AlreadySettled.selector);
        circle.exitEarly();
    }

    function test_exitEarly_withLoss_paysValue() public {
        _startYield(3, 1_500);
        _runFirstRounds(2);
        morpho.mockLoss(60e6); // 600 → 540
        address m = people[1];
        uint256 value = circle.memberValue(m);
        assertLt(value, 2 * C);
        assertApproxEqAbs(value, 180e6, 1);
        vm.prank(m);
        uint256 amount = circle.exitEarly();
        assertEq(amount, value);
        assertEq(usdc.balanceOf(m), value);
        assertLe(
            _toAssets(circle.forfeitShares()), 1, "only rounding dust (under one micro-USDC) is forfeited"
        );
        _assertBuckets();
    }

    function test_exitEarly_reverts() public {
        _start(2, 12, 0, address(0), true);
        _payAll(1, _everyone());
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.Locked.selector);
        circle.exitEarly();

        _create(_params(2, 12, 0, address(morpho), false));
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.exitEarly();
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.exitEarly();

        _payAll(1, _everyone());
        circle.deployIdle();
        morpho.mockSetLiquidity(C - 1);
        vm.prank(people[0]);
        vm.expectRevert(bytes("MockVaultV2: illiquid")); // vault reverts bubble up; nothing changes
        circle.exitEarly();
        assertFalse(circle.memberState(people[0]).exited);

        _mature();
        circle.finalize();
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.exitEarly();
    }

    // ================================================================ flagRound

    function test_flagRound_recordsMissedStrikes() public {
        _startYield(3, 0);
        _payAll(1, _allBut(2));
        vm.warp(_graceEnd(1));
        vm.expectRevert(IMHCircle.BadRound.selector); // grace not over
        circle.flagRound(1);
        vm.warp(_graceEnd(1) + CURE);
        vm.expectRevert(IMHCircle.BadRound.selector); // audit 2 R1-08: nor the cure after it
        circle.flagRound(1);

        vm.warp(_graceEnd(1) + CURE + 1);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.RoundFlagged(1, 1);
        vm.expectEmit(true, true, true, true, address(reputation));
        emit IMHReputation.StrikeRecorded(people[2], address(circle), 1, IMHReputation.Reason.MISSED);
        vm.prank(attacker); // permissionless
        circle.flagRound(1);

        assertTrue(circle.roundFlagged(1));
        assertTrue(reputation.struck(people[2], address(circle), 1, IMHReputation.Reason.MISSED));
        assertEq(reputation.strikeCount(people[2]), 1);
        assertEq(reputation.strikeCount(people[0]), 0);
        assertEq(reputation.strikeCount(people[1]), 0);

        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(1); // once
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(0);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(13);

        _openRound(2);
        _afterCure(2);
        usdc.pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.flagRound(2);
        usdc.unpause();
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.RoundFlagged(2, 3);
        circle.flagRound(2);
        assertEq(reputation.strikesByReason(people[2], IMHReputation.Reason.MISSED), 2);
    }

    function test_flagRound_statusGates() public {
        _create(_params(2, 2, 0, address(0), false));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.flagRound(1);
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        _openRound(2);
        _payAll(2, _everyone());
        _mature();
        circle.finalize();
        circle.flagRound(1); // still allowed after maturity: everyone missed round 1
        assertEq(reputation.strikeCount(people[0]), 1);
        _settleAll();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        circle.flagRound(2); // and once closed (nobody missed round 2)
        assertEq(reputation.strikeCount(people[0]), 1);

        _startYield(2, 0);
        vm.prank(guardian);
        circle.guardianCancel();
        _afterGrace(1);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.flagRound(1);
    }

    function test_flagRound_exitedMemberOnlyForRoundsBeforeExit() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        _openRound(2);
        _payAll(2, _allBut(0));
        _openRound(3); // round 2 is still in grace
        vm.prank(people[0]);
        circle.exitEarly(); // exitRound = 3, round 2 unpaid
        assertEq(circle.memberState(people[0]).exitRound, 3);
        _afterCure(2);
        circle.flagRound(2);
        assertTrue(reputation.struck(people[0], address(circle), 2, IMHReputation.Reason.MISSED));
        _openRound(4);
        _afterCure(3);
        circle.flagRound(3);
        assertFalse(reputation.struck(people[0], address(circle), 3, IMHReputation.Reason.MISSED), "left");
        assertEq(reputation.strikeCount(people[1]), 1, "missed round 3");
    }

    // ================================================================ finalize

    function test_finalize_capsDelinquentAndSnapshots() public {
        _startYield(3, 0);
        _runRounds(_everyone(), 2, 1 << 5); // member 2 misses round 5
        morpho.mockYield(35e6); // 3500 → 3535 (1%)
        _mature();
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        address d = people[2];
        uint256 accD = circle.memberState(d).accShares;
        uint256 keep = Math.mulDiv(11 * C, total + VS, nav + 1);
        uint256 compliantAcc =
            circle.memberState(people[0]).accShares + circle.memberState(people[1]).accShares;

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.Forfeited(d, accD - keep);
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.Finalized(nav, accD - keep, compliantAcc);
        vm.prank(attacker); // permissionless
        circle.finalize();

        assertEq(uint8(circle.status()), uint8(CircleStatus.Matured));
        assertEq(circle.memberState(d).accShares, keep);
        assertLe(circle.memberValue(d), 11 * C, "delinquent capped at principal");
        assertEq(circle.forfeitSnap(), accD - keep);
        assertEq(circle.forfeitShares(), accD - keep);
        assertEq(circle.compliantSnap(), compliantAcc);
        assertEq(circle.bonusBase(), compliantAcc);
        assertTrue(circle.memberState(people[0]).compliant);
        assertFalse(circle.memberState(d).compliant);
        _assertBuckets();
    }

    function test_finalize_lossDoesNotCapDelinquent() public {
        _startYield(3, 0);
        _runRounds(_everyone(), 2, 1 << 5);
        morpho.mockLoss(35e6);
        _mature();
        uint256 accD = circle.memberState(people[2]).accShares;
        circle.finalize();
        assertEq(circle.memberState(people[2]).accShares, accD, "value below principal: nothing forfeited");
        assertEq(circle.forfeitSnap(), 0);
    }

    function test_finalize_reverts() public {
        _create(_params(2, 2, 0, address(0), false));
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.finalize();
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        vm.warp(_graceEnd(2));
        vm.expectRevert(IMHCircle.NotMatured.selector);
        circle.finalize();

        vm.prank(guardian);
        circle.extendDeadline(1 days);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(IMHCircle.NotMatured.selector); // the extension moved maturity
        circle.finalize();

        _mature();
        usdc.pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.finalize();
        usdc.unpause();
        circle.finalize();
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.finalize();
    }

    /// @dev Audit R1-09: with nobody left at maturity, each exited member gets its own forfeited shares back as a
    ///      claim (fee 0 here); only rounding dust reaches the treasury.
    function test_finalize_everyoneExited_returnsForfeits() public {
        _startYield(2, 0);
        _runFirstRounds(2);
        morpho.mockYield(40e6);
        vm.prank(people[0]);
        circle.exitEarly();
        uint256 f0 = circle.forfeitShares();
        vm.prank(people[1]);
        circle.exitEarly();
        uint256 f1 = circle.forfeitShares() - f0;
        assertGt(f0, 0);
        assertGt(f1, 0);
        _mature();
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ClaimAssigned(people[0], f0, f0);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ClaimAssigned(people[1], f1, f1);
        vm.expectEmit(false, false, false, false, address(circle));
        emit IMHAccumulationCircle.CircleClosed();
        circle.finalize();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        assertEq(circle.forfeitShares(), 0);
        assertEq(circle.residualShares(), 0, "nothing to the treasury");
        assertEq(circle.memberState(people[0]).claimShares, f0);
        assertEq(circle.memberState(people[1]).claimShares, f1);
        _assertBuckets();

        vm.prank(people[0]);
        circle.claim();
        vm.prank(people[1]);
        circle.claimInKind();
        assertApproxEqAbs(_net(people[0]) + _net(people[1]), 40e6, 3, "the whole yield back to the members");
        circle.sweepResidual();
        assertLe(
            usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury)), 3, "dust only"
        );
    }

    // ================================================================ settleMember

    function test_settleMember_compliantPaysBonusAndFeeOnEarnings() public {
        _startYield(3, 1_000);
        _runRounds(_everyone(), 2, 1 << 5);
        morpho.mockYield(70e6); // 2%
        _mature();
        circle.finalize();

        address a = people[0];
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 acc = circle.memberState(a).accShares;
        uint256 bonus = Math.mulDiv(circle.forfeitSnap(), acc, circle.compliantSnap());
        uint256 gross = Math.mulDiv(acc + bonus, nav + 1, total + VS);
        uint256 fee = (gross - 12 * C) * 1_000 / 10_000;
        assertGt(bonus, 0);

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(a, 12 * C, gross, fee, true);
        vm.prank(attacker); // anyone; pays only the member
        circle.settleMember(a);

        assertEq(usdc.balanceOf(a), gross - fee);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(circle.forfeitShares(), circle.forfeitSnap() - bonus);
        assertEq(circle.memberState(a).cashOut, gross - fee);
        assertTrue(circle.memberState(a).settled);
        assertEq(circle.settledCount(), 1);
        _assertBuckets();

        vm.expectRevert(IMHCircle.AlreadySettled.selector);
        circle.settleMember(a);
    }

    /// @dev Audit R1-11: the cap applies once, at finalize. Yield earned after maturity on the delinquent's
    ///      retained shares is the delinquent's (no fee), never residual for the treasury.
    function test_settleMember_delinquentKeepsPostMaturityYield() public {
        _startYield(3, 1_000);
        _runRounds(_everyone(), 2, 1 << 5);
        morpho.mockYield(70e6);
        _mature();
        circle.finalize();
        morpho.mockYield(100e6); // more yield after maturity
        address d = people[2];
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 acc = circle.memberState(d).accShares;
        uint256 gross = Math.mulDiv(acc, nav + 1, total + VS);
        assertGt(gross, 11 * C);

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(d, 11 * C, gross, 0, false);
        circle.settleMember(d);
        assertEq(usdc.balanceOf(d), gross, "principal plus post-maturity yield, no fee");
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(circle.residualShares(), 0, "nothing to residual");
        _assertBuckets();
    }

    /// @dev All-delinquent rule: uncapped, the exit forfeit shared by every remaining member (deviation 9), and
    ///      since audit R1-10 the normal fee on earnings.
    function test_settleMember_allDelinquent_uncappedFeeOnEarningsSharesExitForfeit() public {
        _startYield(3, 1_500);
        // Every member misses a different round; member 0 also exits with a gain later.
        _openRound(1);
        _payAll(1, _allBut(1));
        _openRound(2);
        _payAll(2, _allBut(2));
        for (uint256 r = 3; r <= 12; ++r) {
            _openRound(r);
            _payAll(r, _allBut(0) | (r < 6 ? 1 : 0));
            _deploy();
        }
        morpho.mockYield(100e6);
        vm.prank(people[0]);
        circle.exitEarly();
        uint256 exitForfeit = circle.forfeitShares();
        assertGt(exitForfeit, 0);
        _mature();
        uint256 acc1 = circle.memberState(people[1]).accShares;
        uint256 acc2 = circle.memberState(people[2]).accShares;
        circle.finalize();
        assertEq(circle.compliantSnap(), 0, "nobody compliant");
        assertEq(circle.bonusBase(), acc1 + acc2);
        assertEq(circle.memberState(people[1]).accShares, acc1, "uncapped");
        assertEq(circle.forfeitSnap(), exitForfeit);

        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 bonus1 = Math.mulDiv(exitForfeit, acc1, acc1 + acc2);
        uint256 gross1 = Math.mulDiv(acc1 + bonus1, nav + 1, total + VS);
        assertGt(gross1, 11 * C, "above principal");
        uint256 fee1 = (gross1 - 11 * C) * 1_500 / 10_000;
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(people[1], 11 * C, gross1, fee1, false);
        circle.settleMember(people[1]);
        assertEq(usdc.balanceOf(people[1]), gross1 - fee1);
        assertEq(usdc.balanceOf(treasury), fee1, "the fee on earnings, although nobody is compliant");
        circle.settleMember(people[2]);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        _assertBuckets();
    }

    function test_settleMember_lastSettlementClosesAndSweeps() public {
        _startYield(3, 1_000);
        _runRounds(_everyone(), 2, 1 << 5);
        morpho.mockYield(70e6);
        _mature();
        circle.finalize();
        circle.settleMember(people[0]);
        circle.settleMember(people[1]);
        vm.expectRevert(IMHCircle.NotEnded.selector);
        circle.sweepResidual();
        vm.expectEmit(false, false, false, false, address(circle));
        emit IMHAccumulationCircle.CircleClosed();
        circle.settleMember(people[2]);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        assertEq(circle.forfeitShares(), 0, "bonus dust moved to residual");
        assertEq(circle.totalShares(), circle.residualShares());
        _assertBuckets();

        uint256 fees = usdc.balanceOf(treasury);
        uint256 assets = circle.idleAssets();
        uint256 vShares = circle.vaultShares();
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ResidualSwept(treasury, assets, vShares);
        circle.sweepResidual();
        assertEq(usdc.balanceOf(treasury), fees + assets);
        assertEq(morpho.balanceOf(treasury), vShares);
        assertEq(circle.totalShares(), 0);
        assertEq(circle.nav(), 0);
        assertEq(usdc.balanceOf(address(circle)), 0);
        assertEq(morpho.balanceOf(address(circle)), 0);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepResidual();
        // Members: compliant ≥ principal, delinquent exactly principal; dust only to the treasury.
        assertGt(_net(people[0]), 0);
        assertLe(_net(people[2]), 0, "delinquent: at most principal");
        assertGe(_net(people[2]), -1, "delinquent: principal up to one unit of floor rounding");
        assertLe(vShares == 0 ? assets : assets + morpho.convertToAssets(vShares), 2, "residual is dust");
    }

    function test_settleMember_reverts() public {
        _startYield(2, 0);
        _runRounds(_everyone(), 0, 0);
        vm.expectRevert(IMHCircle.NotMatured.selector);
        circle.settleMember(people[0]);
        _mature();
        circle.finalize();
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.settleMember(attacker);
        morpho.mockSetLiquidity(0);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.settleMember(people[0]);
        morpho.mockSetLiquidity(type(uint256).max);
        circle.settleMember(people[0]);
        vm.expectRevert(IMHCircle.AlreadySettled.selector);
        circle.settleMember(people[0]);
    }

    function test_settleMember_blacklistedPayeesAreQueued() public {
        _startYield(2, 1_000);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(48e6);
        _mature();
        circle.finalize();
        usdc.blacklist(people[0]);
        usdc.blacklist(treasury);
        uint256 value = circle.memberValue(people[0]);
        uint256 fee = (value - 12 * C) / 10;
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.PayoutQueued(people[0], value - fee);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.PayoutQueued(treasury, fee);
        circle.settleMember(people[0]);
        assertEq(circle.owed(people[0]), value - fee);
        assertEq(circle.owed(treasury), fee);
        _assertBuckets();

        usdc.unBlacklist(people[0]);
        vm.prank(people[0]);
        circle.claimOwed();
        assertEq(usdc.balanceOf(people[0]), value - fee);
        _assertBuckets();
    }

    // ================================================================ settleMemberInKind

    function test_settleMemberInKind_proRataWithFee() public {
        _startYield(3, 1_000);
        for (uint256 r = 1; r <= 12; ++r) {
            _openRound(r);
            _payAll(r, r == 5 ? _allBut(2) : _everyone());
            if (r < 12) _deploy(); // round 12 stays idle, so both in-kind parts are non-zero
        }
        morpho.mockYield(70e6);
        _mature();
        circle.finalize();
        assertEq(circle.idleAssets(), 3 * C);

        address a = people[0];
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        uint256 acc = circle.memberState(a).accShares;
        uint256 shares = acc + Math.mulDiv(circle.forfeitSnap(), acc, circle.compliantSnap());
        uint256 gross = Math.mulDiv(shares, nav + 1, total + VS);
        uint256 fee = (gross - 12 * C) * 1_000 / 10_000;
        uint256 assets = Math.mulDiv(circle.idleAssets(), shares, total + VS);
        uint256 vs = Math.mulDiv(circle.vaultShares(), shares, total + VS);
        uint256 feeAssets = assets * fee / gross;
        uint256 feeVs = vs * fee / gross;

        morpho.mockSetLiquidity(0); // in kind works while the vault is illiquid
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettledInKind(
            a, 12 * C, assets - feeAssets, vs - feeVs, feeAssets, feeVs
        );
        vm.prank(a);
        circle.settleMemberInKind(a);

        assertEq(usdc.balanceOf(a), assets - feeAssets);
        assertEq(morpho.balanceOf(a), vs - feeVs);
        assertEq(usdc.balanceOf(treasury), feeAssets);
        assertEq(morpho.balanceOf(treasury), feeVs);
        assertEq(circle.memberState(a).cashOut, assets - feeAssets, "cashOut counts USDC only");
        assertTrue(circle.memberState(a).settled);
        // Value delivered never exceeds the cash entitlement.
        assertLe(assets + morpho.convertToAssets(vs), gross);
        assertApproxEqAbs(assets + morpho.convertToAssets(vs), gross, 2);
        _assertBuckets();
    }

    function test_settleMemberInKind_reverts() public {
        _startYield(2, 0);
        _runRounds(_everyone(), 0, 0);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.NotMatured.selector);
        circle.settleMemberInKind(people[0]);
        _mature();
        circle.finalize();
        vm.prank(attacker); // nobody can force vault shares on a member
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.settleMemberInKind(people[0]);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotMember.selector);
        circle.settleMemberInKind(attacker);
        vm.prank(people[0]);
        circle.settleMemberInKind(people[0]);
        vm.prank(people[0]);
        vm.expectRevert(IMHCircle.AlreadySettled.selector);
        circle.settleMemberInKind(people[0]);
    }

    /// @dev The last member to leave in kind from an all-idle pool gets `floor(idle·shares/(T+1e6))`: the
    ///      virtual-share remainder stays behind for the residual sweep, so in kind never beats cash.
    function test_settleMemberInKind_lastLeaverLeavesVirtualDust() public {
        _startYield(2, 0);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(24e6);
        vm.prank(guardian);
        circle.emergencyExit(type(uint256).max); // everything idle
        assertEq(circle.vaultShares(), 0);
        _mature();
        circle.finalize();
        vm.prank(people[0]);
        circle.settleMemberInKind(people[0]);
        uint256 idle = circle.idleAssets();
        uint256 total = circle.totalShares();
        uint256 shares = circle.memberState(people[1]).accShares;
        assertEq(shares, total, "last member holds every share");
        uint256 expected = idle * shares / (total + VS);
        assertLt(expected, idle, "the virtual shares keep a remainder");
        vm.prank(people[1]);
        circle.settleMemberInKind(people[1]);
        assertEq(usdc.balanceOf(people[1]), expected);
        assertEq(circle.idleAssets(), idle - expected);
        circle.sweepResidual();
        assertEq(usdc.balanceOf(treasury), idle - expected);
    }

    /// @dev A member who paid every round and then exited is not compliant.
    function test_memberState_exitedAfterPayingEveryRoundIsNotCompliant() public {
        _start(2, 1, 0, address(0), false);
        _payAll(1, _everyone());
        assertTrue(circle.memberState(people[0]).compliant);
        vm.prank(people[0]);
        circle.exitEarly();
        assertFalse(circle.memberState(people[0]).compliant);
        assertTrue(circle.memberState(people[1]).compliant);
    }

    // ================================================================ guardianCancel, claim, claimInKind

    function test_guardianCancel_unwindsBySharesAndPaysClaims() public {
        _startYield(3, 1_500);
        _runFirstRounds(3);
        morpho.mockYield(90e6);
        vm.prank(people[0]);
        circle.exitEarly(); // creates an exit forfeit
        uint256 forfeit = circle.forfeitShares();
        uint256 acc1 = circle.memberState(people[1]).accShares;
        uint256 acc2 = circle.memberState(people[2]).accShares;
        uint256 claim1 = acc1 + Math.mulDiv(forfeit, acc1, acc1 + acc2);
        uint256 claim2 = acc2 + Math.mulDiv(forfeit, acc2, acc1 + acc2);
        uint256 dust = acc1 + acc2 + forfeit - claim1 - claim2;

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ClaimAssigned(people[1], acc1, claim1);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ClaimAssigned(people[2], acc2, claim2);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.CircleCancelled(
            IMHAccumulationCircle.CancelReason.Guardian, claim1 + claim2, dust
        );
        vm.recordLogs();
        vm.prank(guardian);
        circle.guardianCancel();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 assignedEvents;
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics[0] == IMHAccumulationCircle.ClaimAssigned.selector) ++assignedEvents;
        }
        assertEq(assignedEvents, 2, "no claim for the member who already left");

        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        assertEq(circle.memberState(people[1]).claimShares, claim1);
        assertEq(circle.accTotal(), 0);
        assertEq(circle.forfeitShares(), 0);
        assertEq(circle.claimTotal(), claim1 + claim2);
        _assertBuckets();

        vm.expectRevert(IMHCircle.NotEnded.selector);
        circle.sweepResidual();

        // Cash claim.
        uint256 expected = _toAssets(claim1);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.Claimed(people[1], expected);
        vm.prank(people[1]);
        assertEq(circle.claim(), expected);
        assertEq(usdc.balanceOf(people[1]), expected);
        assertGt(_net(people[1]), 0, "kept the yield, no fee");
        vm.prank(people[1]);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.claim();
        _assertBuckets();

        // In-kind claim while illiquid.
        morpho.mockSetLiquidity(0);
        uint256 total = circle.totalShares();
        uint256 assets = Math.mulDiv(circle.idleAssets(), claim2, total + VS);
        uint256 vs = Math.mulDiv(circle.vaultShares(), claim2, total + VS);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.ClaimedInKind(people[2], assets, vs);
        vm.prank(people[2]);
        circle.claimInKind();
        assertEq(morpho.balanceOf(people[2]), vs);
        vm.prank(people[2]);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.claimInKind();
        assertEq(usdc.balanceOf(treasury), 0, "no fee on cancellations");
        _assertBuckets();

        circle.sweepResidual(); // only dust is left
        assertLe(usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury)), 2);
    }

    function test_guardianCancel_reverts() public {
        _create(_params(2, 12, 0, address(morpho), false));
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.guardianCancel();
        _join(people[0]);
        _join(people[1]);
        address[5] memory notGuardian = [attacker, operator, treasury, address(timelock), gov];
        for (uint256 i; i < notGuardian.length; ++i) {
            vm.prank(notGuardian[i]);
            vm.expectRevert(IMHCircle.NotGuardian.selector);
            circle.guardianCancel();
        }
        vm.warp(circle.startTime());
        _mature();
        circle.finalize();
        vm.prank(guardian);
        circle.guardianCancel(); // Matured: allowed since audit R1-03
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.guardianCancel();

        // Closed: refused.
        _startYield(2, 0);
        _runRounds(_everyone(), 0, 0);
        _mature();
        circle.finalize();
        _settleAll();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.guardianCancel();
    }

    // ================================================================ emergencyExit, pullFromVault

    function test_emergencyExit_chunked() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        uint256 held = circle.vaultShares();
        morpho.mockSetLiquidity(C);
        uint256 chunk = morpho.previewWithdraw(C) - 1; // a hair under the liquid amount

        vm.expectEmit(false, false, false, false, address(circle));
        emit IMHAccumulationCircle.YieldDisabled();
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.EmergencyExited(chunk, morpho.previewRedeem(chunk));
        vm.prank(guardian);
        circle.emergencyExit(chunk);
        assertTrue(circle.yieldOff());
        assertEq(circle.vaultShares(), held - chunk);
        assertApproxEqAbs(circle.idleAssets(), C, 1);
        _assertBuckets();

        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: illiquid")); // one chunk too many reverts as a whole
        circle.emergencyExit(type(uint256).max);

        morpho.mockSetLiquidity(type(uint256).max);
        vm.prank(guardian);
        circle.emergencyExit(type(uint256).max); // capped at what the circle holds
        assertEq(circle.vaultShares(), 0);
        assertApproxEqAbs(circle.idleAssets(), 3 * C, 1);
        _assertBuckets();
    }

    function test_emergencyExit_zeroOnlySwitchesYieldOffEvenWhenIlliquid() public {
        _startYield(2, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        morpho.mockSetLiquidity(0);
        morpho.mockSetExitsBlocked(true);
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.EmergencyExited(0, 0);
        vm.prank(guardian);
        circle.emergencyExit(0);
        assertTrue(circle.yieldOff());
        vm.prank(guardian);
        circle.emergencyExit(0); // idempotent
    }

    function test_emergencyExit_reverts() public {
        _startYield(2, 0);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.emergencyExit(1);
        vm.prank(address(timelock));
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.emergencyExit(1);
        _start(2, 12, 0, address(0), false);
        vm.prank(guardian);
        vm.expectRevert(IMHAccumulationCircle.NoYield.selector);
        circle.emergencyExit(1);
    }

    function test_pullFromVault() public {
        _startYield(2, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        vm.expectRevert(IMHCircle.YieldOn.selector);
        circle.pullFromVault(1);
        vm.prank(guardian);
        circle.emergencyExit(0);

        uint256 half = circle.vaultShares() / 2;
        uint256 assets = morpho.previewRedeem(half);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.PulledFromVault(attacker, half, assets);
        vm.prank(attacker);
        circle.pullFromVault(half);
        assertEq(circle.idleAssets(), assets);
        circle.pullFromVault(type(uint256).max);
        assertEq(circle.vaultShares(), 0);
        assertEq(circle.idleAssets(), 2 * C);
        vm.expectRevert(IMHAccumulationCircle.ZeroAmount.selector);
        circle.pullFromVault(1);
        _assertBuckets();
    }

    // ================================================================ extendDeadline

    function test_extendDeadline() public {
        _create(_params(2, 12, 0, address(0), false));
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.extendDeadline(1 days);
        _join(people[0]);
        _join(people[1]);
        uint256 d1 = circle.roundDeadline(1);

        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        circle.extendDeadline(1 days);
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(0);
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(7 days + 1);

        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.DeadlineExtended(7 days, 7 days);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        assertEq(circle.roundDeadline(1), d1 + 7 days);
        for (uint256 i; i < 3; ++i) {
            vm.prank(guardian);
            circle.extendDeadline(7 days);
        }
        vm.prank(guardian);
        circle.extendDeadline(2 days);
        assertEq(circle.extension(), 30 days);
        vm.prank(guardian);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(1);
    }

    // ================================================================ Sweeps

    function test_sweepDonations() public {
        _startYield(2, 0);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepDonations();
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _pay(people[0], 2);

        usdc.mint(address(circle), 5e6);
        usdc.mint(attacker, 10e6);
        vm.startPrank(attacker);
        usdc.approve(address(morpho), 10e6);
        uint256 donated = morpho.deposit(10e6, address(circle));
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.DonationsSwept(treasury, 5e6, donated);
        circle.sweepDonations();
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(morpho.balanceOf(treasury), donated);
        _assertBuckets();
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepDonations();
    }

    function test_sweepDonations_neverTouchesOwed() public {
        _start(2, 1, 0, address(0), false);
        _payAll(1, _everyone());
        _mature();
        circle.finalize();
        usdc.blacklist(people[0]);
        circle.settleMember(people[0]); // queued in owed
        assertEq(circle.owed(people[0]), C);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepDonations();
    }

    function test_sweepResidual_reverts() public {
        _startYield(2, 0);
        vm.expectRevert(IMHCircle.NotEnded.selector);
        circle.sweepResidual();
        _runRounds(_everyone(), 0, 0);
        _mature();
        circle.finalize();
        vm.expectRevert(IMHCircle.NotEnded.selector);
        circle.sweepResidual();
    }

    // ================================================================ Views

    function test_views() public {
        _startYield(2, 0);
        assertEq(circle.currentRound(), 1);
        assertEq(circle.roundDeadline(1), circle.startTime() + ROUND);
        _pay(people[0], 1);
        assertTrue(circle.paid(1, people[0]));
        assertFalse(circle.paid(1, attacker));
        assertFalse(circle.paid(0, people[0]));
        assertEq(circle.memberValue(people[0]), C);
        assertEq(circle.memberValue(attacker), 0);
        IMHAccumulationCircle.MemberState memory st = circle.memberState(attacker);
        assertEq(st.slot, 0);
        assertFalse(st.compliant);
        // Paid bits are a bitmap: round 256 and 257 share a word with nothing else.
        _start(2, 300, 0, address(0), false);
        vm.warp(circle.startTime() + 255 * uint256(ROUND));
        assertEq(circle.currentRound(), 256);
        _pay(people[0], 256);
        _openRound(257);
        _pay(people[0], 257);
        assertTrue(circle.paid(256, people[0]));
        assertTrue(circle.paid(257, people[0]));
        assertFalse(circle.paid(255, people[0]));
        assertEq(circle.memberState(people[0]).paidRounds, 2);
    }

    // ================================================================ Helpers

    /// @dev Every member pays rounds 1..k and the keeper deploys after each.
    function _runFirstRounds(uint256 k) internal {
        for (uint256 r = 1; r <= k; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            _deploy();
        }
    }
}
