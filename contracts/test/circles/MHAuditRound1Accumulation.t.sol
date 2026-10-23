// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";

import { MockVaultV2, MockAdapterV2 } from "../mocks/MockVaultV2.sol";

/// @notice Audit round 1 regressions for `MHAccumulationCircle`, `MHCircleBase._pay` and `MHCircleRegistry`, built
///         from the verifiers' PoCs (scratchpad `audit/r1-verify-R1-{03,04,09,10,11,12,14,15}-*`). Each PoC scenario
///         is replayed and now asserts the fixed outcome.
contract MHAuditRound1AccumulationTest is AccumulationFixture {
    uint256 internal constant D = 3;
    uint256 internal constant SKIP_D = (1 << 4) | (1 << 8); // spec §4.5 example: D misses rounds 4 and 8

    function _treasuryValue() internal view returns (uint256) {
        return
            usdc.balanceOf(treasury) + circle.owed(treasury)
                + morpho.convertToAssets(morpho.balanceOf(treasury));
    }

    // ================================================================ R1-03: a vault that cannot value its shares

    /// @dev PoC R1-03 (verifier 1) setup: 4 members, $100, 2 rounds, 10% fee; round 1 deployed, round 2 ($400)
    ///      idle; finalized; then the vault's accrual reverts.
    function _maturedThenBroken() internal returns (MHAccumulationCircle c) {
        c = _start(4, 2, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        morpho.mockYield(8e6);
        _openRound(2);
        _payAll(2, _everyone());
        assertEq(c.idleAssets(), 400e6);
        _mature();
        c.finalize();
        assertEq(uint8(c.status()), uint8(CircleStatus.Matured));
        morpho.mockSetNavBroken(true);
    }

    /// @dev `test_matured_navRevert_noExit_idleFrozen`: every exit used to revert until the curator repaired the
    ///      vault, the $400 that never touched it included. The Guardian's Matured cancel is now the NAV-free exit:
    ///      each member takes its idle USDC and vault shares in kind, while the vault stays broken.
    function test_R1_03_maturedBrokenVault_guardianCancelThenClaimInKind() public {
        MHAccumulationCircle c = _maturedThenBroken();
        vm.expectRevert();
        c.settleMember(people[0]);
        vm.prank(people[0]);
        vm.expectRevert();
        c.settleMemberInKind(people[0]);

        vm.prank(guardian);
        c.guardianCancel();
        assertEq(uint8(c.status()), uint8(CircleStatus.Cancelled));
        for (uint256 i; i < 4; ++i) {
            vm.prank(people[i]);
            (uint256 assets, uint256 vShares) = c.claimInKind();
            assertGe(assets, 99e6, "its share of the idle $400");
            assertGt(vShares, 0, "and its vault shares");
        }
        assertLe(c.idleAssets(), 1, "the idle USDC is out");
        _assertBucketsNoNav(c);
        // Once the curator repairs the vault the members redeem their shares: everyone got principal + yield.
        morpho.mockSetNavBroken(false);
        for (uint256 i; i < 4; ++i) {
            uint256 s = morpho.balanceOf(people[i]);
            vm.prank(people[i]);
            morpho.redeem(s, people[i], people[i]);
            assertApproxEqAbs(_net(people[i]), 2e6, 2, "principal + its quarter of the $8 yield, no fee");
        }
    }

    /// @dev `test_matured_dustShare_freezesAllIdle`: a chunked emergency exit left one vault share; the broken
    ///      vault used to freeze all $808 of idle USDC with it.
    function test_R1_03_dustShareVariant_idleStillReachable() public {
        MHAccumulationCircle c = _start(4, 2, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        _openRound(2);
        _payAll(2, _everyone());
        _mature();
        c.finalize();
        uint256 vs = c.vaultShares();
        vm.prank(guardian);
        c.emergencyExit(vs - 1);
        assertEq(c.vaultShares(), 1);
        morpho.mockSetNavBroken(true);
        vm.prank(guardian);
        c.guardianCancel();
        for (uint256 i; i < 4; ++i) {
            vm.prank(people[i]);
            (uint256 assets,) = c.claimInKind();
            assertGe(assets, 199e6, "its share of the idle USDC");
        }
    }

    /// @dev The Matured cancel applies the finalize outcomes (spec §4.5 example): D stays capped at its $1,000 and
    ///      the compliant members get exactly the bonus `settleMember` would have given them; no fee is charged.
    function test_R1_03_maturedCancel_keepsFinalizeOutcomes() public {
        _startYield(4, 1_000);
        _runRounds(_everyone(), D, SKIP_D);
        morpho.mockYield(115e6);
        circle.flagRound(4);
        circle.flagRound(8);
        _mature();
        circle.finalize();
        uint256 accA = circle.memberState(people[0]).accShares;
        uint256 accD = circle.memberState(people[D]).accShares;
        uint256 bonusA = Math.mulDiv(circle.forfeitSnap(), accA, circle.compliantSnap());
        circle.settleMember(people[1]); // one member settled before the cancel
        vm.prank(guardian);
        circle.guardianCancel();
        assertEq(circle.memberState(people[0]).claimShares, accA + bonusA, "compliant: acc + bonus");
        assertEq(circle.memberState(people[D]).claimShares, accD, "delinquent: its capped shares, no bonus");
        assertEq(circle.memberState(people[1]).claimShares, 0, "already settled");
        _assertBuckets();
        vm.prank(people[0]);
        circle.claim();
        vm.prank(people[D]);
        circle.claim();
        assertApproxEqAbs(usdc.balanceOf(people[0]), 1_238_333_333, 2, "$1,238.33, no fee");
        assertApproxEqAbs(usdc.balanceOf(people[D]), 1_000e6, 1, "D: $1,000");
    }

    /// @dev `test_active_navRevert_strikesAndForfeits`: while the vault could not value shares nobody could pay,
    ///      yet `flagRound` struck them and finalize later capped them. `flagRound` now reverts during the outage,
    ///      which gives the Guardian time to extend the deadline; after the repair the members pay normally.
    function test_R1_03_activeBrokenVault_noStrikesWhileNobodyCanPay() public {
        MHAccumulationCircle c = _start(4, 3, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        _openRound(2);
        _payAll(2, _everyone());
        c.deployIdle();
        morpho.mockYield(40e6);
        _openRound(3);
        _pay(people[0], 3);
        c.deployIdle();
        morpho.mockSetNavBroken(true);
        for (uint256 i = 1; i < 4; ++i) {
            _fund(people[i], C);
            vm.prank(people[i]);
            vm.expectRevert();
            c.contribute(3, C);
        }
        _afterCure(3);
        vm.prank(people[0]);
        vm.expectRevert(); // the vault's error: no strike while members cannot pay
        c.flagRound(3);
        vm.prank(guardian);
        c.extendDeadline(7 days); // the Guardian's response to the outage (runbook)
        morpho.mockSetNavBroken(false);
        for (uint256 i = 1; i < 4; ++i) {
            vm.prank(people[i]);
            c.contribute(3, C);
        }
        _afterCure(3);
        c.flagRound(3);
        for (uint256 i; i < 4; ++i) {
            assertEq(reputation.strikeCount(people[i]), 0, "nobody missed");
        }
        c.finalize();
        assertEq(c.forfeitSnap(), 0, "nobody capped");
    }

    /// @dev Bucket identity without reading NAV (the vault is broken).
    function _assertBucketsNoNav(MHAccumulationCircle c) internal view {
        address[] memory m = c.members();
        uint256 acc;
        uint256 claims;
        for (uint256 i; i < m.length; ++i) {
            acc += c.memberState(m[i]).accShares;
            claims += c.memberState(m[i]).claimShares;
        }
        assertEq(acc + claims + c.forfeitShares() + c.residualShares(), c.totalShares(), "share buckets");
        assertEq(usdc.balanceOf(address(c)), c.idleAssets() + c.owedTotal(), "usdc tracked");
        assertEq(morpho.balanceOf(address(c)), c.vaultShares() + c.owedSharesTotal(), "vault shares tracked");
    }

    // ================================================================ R1-09: everyone exits early

    function _sixRoundsThenExitAll(uint16 fee, uint256 postExitYield) internal {
        _startYield(2, fee);
        for (uint256 r = 1; r <= 6; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            _deploy();
        }
        morpho.mockYield(120e6);
        _openRound(7);
        vm.prank(people[0]);
        assertEq(circle.exitEarly(), 600e6);
        vm.prank(people[1]);
        assertEq(circle.exitEarly(), 600e6);
        if (postExitYield != 0) morpho.mockYield(postExitYield);
        _mature();
        circle.finalize();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        for (uint256 i; i < 2; ++i) {
            vm.prank(people[i]);
            circle.claim();
        }
        circle.sweepResidual();
    }

    /// @dev `test_R109_allExit_feeZero_treasuryTakesAllYield`: the treasury used to collect the whole $120 of
    ///      yield (100% of earnings). Now each exited member gets its own forfeited yield back.
    function test_R1_09_allExit_fee0_yieldBackToMembers() public {
        _sixRoundsThenExitAll(0, 0);
        assertApproxEqAbs(_net(people[0]), 60e6, 2);
        assertApproxEqAbs(_net(people[1]), 60e6, 2);
        assertLe(_treasuryValue(), 3, "dust only");
    }

    /// @dev With a 15% fee the treasury takes exactly the normal fee on those earnings, never more.
    function test_R1_09_allExit_fee15_onlyTheNormalFee() public {
        _sixRoundsThenExitAll(1_500, 0);
        assertApproxEqAbs(_net(people[0]), 51e6, 2);
        assertApproxEqAbs(_net(people[1]), 51e6, 2);
        assertApproxEqAbs(_treasuryValue(), 18e6, 3, "15% of $120");
    }

    /// @dev `test_R109_allExit_postExitYieldAlsoToTreasury`: yield earned on the forfeit pool after the exits now
    ///      goes back to the members as well.
    function test_R1_09_allExit_postExitYieldAlsoReturned() public {
        _sixRoundsThenExitAll(0, 5e6);
        assertApproxEqAbs(_net(people[0]) + _net(people[1]), 125e6, 3);
        assertLe(_treasuryValue(), 3);
    }

    /// @dev R1-03 × R1-09: a Matured circle can already hold claims (returned exit forfeits) when the Guardian
    ///      cancels it; the cancel adds to them instead of overwriting `claimTotal`.
    function test_R1_03_maturedCancel_keepsReturnedForfeitClaims() public {
        _startYield(3, 0);
        for (uint256 r = 1; r <= 3; ++r) {
            _openRound(r);
            _payAll(r, _allBut(2)); // member 2 never pays: it holds nothing at maturity
            _deploy();
        }
        morpho.mockYield(30e6);
        _openRound(4);
        vm.prank(people[0]);
        circle.exitEarly();
        vm.prank(people[1]);
        circle.exitEarly();
        _mature();
        circle.finalize();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Matured), "member 2 still unsettled");
        uint256 returned = circle.claimTotal();
        assertGt(returned, 0, "the exits' forfeits came back as claims");
        vm.prank(guardian);
        circle.guardianCancel();
        assertEq(circle.claimTotal(), returned, "claims kept");
        _assertBuckets();
        for (uint256 i; i < 2; ++i) {
            vm.prank(people[i]);
            circle.claim();
        }
        assertApproxEqAbs(_net(people[0]) + _net(people[1]), 30e6, 3);
    }

    // ================================================================ R1-10: all-delinquent fee waiver

    uint256 internal constant RATE_PPM = 3_863; // ~4.7% APY per 30-day round

    function _accrue() internal {
        uint256 nav = circle.nav();
        if (nav > 0) morpho.mockYield(nav * RATE_PPM / 1e6);
    }

    /// @dev PoC R1-10 scenario: per-round accrual; `payersLast` pay the last round.
    function _r110(uint256 n, uint16 fee, uint256 payersLast)
        internal
        returns (int256[] memory nets, uint256 t)
    {
        _startYield(n, fee);
        uint256 rounds = circle.totalRounds();
        for (uint256 r = 1; r <= rounds; ++r) {
            _openRound(r);
            if (r > 1) _accrue();
            _payAll(r, r == rounds ? payersLast : _everyone());
            _deploy();
        }
        _accrue();
        _mature();
        if (payersLast != _everyone()) circle.flagRound(rounds);
        circle.finalize();
        _settleAll();
        nets = new int256[](n);
        for (uint256 i; i < n; ++i) {
            nets[i] = _net(people[i]);
        }
        t = _treasuryValue();
    }

    /// @dev `test_n4_fee1500_allSkipLast` / `test_n2_fee1500_allSkipLast`: everyone skipping the last round used
    ///      to waive the fee and leave every member better off than paying. Now the fee is charged and skipping
    ///      never beats paying.
    function test_R1_10_universalDelinquency_doesNotWaiveTheFee() public {
        uint256[2] memory ns = [uint256(2), 4];
        uint256 snap = vm.snapshotState();
        for (uint256 k; k < 2; ++k) {
            uint256 n = ns[k];
            (int256[] memory honest, uint256 tHonest) = _r110(n, 1_500, _everyone());
            vm.revertToState(snap);
            (int256[] memory skip, uint256 tSkip) = _r110(n, 1_500, 0);
            assertEq(circle.compliantSnap(), 0, "nobody compliant");
            assertGt(tSkip, 0, "the fee is charged");
            assertApproxEqRel(tSkip, tHonest, 0.05e18, "about the same fee as when everyone pays");
            for (uint256 i; i < n; ++i) {
                assertLe(skip[i], honest[i], "skipping the last round never pays");
                assertEq(reputation.strikesByReason(people[i], IMHReputation.Reason.MISSED), 1);
            }
            vm.revertToState(snap);
        }
    }

    /// @dev PoC R1-09 `test_R109_lastMemberStays_getsAllYield`: the member that stops paying instead of exiting
    ///      (all-delinquent) now pays the 15% fee on the whole yield it takes.
    function test_R1_10_lastMemberStaysDelinquent_paysTheFee() public {
        _startYield(2, 1_500);
        for (uint256 r = 1; r <= 6; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            _deploy();
        }
        morpho.mockYield(120e6);
        _openRound(7);
        vm.prank(people[0]);
        circle.exitEarly();
        _mature();
        circle.finalize();
        assertEq(circle.compliantSnap(), 0);
        circle.settleMember(people[1]);
        assertApproxEqAbs(_net(people[1]), 102e6, 2, "the $120 less the 15% fee");
        assertApproxEqAbs(_treasuryValue(), 18e6, 2);
    }

    // ================================================================ R1-11: post-maturity yield on capped shares

    function _specExample(uint16 fee) internal {
        _startYield(4, fee);
        _runRounds(_everyone(), D, SKIP_D);
        assertEq(circle.nav(), 4_600e6);
        morpho.mockYield(115e6);
        circle.flagRound(4);
        circle.flagRound(8);
        _mature();
    }

    /// @dev `test_R1_11_fee0_delayedDelinquent_treasuryTakesYield`: D settled 90 days late used to get exactly
    ///      $1,000 while the treasury took the ~$11.66 of yield on its retained shares in a 0%-fee circle. D now
    ///      keeps that yield and the treasury gets dust only.
    function test_R1_11_delayedDelinquent_keepsItsPostMaturityYield() public {
        _specExample(0);
        circle.finalize();
        for (uint256 i; i < 3; ++i) {
            circle.settleMember(people[i]);
        }
        uint256 nav = circle.nav();
        vm.warp(block.timestamp + 90 days);
        morpho.mockYield(nav * 117 / 10_000);
        circle.settleMember(people[D]);
        assertApproxEqAbs(usdc.balanceOf(people[D]), 1_000e6 + 11_700_000, 2, "principal + its own yield");
        circle.sweepResidual();
        assertLe(_treasuryValue(), 5, "dust only in a 0%-fee circle (bonus rounding)");
    }

    /// @dev `test_R1_11_fee10_promptVsDelayed`: with a 10% fee, post-maturity yield on D's shares no longer goes
    ///      100% to the treasury; the treasury's take is the fee on compliant earnings only.
    function test_R1_11_fee10_treasuryTakesOnlyFees() public {
        _specExample(1_000);
        circle.finalize();
        uint256 nav0 = circle.nav();
        morpho.mockYield(nav0 / 100); // +1% after maturity
        _settleAll();
        circle.sweepResidual();
        // A, B, C: gross = 1,238.333 × 1.01 = 1,250.717, earnings 50.717 each, fee 5.0717 each.
        assertApproxEqAbs(_treasuryValue(), 15_215_000, 5, "three fees on earnings, nothing from D");
        assertApproxEqAbs(usdc.balanceOf(people[D]), 1_010e6, 2, "D: $1,000 + 1%");
    }

    // ================================================================ R1-12: the allowlist is a snapshot

    function _curatorWeakensAfter7Days() internal {
        vm.warp(block.timestamp + 7 days);
        morpho.mockSetTimelock(IVaultV2.addAdapter.selector, 0);
        morpho.mockSetTimelock(IVaultV2.setIsAllocator.selector, 0);
    }

    /// @dev `test_R1_12_snapshotMechanism_noGuardianReaction`: after the curator weakened the vault, a new yield
    ///      circle used to be created and deposit into it. Now creation is refused, a pending circle activates with
    ///      yield off, and anyone can delist the vault.
    function test_R1_12_weakenedVault_refusedLiveAndDelistable() public {
        MHAccumulationCircle pending = _create(_params(3, 3, 1_000, address(morpho), false));
        _curatorWeakensAfter7Days();
        assertTrue(registry.isAllowedVault(address(morpho)), "still on the list");
        assertFalse(registry.vaultSafe(address(morpho)), "but not safe");

        vm.prank(operator);
        vm.expectRevert(IMHCircle.BadConfig.selector);
        factory.createAccumulation(_params(3, 3, 1_000, address(morpho), false));

        circle = pending;
        for (uint256 i; i < 3; ++i) {
            _join(people[i]);
        }
        assertEq(uint8(pending.status()), uint8(CircleStatus.Active));
        assertFalse(pending.yieldOff(), "activation latches nothing (audit 2 R2-01) ...");
        vm.warp(pending.startTime());
        _payAll(1, _everyone());
        uint256 snap = vm.snapshotState();
        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultDisallowed(address(morpho));
        vm.prank(attacker); // anyone
        assertTrue(registry.revalidateVault(address(morpho)));
        assertFalse(registry.isAllowedVault(address(morpho)));
        vm.revertToState(snap);

        // ... but nothing reaches the weakened vault. Closing review: `deployIdle` itself delists it (sticky until Gov
        // re-allows) and returns without depositing; the next call reverts `VaultUnsafe`.
        uint256 idle = pending.idleAssets();
        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultDisallowed(address(morpho));
        vm.prank(attacker);
        pending.deployIdle();
        assertEq(pending.idleAssets(), idle, "nothing deposited");
        assertEq(pending.vaultShares(), 0);
        assertFalse(registry.isAllowedVault(address(morpho)), "delisted by deployIdle");
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        pending.deployIdle();
    }

    /// @dev A vault that still passes cannot be delisted by anyone.
    function test_R1_12_revalidate_noopWhileSafe() public {
        vm.prank(attacker);
        assertFalse(registry.revalidateVault(address(morpho)));
        assertTrue(registry.isAllowedVault(address(morpho)));
        assertFalse(registry.revalidateVault(makeAddr("neverAllowed")));
    }

    // ================================================================ R1-14: blacklisted member, in-kind exits

    function _matured2() internal returns (MHAccumulationCircle c) {
        c = _start(2, 2, 0, address(morpho), false);
        _runRounds(_everyone(), 0, 0);
        _mature();
        c.finalize();
    }

    /// @dev `test_poc_settleMemberInKind_blacklistedRedeemsToClean`: the blacklisted member used to receive vault
    ///      shares it could redeem to a clean address. They are now queued in `owedShares` until the blacklist is
    ///      lifted.
    function test_R1_14_settleMemberInKind_queuesSharesForBlacklistedMember() public {
        MHAccumulationCircle c = _matured2();
        address bad = people[0];
        usdc.blacklist(bad);
        vm.prank(bad);
        c.settleMemberInKind(bad);
        assertEq(morpho.balanceOf(bad), 0, "no vault share reaches a blacklisted address");
        uint256 queued = c.owedShares(bad);
        assertGt(queued, 0);
        assertEq(c.owedSharesTotal(), queued);
        vm.prank(bad);
        vm.expectRevert(IMHAccumulationCircle.Blacklisted.selector);
        c.claimOwedShares();
        // Donations sweep never takes queued shares.
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        c.sweepDonations();

        usdc.unBlacklist(bad);
        vm.prank(bad);
        assertEq(c.claimOwedShares(), queued);
        assertEq(morpho.balanceOf(bad), queued);
        assertEq(c.owedSharesTotal(), 0);
        vm.prank(bad);
        vm.expectRevert(IMHCircle.NothingOwed.selector);
        c.claimOwedShares();
    }

    /// @dev `test_poc_claimInKind_afterCancel_blacklistedRedeemsToClean`.
    function test_R1_14_claimInKind_queuesSharesForBlacklistedMember() public {
        MHAccumulationCircle c = _start(2, 12, 0, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        _deploy();
        vm.prank(guardian);
        c.guardianCancel();
        usdc.blacklist(people[0]);
        vm.prank(people[0]);
        (, uint256 vShares) = c.claimInKind();
        assertGt(vShares, 0);
        assertEq(morpho.balanceOf(people[0]), 0);
        assertEq(c.owedShares(people[0]), vShares);
    }

    /// @dev The treasury's fee-share leg is queued too when the treasury is blacklisted; the member still exits.
    function test_R1_14_blacklistedTreasury_feeSharesQueued() public {
        MHAccumulationCircle c = _start(2, 2, 1_000, address(morpho), false);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(20e6);
        _mature();
        c.finalize();
        usdc.blacklist(treasury);
        vm.prank(people[0]);
        c.settleMemberInKind(people[0]);
        assertGt(morpho.balanceOf(people[0]), 0, "the member got its shares");
        assertGt(c.owedShares(treasury), 0, "the fee shares wait for the treasury");
        assertEq(morpho.balanceOf(treasury), 0);
    }

    // ================================================================ R1-15: the circle itself blacklisted

    /// @dev `test_R1_15_selfBlacklist_freezesEveryExit_whenIdlePositive`: with the circle blacklisted every exit
    ///      used to revert on its USDC leg. The USDC leg is now queued in `owed`, so the in-kind exits complete
    ///      and deliver the vault shares; the USDC follows once the blacklist is lifted.
    function test_R1_15_selfBlacklist_inKindExitsStillDeliverShares() public {
        MHAccumulationCircle c = _start(2, 2, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        _openRound(2);
        _payAll(2, _everyone()); // left idle
        morpho.mockYield(20e6);
        _mature();
        c.finalize();
        usdc.blacklist(address(c));

        vm.prank(people[0]);
        c.settleMemberInKind(people[0]);
        assertGt(morpho.balanceOf(people[0]), 0, "vault shares delivered");
        assertGt(c.owed(people[0]), 0, "idle USDC part queued");
        vm.prank(people[1]);
        c.settleMemberInKind(people[1]);
        assertGt(morpho.balanceOf(people[1]), 0);
        // Queued USDC cannot leave while the circle is blacklisted, and stays owed.
        vm.prank(people[0]);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        c.claimOwed();
        usdc.unBlacklist(address(c));
        vm.prank(people[0]);
        c.claimOwed();
        assertEq(c.owed(people[0]), 0);
    }

    /// @dev `test_R1_15_selfBlacklist_claimInKindReverts`.
    function test_R1_15_selfBlacklist_claimInKindWorks() public {
        MHAccumulationCircle c = _start(2, 3, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        _openRound(2);
        _payAll(2, _everyone());
        usdc.blacklist(address(c));
        vm.prank(guardian);
        c.guardianCancel();
        vm.prank(people[0]);
        (uint256 assets, uint256 vShares) = c.claimInKind();
        assertGt(vShares, 0);
        assertEq(c.owed(people[0]), assets, "USDC leg queued");
    }

    // ================================================================ R1-04: allowVault covers every curator power

    function _expectVaultCheck(MockVaultV2 v, bytes4 check) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMHCircleRegistry.VaultCheckFailed.selector, check));
        registry.allowVault(address(v));
    }

    function _allow(MockVaultV2 v) internal {
        vm.prank(address(timelock));
        registry.allowVault(address(v));
        assertTrue(registry.isAllowedVault(address(v)));
    }

    /// @dev PoC R1-04 (`R1AllowVaultRemoveAdapter`): a vault with `removeAdapter` timelocked 0 passed `allowVault`,
    ///      and the curator could write NAV down at once while anyone settled members at the depressed NAV. It is
    ///      now refused, as is every other short exposure timelock.
    function test_R1_04_allowVault_rejectsEveryShortCuratorTimelock() public {
        bytes4[2] memory slow = [IVaultV2.removeAdapter.selector, IVaultV2.setAdapterRegistry.selector];
        for (uint256 i; i < 2; ++i) {
            MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
            v.mockSetAbdicated(slow[i], false);
            v.mockSetTimelock(slow[i], 7 days - 1);
            _expectVaultCheck(v, slow[i]);
            v.mockSetTimelock(slow[i], 7 days);
            _allow(v);
        }
        bytes4[4] memory fast = [
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector
        ];
        for (uint256 i; i < 4; ++i) {
            MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
            v.mockSetTimelock(fast[i], 0); // e.g. Steakhouse's management fee
            _expectVaultCheck(v, fast[i]);
            v.mockSetTimelock(fast[i], 3 days - 1);
            _expectVaultCheck(v, fast[i]);
            v.mockSetAbdicated(fast[i], true);
            _allow(v);
        }
    }

    function test_R1_04_allowVault_requiresAnAdapterRegistry() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        v.mockSetAdapterRegistry(address(0));
        _expectVaultCheck(v, IVaultV2.adapterRegistry.selector);
    }

    /// @dev Each adapter's `burnShares` (a write-down) needs the 3-day window too; adapters without Morpho's
    ///      timelock views fail closed, and more than 16 adapters are refused.
    function test_R1_04_allowVault_checksEveryAdapter() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        MockAdapterV2 good = new MockAdapterV2();
        MockAdapterV2 bad = new MockAdapterV2();
        bad.mockSetTimelock(IMorphoMarketV1AdapterV2.burnShares.selector, 1 days);
        v.mockAddAdapter(address(good));
        _allow(v);

        v = new MockVaultV2(address(usdc), address(this));
        v.mockAddAdapter(address(good));
        v.mockAddAdapter(address(bad));
        _expectVaultCheck(v, IMorphoMarketV1AdapterV2.burnShares.selector);
        bad.mockSetAbdicated(IMorphoMarketV1AdapterV2.burnShares.selector, true);
        _allow(v);

        // Audit 2 R1-28: an adapter without Morpho's timelock views fails closed with the exact check, not just any
        // revert (kills mutants G03/G04, which loosen the bounded read's parsing).
        v = new MockVaultV2(address(usdc), address(this));
        v.mockAddAdapter(makeAddr("noTimelockViews"));
        _expectVaultCheck(v, IMorphoMarketV1AdapterV2.burnShares.selector);

        v = new MockVaultV2(address(usdc), address(this));
        for (uint256 i; i < 17; ++i) {
            v.mockAddAdapter(address(good));
        }
        _expectVaultCheck(v, IVaultV2.adaptersLength.selector);
    }

    /// @dev A curator-added adapter without Morpho's timelock views cannot brick circle creation or activation.
    ///      Audit R2-07 (was: `vaultSafe` stayed true): `vaultSafe` requires the adapter set recorded by `allowVault`,
    ///      so such an adapter makes the vault unsafe; new circles are refused and a circle activating on it cannot
    ///      deposit (audit 2 R2-01: nothing latched in the circle; closing review: `deployIdle` delists the vault and
    ///      returns, later calls revert `VaultUnsafe`), instead of reverting. (Since
    ///      audit 2 R1-10 `vaultSafe` also walks the adapters, with the same bounded, fail-closed reads.)
    function test_R1_04_vaultSafe_neverCallsAdapters_butAdapterChangeIsUnsafe() public {
        _create(_params(2, 2, 0, address(morpho), false)); // created while safe
        morpho.mockAddAdapter(makeAddr("noTimelockViews"));
        assertFalse(registry.vaultSafe(address(morpho)), "adapter set changed since allowVault");
        _join(people[0]);
        _join(people[1]); // activation does not revert ...
        vm.warp(circle.startTime());
        _payAll(1, _everyone());
        // ... and nothing reaches the vault: closing review, `deployIdle` delists it and deposits nothing.
        circle.deployIdle();
        assertEq(circle.vaultShares(), 0);
        assertEq(circle.idleAssets(), 2 * C);
        assertFalse(registry.isAllowedVault(address(morpho)), "delisted by deployIdle");
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        circle.deployIdle();
    }
}
