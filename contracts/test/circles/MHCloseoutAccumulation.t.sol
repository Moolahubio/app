// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";
import { MockAdapterV2 } from "../mocks/MockVaultV2.sol";

/// @notice A vault whose `previewRedeem` needs about 2.94M gas (an expensive but healthy valuation): it fails when given
///         less than 2.96M. Etched over the mock vault to test the `cancelExpired` probe's gas guard (B-R2-14 A63).
contract HungryPreview {
    fallback() external {
        uint256 start = gasleft();
        if (start < 2_960_000) revert();
        while (start - gasleft() < 2_940_000) { }
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @notice Closeout of the internal audit of the accumulation circle: list A (audit 1, round 2: A-R2-02, A-R2-06,
///         A-R2-21 survivors A04/A39/A45) and list B (audit 2, round 2: B-R2-01, B-R2-06, B-R2-07, and the B-R2-14
///         survivors A20/A47/A55/A63/A68 and unasserted ledger events). Each B low/medium finding was first reproduced
///         on the unfixed code; these tests assert the fixed behaviour.
contract MHCloseoutAccumulationTest is AccumulationFixture {
    address internal keeper = makeAddr("keeper");

    function _exitAll(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(people[i]);
            circle.exitEarly();
        }
    }

    function _forfeitOf(Vm.Log[] memory logs, address member) internal view returns (uint256) {
        bytes32 topic = IMHAccumulationCircle.ExitedEarly.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(circle) && logs[i].topics[0] == topic
                    && address(uint160(uint256(logs[i].topics[1]))) == member
            ) {
                (,, uint256 forfeited) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                return forfeited;
            }
        }
        revert("no ExitedEarly");
    }

    // ================================================================ A-R2-02: Active cancel with nobody left

    /// @dev A-R2-02: every member exited, then the Guardian cancels while Active. Each exited member gets its own
    ///      forfeited shares back as a claim (no fee on a cancellation); nothing reaches residual.
    function test_A1R2_02_guardianCancel_allExited_returnsForfeits() public {
        _startYield(3, 1_000);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(30e6);
        _openRound(2);
        vm.recordLogs();
        _exitAll(3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.prank(guardian);
        circle.guardianCancel();
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 f = _forfeitOf(logs, people[i]);
            assertGt(f, 0);
            assertEq(circle.memberState(people[i]).claimShares, f, "own forfeit returned in full");
            sum += f;
        }
        assertEq(circle.claimTotal(), sum);
        assertEq(circle.residualShares(), 0, "nothing to residual");
        for (uint256 i; i < 3; ++i) {
            vm.prank(people[i]);
            circle.claim();
            assertApproxEqAbs(_net(people[i]), 10e6, 2, "each kept its third of the yield");
        }
    }

    // ================================================================ A-R2-06: cash exits take pro-rata idle

    /// @dev A-R2-06: a cash settlement takes only its pro-rata part of idle USDC and withdraws the rest, so the idle /
    ///      vault mix of what stays is unchanged and a later loss hits every remaining member alike, whatever the
    ///      settlement order.
    function test_A1R2_06_cashSettlementKeepsTheMix_laterLossShared() public {
        _startYield(3, 0);
        _runRounds(_everyone(), 0, 0);
        _mature();
        circle.finalize();
        uint256 half = circle.vaultShares() / 2;
        vm.prank(guardian);
        circle.emergencyExit(half); // half of the position back to idle
        uint256 idle0 = circle.idleAssets();
        uint256 total0 = circle.totalShares();
        uint256 acc0 = circle.memberState(people[0]).accShares;
        circle.settleMember(people[0]);
        assertApproxEqAbs(
            circle.idleAssets(), idle0 - idle0 * acc0 / (total0 + VS), 1, "idle taken pro rata only"
        );
        morpho.mockLoss(morpho.totalAssets() / 2);
        vm.prank(people[1]);
        circle.settleMemberInKind(people[1]);
        circle.settleMember(people[2]);
        int256 in1 = _net(people[1]);
        int256 in2 = _net(people[2]);
        assertApproxEqAbs(in1, in2, 2, "in kind and cash settlers share the loss alike");
        // Each remaining member: principal $1,200, half of it in the vault, half of the vault part lost.
        assertApproxEqAbs(in1, -300e6, 3, "a quarter of principal lost, for both");
    }

    // ================================================================ A-R2-21: round-1 mutation survivors

    /// @dev A04 (R1-09 fee rounding): every returned forfeit is charged exactly `floor(f·fee/BPS)`.
    function test_A1R2_21_A04_returnedForfeitFeeRoundsDown() public {
        _startYield(3, 1_500);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(30_000_007);
        _openRound(2);
        vm.recordLogs();
        _exitAll(3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fees;
        uint256[3] memory f;
        for (uint256 i; i < 3; ++i) {
            f[i] = _forfeitOf(logs, people[i]);
            fees += f[i] * 1_500 / K.BPS;
        }
        uint256 total = circle.totalShares();
        circle.finalize(); // everyone exited: at once (audit 2 R2-06)
        for (uint256 i; i < 3; ++i) {
            assertEq(circle.memberState(people[i]).claimShares, f[i] - f[i] * 1_500 / K.BPS, "claim, exact");
        }
        assertEq(circle.totalShares(), total - fees, "fee shares, exact");
    }

    /// @dev A45 (deployIdle status gate): nothing is deployed once the circle has matured.
    function test_A1R2_21_A45_deployIdleOnlyWhileActive() public {
        _startYield(2, 0);
        _runRounds(_everyone(), 0, 0);
        _openRound(12);
        _mature();
        circle.finalize();
        uint256 held = circle.vaultShares();
        vm.prank(guardian);
        circle.emergencyExit(held); // everything idle in a Matured circle
        assertGe(circle.idleAssets(), K.MIN_DEPLOY);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.deployIdle();
    }

    /// @dev A39 (`flagRound` reads the NAV only while Active): once Matured, a broken vault does not block a strike.
    function test_A1R2_21_A39_flagWhileMatured_needsNoNav() public {
        _startYield(2, 0);
        _runRounds(_everyone(), 1, 1 << 3); // member 1 skips round 3
        _mature();
        circle.finalize();
        morpho.mockSetNavBroken(true);
        circle.flagRound(3);
        assertTrue(reputation.struck(people[1], address(circle), 3, IMHReputation.Reason.MISSED));
    }

    // ================================================================ B-R2-01: no yield latch

    function _yieldCircle() internal returns (MHAccumulationCircle c) {
        c = _startYield(4, 1_000);
        _payAll(1, _everyone());
        c.deployIdle();
    }

    /// @dev B-R2-01 (reproduced: a benign adapter-set change let anyone latch `yieldOff` and the circle never deposited
    ///      again). While the registry does not consider the vault safe, anyone may pull the shares home and deposits
    ///      pause; once Gov re-approves the vault, deposits resume and the circle earns like a control circle.
    function test_A2R2_01_adapterSetChange_noLatch_yieldResumes() public {
        MHAccumulationCircle a = _yieldCircle();
        MHAccumulationCircle b = _yieldCircle(); // control
        morpho.mockAddAdapter(address(new MockAdapterV2())); // the curator's timelocked addAdapter executes
        assertFalse(registry.vaultSafe(address(morpho)), "adapter set changed since allowVault");
        vm.prank(attacker);
        a.pullFromVault(type(uint256).max); // anyone: protective, and not latched
        assertEq(a.vaultShares(), 0);
        assertFalse(a.yieldOff());
        _openRound(2);
        circle = a;
        _payAll(2, _everyone());
        circle = b;
        _payAll(2, _everyone());
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        a.deployIdle();
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        b.deployIdle();

        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(morpho))));
        a.deployIdle();
        b.deployIdle();
        assertEq(a.idleAssets(), 0, "every idle unit back in the vault");
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.YieldOn.selector);
        a.pullFromVault(1);
        morpho.mockYield(morpho.totalAssets() / 100);
        assertApproxEqAbs(a.nav(), b.nav(), 3, "the pulled circle earns like the control");
        assertGt(a.nav(), 800e6 + 7e6);
    }

    /// @dev B-R2-01, precautionary delisting: the Guardian disallows (runbook: a Submit is pending), a stranger pulls
    ///      every share, Gov re-allows after review: yield resumes.
    function test_A2R2_01_precautionaryDisallow_thenReallow_yieldResumes() public {
        MHAccumulationCircle a = _yieldCircle();
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        vm.prank(attacker);
        a.pullFromVault(type(uint256).max);
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(morpho))));
        assertTrue(registry.vaultSafe(address(morpho)));
        a.deployIdle();
        assertGt(a.vaultShares(), 0, "yield resumed");
    }

    /// @dev B-R2-01: the Guardian's switch-off stays permanent; re-approving the vault does not undo it.
    function test_A2R2_01_guardianSwitchOff_isPermanent() public {
        MHAccumulationCircle a = _yieldCircle();
        vm.prank(guardian);
        a.emergencyExit(0);
        assertTrue(a.yieldOff());
        vm.prank(attacker);
        a.pullFromVault(type(uint256).max); // anyone, once the Guardian switched yield off
        _openRound(2);
        _payAll(2, _everyone());
        assertTrue(registry.vaultSafe(address(morpho)));
        vm.expectRevert(IMHAccumulationCircle.NoYield.selector);
        a.deployIdle();
    }

    /// @dev B-R2-01: a sustained unsafe state keeps yield off for its whole duration: no deposit, anyone pulls, and a
    ///      later loss in the vault does not touch the circle.
    function test_A2R2_01_sustainedUnsafe_noExposure() public {
        MHAccumulationCircle a = _yieldCircle();
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        vm.prank(keeper);
        a.pullFromVault(type(uint256).max);
        for (uint256 r = 2; r <= 12; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
            a.deployIdle();
        }
        morpho.mockLoss(morpho.totalAssets() / 2);
        assertEq(a.vaultShares(), 0);
        assertApproxEqAbs(a.nav(), 4_800e6, 2, "every unit idle in the circle");
        _mature();
        a.finalize();
        _settleAll();
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(_net(people[i]), 0, 2, "principal back");
        }
    }

    // ================================================================ B-R2-06: everyone exited

    /// @dev B-R2-06 (reproduced: the exits' forfeited yield waited for the end of the schedule). Once every member has
    ///      exited, `finalize` runs at once and returns each exiter its own forfeit less the fee, paid in kind.
    function test_A2R2_06_allExited_finalizeAtOnce() public {
        _startYield(3, 1_000);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(30e6);
        _openRound(2);
        vm.prank(people[0]);
        circle.exitEarly();
        vm.prank(people[1]);
        circle.exitEarly();
        vm.expectRevert(IMHCircle.NotMatured.selector);
        circle.finalize(); // someone remains: the schedule applies
        vm.prank(people[2]);
        circle.exitEarly();
        circle.finalize();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        for (uint256 i; i < 3; ++i) {
            vm.prank(people[i]);
            circle.claim();
            assertApproxEqAbs(_net(people[i]), 9e6, 3, "its $10 of yield less the 10% fee");
        }
        assertApproxEqAbs(
            usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury)), 3e6, 3, "fee"
        );
    }

    // ================================================================ B-R2-07: the last round stays owed

    /// @dev B-R2-07 (reproduced: exiting after the last deadline dodged the MISSED strike). After the last round's
    ///      deadline the last round is owed too (`exitRound = totalRounds + 1`); before it, it is not.
    function test_A2R2_07_lastRoundExit_afterDeadline_stillOwed() public {
        _start(3, 2, 0, address(0), false);
        _payAll(1, _everyone());
        _openRound(2);
        _payAll(2, 1); // only member 0 pays round 2
        vm.prank(people[1]);
        circle.exitEarly(); // during round 2, before its deadline
        assertEq(circle.memberState(people[1]).exitRound, 2);
        vm.warp(circle.roundDeadline(2) + 1);
        vm.prank(people[2]);
        circle.exitEarly(); // after the last deadline
        assertEq(circle.memberState(people[2]).exitRound, 3);
        _afterCure(2);
        circle.flagRound(2);
        assertTrue(reputation.struck(people[2], address(circle), 2, IMHReputation.Reason.MISSED), "owed");
        assertFalse(reputation.struck(people[1], address(circle), 2, IMHReputation.Reason.MISSED), "not owed");
    }

    // ================================================================ B-R2-14: survivors and ledger events

    /// @dev A47: `deployIdle` records that the vault valued the shares now (`lastLive`).
    function test_A2R2_14_A47_deployIdleRefreshesLastLive() public {
        _startYield(2, 0);
        _payAll(1, _everyone());
        vm.warp(block.timestamp + 5 days);
        circle.deployIdle();
        assertEq(circle.lastLive(), block.timestamp);
    }

    /// @dev A20: `forceExit` with exactly the position's value redeems every share (the `<=` branch), leaving no
    ///      vault-share dust behind.
    function test_A2R2_14_A20_forceExitExactValue_redeemsEveryShare() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(1_234_567);
        uint256 value = morpho.previewRedeem(circle.vaultShares());
        vm.prank(guardian);
        circle.forceExit(address(liqAdapter), "", value);
        assertEq(circle.vaultShares(), 0, "no dust shares left");
        assertEq(circle.idleAssets(), value);
    }

    function _toExpiry() internal {
        _startYield(3, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        vm.warp(uint256(circle.lastLive()) + K.EXPIRY_DELAY + 1);
    }

    /// @dev A55: a vault whose `previewRedeem` returns no data cannot value the shares, so `cancelExpired` opens.
    function test_A2R2_14_A55_emptyReturnIsNotAValuation() public {
        _toExpiry();
        vm.etch(address(morpho), hex"00"); // every call succeeds with no return data
        vm.prank(keeper);
        circle.cancelExpired();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
    }

    /// @dev A63: the probe needs `NAV_PROBE_MIN_GAS` left, so whatever gas the caller sends, an expensive but healthy
    ///      valuation is never mistaken for a broken one.
    function test_A2R2_14_A63_probeGasGuard_expensiveHealthyVault() public {
        _toExpiry();
        vm.etch(address(morpho), type(HungryPreview).runtimeCode);
        uint256 insufficient;
        uint256 readable;
        for (uint256 g = 3_000_000; g < 3_200_000; g += 2_000) {
            (bool ok, bytes memory ret) =
                address(circle).call{ gas: g }(abi.encodeCall(circle.cancelExpired, ()));
            assertFalse(ok, "a healthy vault was cancelled");
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 err = bytes4(ret); // the error selector (a revert always returns at least 4 bytes here)
            if (err == IMHAccumulationCircle.InsufficientGas.selector) ++insufficient;
            else if (err == IMHAccumulationCircle.NavReadable.selector) ++readable;
            else revert("unexpected error");
        }
        assertGt(insufficient, 0);
        assertGt(readable, 0);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
    }

    /// @dev A68: the delinquent cap applies exactly above principal: value == principal keeps every share (even though
    ///      `toShares(principal)` is below its shares once the price has moved), value == principal + 1 is capped.
    function test_A2R2_14_A68_capBoundary() public {
        for (uint256 want; want < 2; ++want) {
            uint256 snap = vm.snapshotState();
            _start(2, 2, 0, address(morpho), false);
            _payAll(1, _everyone());
            _deploy();
            _openRound(2);
            _payAll(2, 1); // member 1 delinquent: principal $100
            _deploy();
            address d = people[1];
            uint256 acc = circle.memberState(d).accShares;
            bool found;
            for (uint256 y; y < 256; ++y) {
                morpho.mockYield(1); // the price moves until a cap at principal would bite
                if (
                    circle.memberValue(d) == C + want
                        && Math.mulDiv(C, circle.totalShares() + VS, circle.nav() + 1) < acc
                ) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "value reached exactly");
            assertLt(
                Math.mulDiv(C, circle.totalShares() + VS, circle.nav() + 1), acc, "toShares(principal) < acc"
            );
            _mature();
            circle.finalize();
            if (want == 0) assertEq(circle.memberState(d).accShares, acc, "at principal: not capped");
            else assertLt(circle.memberState(d).accShares, acc, "one unit above: capped");
            vm.revertToState(snap);
        }
    }

    /// @dev Ledger events of the in-kind paths (spec §4.6 additions): `FeePaidInKind`, `SharesQueued`,
    ///      `OwedSharesClaimed`, asserted with their exact arguments.
    function test_A2R2_14_inKindLedgerEvents() public {
        _startYield(2, 1_000);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(20e6);
        _openRound(2);
        _exitAll(2);
        uint256 total = circle.totalShares();
        uint256 feeShares = circle.forfeitShares() * 1_000 / K.BPS; // two forfeits: floor per member, checked below
        vm.recordLogs();
        circle.finalize();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != IMHAccumulationCircle.FeePaidInKind.selector) continue;
            seen = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), treasury);
            (uint256 assets, uint256 vShares) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(morpho.balanceOf(treasury), vShares, "FeePaidInKind.vaultShares == shares sent");
            assertEq(usdc.balanceOf(treasury), assets, "FeePaidInKind.assets == USDC sent");
        }
        assertTrue(seen, "FeePaidInKind emitted");
        assertApproxEqAbs(total - circle.totalShares(), feeShares, 1);

        address m = people[0];
        usdc.setBlacklisted(m, true);
        uint256 claimShares = circle.memberState(m).claimShares;
        uint256 expectShares = circle.vaultShares() * claimShares / (circle.totalShares() + VS);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.SharesQueued(m, expectShares);
        vm.prank(m);
        circle.claimInKind();
        assertEq(circle.owedShares(m), expectShares);
        usdc.setBlacklisted(m, false);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.OwedSharesClaimed(m, expectShares);
        vm.prank(m);
        circle.claimOwedShares();
        assertEq(morpho.balanceOf(m), expectShares);
    }
}
