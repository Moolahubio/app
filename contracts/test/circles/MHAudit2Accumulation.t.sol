// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { CircleStatus, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";
import { MockVaultV2 } from "../mocks/MockVaultV2.sol";

/// @notice The timelock state machine of Morpho's `MorphoMarketV1AdapterV2` (morpho-org/vault-v2,
///         src/adapters/MorphoMarketV1AdapterV2.sol lines 83-160), copied from the audit 2 R1-10 verifier PoC: the
///         curator is fixed at construction, and `burnShares` realises the write-down as a vault loss.
contract MorphoAdapterTimelocks {
    error Unauthorized();
    error DataAlreadyPending();
    error DataNotTimelocked();
    error TimelockNotExpired();
    error Abdicated();
    error AutomaticallyTimelocked();
    error TimelockNotDecreasing();

    address public immutable curator;
    MockVaultV2 public immutable parentVault;
    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;
    mapping(bytes data => uint256) public executableAt;

    constructor(MockVaultV2 vault, address curator_) {
        parentVault = vault;
        curator = curator_;
        timelock[this.burnShares.selector] = 3 days; // the Gauntlet shape: passes `allowVault`
    }

    function submit(bytes calldata data) external {
        if (msg.sender != curator) revert Unauthorized();
        if (executableAt[data] != 0) revert DataAlreadyPending();
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        uint256 t =
            selector == this.decreaseTimelock.selector ? timelock[bytes4(data[4:8])] : timelock[selector];
        executableAt[data] = block.timestamp + t;
    }

    function _timelocked() internal {
        if (executableAt[msg.data] == 0) revert DataNotTimelocked();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < executableAt[msg.data]) revert TimelockNotExpired();
        if (abdicated[bytes4(msg.data)]) revert Abdicated();
        executableAt[msg.data] = 0;
    }

    function decreaseTimelock(bytes4 selector, uint256 newDuration) external {
        _timelocked();
        if (selector == this.decreaseTimelock.selector) revert AutomaticallyTimelocked();
        if (newDuration > timelock[selector]) revert TimelockNotDecreasing();
        timelock[selector] = newDuration;
    }

    function burnShares(bytes32) external {
        _timelocked();
        parentVault.mockLoss(parentVault.totalAssets() / 2);
    }
}

/// @notice A keeper holding its own vault shares: force-deallocates in one transaction (the prior-audit R1-22
///         runbook), so an allocator can move the freed USDC back before the circle's exit.
contract SeparateTxKeeper {
    function forceDeallocate(MockVaultV2 v, address adapter, uint256 assets) external {
        v.forceDeallocate(adapter, "", assets, address(this));
    }
}

/// @notice Audit 2, round 1: regressions for `MHAccumulationCircle` (and its registry reads) built from the verifier
///         PoCs in `scratchpad/audit/r1-verify-R1-{01,05,06,07,08,09,10,12}-*`. Each PoC scenario is replayed and
///         asserts the fixed outcome; acknowledged findings pin the accepted behaviour.
contract MHAudit2AccumulationTest is AccumulationFixture {
    event CircleCancelled(
        IMHAccumulationCircle.CancelReason indexed reason, uint256 claimShares, uint256 residualShares
    );

    address internal bot = makeAddr("bot");
    address internal keeperEoa = makeAddr("keeper");

    function _held(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + circle.owed(who) + morpho.convertToAssets(morpho.balanceOf(who));
    }

    function _treasuryValue() internal view returns (uint256) {
        return _held(treasury);
    }

    function _gate() internal view returns (uint256) {
        return uint256(circle.lastLive()) + K.EXPIRY_DELAY;
    }

    function _claimAllInKind() internal {
        address[] memory m = circle.members();
        for (uint256 i; i < m.length; ++i) {
            if (circle.memberState(m[i]).claimShares == 0) continue;
            vm.prank(m[i]);
            circle.claimInKind();
        }
    }

    function _forceExit(uint256 assets) internal {
        vm.prank(guardian);
        circle.forceExit(address(liqAdapter), "", assets);
    }

    // ================================================================ R1-01: a hostile allocator blocks every exit

    /// @dev 3 members × $1,000 deposited into the vault (the PoC's circle). Tests then let the allocator point the
    ///      vault's liquidity adapter at an empty market (instant, no timelock): `mockSetLiquidity(0)`.
    function _startThousand() internal returns (MHAccumulationCircle c) {
        AccumulationParams memory p = _params(3, 3, 0, address(morpho), false);
        p.config.contribution = 1_000e6;
        c = _create(p);
        for (uint256 i; i < 3; ++i) {
            _join(people[i]);
        }
        vm.warp(c.startTime());
        for (uint256 i; i < 3; ++i) {
            _fund(people[i], 1_000e6);
            vm.prank(people[i]);
            c.contribute(1, 1_000e6);
        }
        c.deployIdle();
    }

    /// @dev PoC R1-01 (verifiers 1 and 2, `test_poc_allocatorBlocksGuardianExit_rugLandsOnCircle`,
    ///      `test_finding_blockByJunkLiquidityData_lossLands`): with the liquidity adapter pointed at an empty market,
    ///      every redemption reverts and the rug lands on the circle. Now the Guardian's `forceExit` frees the
    ///      circle's USDC from the market and redeems it in the same call; the later 93% write-down misses the circle.
    function test_A2R1_01_hostileLiquidityAdapter_forceExitSavesTheCircle() public {
        MHAccumulationCircle c = _startThousand();
        uint256 navBefore = c.nav();
        assertApproxEqAbs(navBefore, 3_000e6, 2);
        uint256 held = c.vaultShares();
        morpho.mockSetLiquidity(0); // the allocator's instant `setLiquidityAdapterAndData(…, emptyMarket)`

        // Every other exit is blocked, as in the PoC.
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        c.emergencyExit(type(uint256).max);
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        c.emergencyExit(held / 100);
        vm.prank(guardian);
        c.emergencyExit(0);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        c.pullFromVault(held / 1000);
        vm.prank(people[0]);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        c.exitEarly();

        uint256 value = morpho.previewRedeem(held);
        vm.expectEmit(true, false, false, true, address(c));
        emit IMHAccumulationCircle.ForceExited(address(liqAdapter), value, 0, held, value);
        vm.prank(guardian);
        c.forceExit(address(liqAdapter), "", value);
        assertEq(c.vaultShares(), 0, "every share out");
        assertEq(c.idleAssets(), value);
        assertTrue(c.yieldOff());

        // The curator's timelocked cap increases mature and the bad debt is realised: the circle is not exposed.
        morpho.mockLoss(morpho.totalAssets() * 93 / 100);
        assertApproxEqAbs(c.nav(), navBefore, 2, "circle whole");
        _assertBucketsOf(c);
    }

    /// @dev PoC R1-01 `test_poc_runbookSequenceDefeatedByReallocation` / `test_runbook_separateTx_defeated`: a
    ///      keeper's force-deallocation in its own transaction is undone by the allocator's next transaction and the
    ///      Guardian's exit reverts again. `forceExit` cannot be interleaved: it deallocates and redeems in one call.
    function test_A2R1_01_separateTxRunbookDefeated_forceExitIsAtomic() public {
        MHAccumulationCircle c = _startThousand();
        SeparateTxKeeper keeper = new SeparateTxKeeper();
        _fund(address(this), 100e6);
        usdc.approve(address(morpho), 100e6);
        morpho.deposit(100e6, address(keeper));
        morpho.mockSetLiquidity(0);
        uint256 need = morpho.previewRedeem(c.vaultShares()) + 10;
        keeper.forceDeallocate(morpho, address(liqAdapter), need);
        assertGe(morpho.freedIdle(), need, "the keeper freed the liquidity");
        morpho.mockReallocate(); // the allocator's next transaction
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        c.emergencyExit(type(uint256).max);

        uint256 value = morpho.previewRedeem(c.vaultShares());
        vm.prank(guardian);
        c.forceExit(address(liqAdapter), "", value);
        assertEq(c.vaultShares(), 0);
        assertApproxEqAbs(c.idleAssets(), 3_000e6, 2);
    }

    /// @dev PoC R1-01 `test_escapeCost_boundedByMaxPenalty` / `test_v1_penaltyRaisedToMax_atomicRescueStillWorks`: a
    ///      hostile curator raises the force-deallocation penalty to Vault V2's 2% cap. The circle pays it, and over
    ///      any number of calls never more than 2% of its position (`assets` is bounded by the position's value).
    function test_A2R1_01_forceExit_penaltyBoundedBy2Percent() public {
        MHAccumulationCircle c = _startThousand();
        morpho.mockSetLiquidity(0);
        morpho.mockSetForceDeallocatePenalty(address(liqAdapter), 0.02e18);
        uint256 navBefore = c.nav();
        // Four chunks, then the rest in one call.
        for (uint256 i; i < 4; ++i) {
            uint256 v = morpho.previewRedeem(c.vaultShares());
            vm.prank(guardian);
            c.forceExit(address(liqAdapter), "", v / 4);
        }
        uint256 rest = morpho.previewRedeem(c.vaultShares());
        vm.prank(guardian);
        c.forceExit(address(liqAdapter), "", rest);
        assertLe(c.vaultShares(), 1e12, "only dust left in the vault");
        assertGe(c.nav() + navBefore * 2 / 100 + 2, navBefore, "at most 2% of the position");
        assertLt(c.nav(), navBefore, "the penalty was paid");
        _assertBucketsOf(c);
    }

    /// @dev When the market itself is short, `forceExit` frees and redeems exactly what it asks for.
    function test_A2R1_01_forceExit_partialFreesAndRedeemsExactly() public {
        MHAccumulationCircle c = _startThousand();
        morpho.mockSetLiquidity(0);
        morpho.mockSetForceable(1_000e6);
        uint256 held = c.vaultShares();
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: market illiquid"));
        c.forceExit(address(liqAdapter), "", 1_000e6 + 1);
        uint256 burn = morpho.previewWithdraw(1_000e6);
        vm.prank(guardian);
        c.forceExit(address(liqAdapter), "", 1_000e6);
        assertEq(c.idleAssets(), 1_000e6);
        assertEq(c.vaultShares(), held - burn);
        assertApproxEqAbs(c.nav(), 3_000e6, 2);
    }

    /// @dev Guards: Guardian only; a vault; non-zero assets bounded by the position; one of the vault's adapters.
    function test_A2R1_01_forceExit_guards() public {
        MHAccumulationCircle c = _startThousand();
        uint256 value = morpho.previewRedeem(c.vaultShares());
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.NotGuardian.selector);
        c.forceExit(address(liqAdapter), "", value);
        vm.startPrank(guardian);
        vm.expectRevert(IMHAccumulationCircle.BadForceExit.selector);
        c.forceExit(address(liqAdapter), "", 0);
        vm.expectRevert(IMHAccumulationCircle.BadForceExit.selector);
        c.forceExit(address(liqAdapter), "", value + 1);
        vm.expectRevert(IMHAccumulationCircle.BadForceExit.selector);
        c.forceExit(attacker, "", value);
        vm.stopPrank();
        morpho.mockSetNavBroken(true);
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: adapter realAssets reverted"));
        c.forceExit(address(liqAdapter), "", value);
        morpho.mockSetNavBroken(false);

        _start(2, 2, 0, address(0), false);
        vm.prank(guardian);
        vm.expectRevert(IMHAccumulationCircle.NoYield.selector);
        circle.forceExit(address(liqAdapter), "", 1);
    }

    function _assertBucketsOf(MHAccumulationCircle c) internal view {
        assertEq(usdc.balanceOf(address(c)), c.idleAssets() + c.owedTotal(), "usdc tracked");
        assertEq(morpho.balanceOf(address(c)), c.vaultShares(), "vault shares tracked");
    }

    // ================================================================ R1-05/R1-06/R1-07: cancelExpired

    uint256 internal constant DEL = 3;
    uint256 internal constant SKIP = (1 << 4) | (1 << 8);

    /// @dev Spec §4.5 example: 4 members, $100 × 12, fee 10%, D (index 3) skips rounds 4 and 8, +$115 yield.
    function _specExample() internal {
        _startYield(4, 1_000);
        _runRounds(_everyone(), DEL, SKIP);
        morpho.mockYield(115e6);
        _mature();
        circle.flagRound(4);
        circle.flagRound(8);
    }

    /// @dev PoC R1-05 (a) `test_a_cancelExpired_byDelinquent_atExpiry`: with the keeper idle for 90 days, the
    ///      delinquent's cancel used to skip the cap (D got $1,025, the treasury $0). With a vault that values its
    ///      shares the cancel is refused; `finalize` still gives the spec numbers.
    function test_A2R1_05_healthyVault_delinquentCannotCancel_finalizeCaps() public {
        _specExample();
        vm.warp(_gate() + 1); // past the old gate (graceEnd(12) + 90 days) and the outage gate
        assertGt(block.timestamp, _graceEnd(12) + K.EXPIRY_DELAY);
        vm.prank(people[DEL]);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        circle.cancelExpired();
        circle.finalize();
        _settleAll();
        assertApproxEqAbs(_held(people[0]), 1_234_500_000, 2, "compliant: spec $1,234.50");
        assertApproxEqAbs(_held(people[DEL]), 1_000e6, 2, "delinquent capped at its principal");
        assertApproxEqAbs(_treasuryValue(), 11_500_000, 3, "treasury: spec $11.50");
    }

    /// @dev PoC R1-05 (b) `test_b_pausedFromMaturityToExpiry`: even with a vault that cannot value its shares (the
    ///      only case the cancel exists for), it reverts while USDC is paused, like `finalize`.
    function test_A2R1_05_usdcPaused_cancelExpiredReverts() public {
        _specExample();
        morpho.mockSetNavBroken(true);
        usdc.setPaused(true);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.finalize();
        vm.warp(_gate() + 1);
        vm.prank(people[DEL]);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.cancelExpired();
        usdc.setPaused(false);
        vm.prank(people[DEL]);
        circle.cancelExpired(); // the NAV-free exit once USDC is live
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
    }

    /// @dev PoC R1-05 (b) `test_b_circleBlacklisted_inKind`: a blacklisted circle cannot be cancelled by anyone but
    ///      the Guardian.
    function test_A2R1_05_circleBlacklisted_onlyGuardianCancels() public {
        _specExample();
        morpho.mockSetNavBroken(true);
        usdc.setBlacklisted(address(circle), true);
        vm.warp(_gate() + 1);
        vm.prank(people[DEL]);
        vm.expectRevert(IMHCircle.CircleBlacklisted.selector);
        circle.cancelExpired();
        vm.prank(guardian);
        circle.guardianCancel();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
    }

    function _maturedFee15() internal {
        _start(3, 3, 1_500, address(morpho), false);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(60e6); // +$60 on $900
        _mature();
        circle.finalize();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Matured));
    }

    /// @dev PoC R1-06 `test_R106_illiquid_waitForExpiry_skipsFee`: while the vault is illiquid (but values its
    ///      shares), a member could wait 90 days and cancel the fee away. The cancel is now refused; the member's way
    ///      out is `settleMemberInKind`, which charges the fee.
    function test_A2R1_06_illiquidMatured_waitingCannotSkipTheFee() public {
        _maturedFee15();
        address a = people[0];
        morpho.mockSetLiquidity(0);
        vm.prank(keeperEoa);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.settleMember(a);
        vm.warp(_gate() + 1);
        assertGt(block.timestamp, _graceEnd(3) + K.EXPIRY_DELAY, "past the old gate");
        vm.prank(a);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        circle.cancelExpired();
        vm.prank(a);
        circle.settleMemberInKind(a);
        assertApproxEqAbs(_treasuryValue(), 3e6, 3, "the ~$3.00 fee on A's ~$20 earnings");
    }

    /// @dev PoC R1-06 `test_R106_liquid_keeperOffline_feeWaived`: a liquid vault and an offline keeper no longer
    ///      waive the fee either.
    function test_A2R1_06_liquid_keeperOffline_feeKept() public {
        _maturedFee15();
        vm.warp(_gate() + 1);
        vm.prank(people[0]);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        circle.cancelExpired();
        circle.settleMember(people[0]);
        assertApproxEqAbs(usdc.balanceOf(treasury), 3e6, 2);
    }

    /// @dev PoC R1-07 `test_R107_midLife_12monthly_frozenUntilScheduleEndPlus90d`: the vault stops valuing shares in
    ///      round 2 of 12 and the Guardian is unavailable. The permissionless exit used to open 422 days later; it now
    ///      opens 90 days after the vault last valued the circle's shares.
    function test_A2R1_07_midLifeBreak_exitOpens90DaysAfterTheOutageStarts() public {
        _start(4, 12, 0, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _payAll(2, _everyone());
        assertEq(circle.idleAssets(), 400e6);
        uint256 brokeAt = block.timestamp;
        assertEq(circle.lastLive(), brokeAt, "the last contribution read the NAV");
        morpho.mockSetNavBroken(true);

        _openRound(3);
        _fund(people[0], C);
        vm.prank(people[0]);
        vm.expectRevert(bytes("MockVaultV2: adapter realAssets reverted"));
        circle.contribute(3, C);
        vm.warp(brokeAt + K.EXPIRY_DELAY);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelExpired();
        vm.warp(brokeAt + K.EXPIRY_DELAY + 1);
        vm.prank(bot);
        circle.cancelExpired();
        assertEq((block.timestamp - brokeAt) / 1 days, 90, "frozen 90 days, not 422");
        for (uint256 i; i < 4; ++i) {
            vm.prank(people[i]);
            (uint256 assets, uint256 vShares) = circle.claimInKind();
            assertGt(assets, 99e6, "idle USDC reachable");
            assertGt(vShares, 0);
        }
    }

    /// @dev PoC R1-07 `test_R107_weekly52_gate` and `test_R107_maxBounds_gateOver130Years`: the gate no longer scales
    ///      with the schedule (52 weekly rounds; 520 rounds × 92 days).
    function test_A2R1_07_gateIndependentOfSchedule() public {
        AccumulationParams memory p = _params(2, uint32(K.MAX_ROUNDS), 0, address(morpho), false);
        p.config.roundDuration = uint64(K.MAX_ROUND);
        _create(p);
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        _payAll(1, _everyone());
        circle.deployIdle();
        uint256 brokeAt = block.timestamp;
        morpho.mockSetNavBroken(true);
        vm.warp(brokeAt + K.EXPIRY_DELAY + 1);
        circle.cancelExpired();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled), "90 days, not 130 years");
    }

    /// @dev A healthy circle is never cancellable this way, however long it sat untouched.
    function test_A2R1_07_healthyCircleNeverExpires() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        vm.warp(block.timestamp + 5 * 365 days);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        circle.cancelExpired();
    }

    /// @dev Too little gas for the probe reverts `InsufficientGas` instead of making a healthy vault look broken.
    function test_A2R1_05_probeCannotBeStarvedByTheCaller() public {
        _startYield(3, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        vm.warp(_gate() + 1);
        (bool ok, bytes memory ret) =
            address(circle).call{ gas: 2_000_000 }(abi.encodeCall(circle.cancelExpired, ()));
        assertFalse(ok);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(ret), IMHAccumulationCircle.InsufficientGas.selector);
        assertEq(uint8(circle.status()), uint8(CircleStatus.Active));
    }

    // ================================================================ R1-08: cure after grace

    function _setupRound2() internal {
        _start(2, 3, 0, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _pay(people[0], 2);
        circle.deployIdle();
    }

    /// @dev PoC R1-08 `test_V_outageSpansGraceEnd_flagBeatsGuardian`: a sequencer outage spans round 2's grace end. At
    ///      restart the bot's flag used to land first and B lost its yield to A. Now the flag waits for the cure, the
    ///      Guardian extends, B pays and stays compliant, and the yield is split pro rata.
    function test_A2R1_08_outageAcrossGraceEnd_guardianExtendsInTheCure() public {
        _setupRound2();
        address b = people[1];
        vm.warp(_graceEnd(2) + 1 hours); // restart
        vm.prank(bot);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
        assertFalse(reputation.struck(b, address(circle), 2, IMHReputation.Reason.MISSED));
        vm.warp(block.timestamp + 2);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        _pay(b, 2);
        assertEq(circle.memberState(b).paidRounds, 2);

        _openRound(3);
        _payAll(3, _everyone());
        circle.deployIdle();
        morpho.mockYield(30e6);
        _mature();
        circle.finalize();
        _settleAll();
        assertGt(_net(b), 14e6, "B keeps about half of the $30 yield");
        assertEq(reputation.strikeCount(b), 0);
    }

    /// @dev PoC R1-08 `test_V_finalizeRace_extensionImpossible`: `finalize` at the last grace end + 1 used to make the
    ///      circle Matured before the Guardian could extend. It now waits for the cure too.
    function test_A2R1_08_finalizeWaitsForTheCure() public {
        _setupRound2();
        _pay(people[1], 2);
        circle.deployIdle();
        _openRound(3);
        _pay(people[0], 3);
        circle.deployIdle();
        vm.warp(_graceEnd(3) + 1 hours);
        vm.prank(bot);
        vm.expectRevert(IMHCircle.NotMatured.selector);
        circle.finalize();
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        _pay(people[1], 3);
        _mature();
        circle.finalize();
        assertTrue(circle.memberState(people[1]).compliant, "B paid every round");
    }

    /// @dev PoC R1-08 `test_V_navOutage_noGuardian_flagAtRecovery`: the vault recovers after round 2's grace end; the
    ///      first transaction after recovery can no longer flag, so the Guardian still has the cure to extend.
    function test_A2R1_08_navOutageAcrossGraceEnd_flagWaitsForTheCure() public {
        _setupRound2();
        vm.warp(_graceEnd(2) - 1 hours);
        morpho.mockSetNavBroken(true);
        vm.warp(_graceEnd(2) + 1 hours);
        morpho.mockSetNavBroken(false);
        vm.prank(bot);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
        vm.prank(guardian);
        circle.extendDeadline(7 days);
        _pay(people[1], 2);
        assertEq(circle.memberState(people[1]).paidRounds, 2);
    }

    /// @dev Pinned (accepted): with no Guardian action the round is flagged once the cure has passed.
    function test_A2R1_08_pinned_noGuardian_flagAfterTheCure() public {
        _setupRound2();
        vm.warp(_graceEnd(2) + CURE);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
        _afterCure(2);
        vm.prank(bot);
        circle.flagRound(2);
        assertTrue(reputation.struck(people[1], address(circle), 2, IMHReputation.Reason.MISSED));
    }

    // ================================================================ R1-09: deposits into a delisted vault

    function _weakenAndDelist() internal {
        vm.warp(block.timestamp + 7 days);
        morpho.mockSetTimelock(IVaultV2.setIsAllocator.selector, 0);
        assertFalse(registry.vaultSafe(address(morpho)));
        vm.prank(attacker);
        assertTrue(registry.revalidateVault(address(morpho)));
    }

    /// @dev PoC R1-09 `test_R109_deployIdle_afterRevalidateDelist`: after the registry delists the vault, anyone's
    ///      `deployIdle` used to put round 2 into it; half of it was then lost. It now deposits nothing (audit 2
    ///      R2-01: it reverts `VaultUnsafe` and latches nothing), so the loss only touches what was already deposited.
    function test_A2R1_09_deployIdleAfterDelist_depositsNothing() public {
        MHAccumulationCircle c = _start(4, 3, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        _weakenAndDelist();
        _openRound(2);
        _payAll(2, _everyone());
        uint256 s0 = c.vaultShares();
        vm.prank(attacker);
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        c.deployIdle();
        assertFalse(c.yieldOff(), "nothing latched");
        assertEq(c.idleAssets(), 400e6, "round 2 stays idle");
        assertEq(c.vaultShares(), s0);
        morpho.mockLoss(morpho.totalAssets() / 2);
        assertApproxEqAbs(c.nav(), 600e6, 2, "only the pre-delist deposit is exposed");
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        c.deployIdle();
    }

    /// @dev PoC R1-09 (b): the Guardian's `disallowVault` now stops deposits too (one registry call, no per-circle
    ///      emergencyExit needed).
    function test_A2R1_09_deployIdleAfterGuardianDisallow_depositsNothing() public {
        MHAccumulationCircle c = _start(4, 3, 1_000, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        c.deployIdle();
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        _openRound(2);
        _payAll(2, _everyone());
        vm.prank(attacker);
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        c.deployIdle();
        assertEq(c.idleAssets(), 400e6);
    }

    /// @dev PoC R1-09 (e) `test_R109_noPermissionlessYieldOff`: once the vault is delisted, anyone's `pullFromVault`
    ///      brings the shares home without the Guardian (audit 2 R2-01: directly, `syncVault` and its latch are gone).
    function test_A2R1_09_pullFromVault_isPermissionlessWhileUnsafe() public {
        MHAccumulationCircle c = _start(4, 3, 1_000, address(morpho), false);
        _payAll(1, _everyone());
        c.deployIdle();
        uint256 held = c.vaultShares();
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.YieldOn.selector); // still safe
        c.pullFromVault(held);
        _weakenAndDelist();
        vm.prank(attacker);
        c.pullFromVault(held);
        assertEq(c.vaultShares(), 0);
        assertApproxEqAbs(c.idleAssets(), 400e6, 2);
        assertFalse(c.yieldOff(), "nothing latched");

        _start(2, 2, 0, address(0), false);
        vm.expectRevert(IMHAccumulationCircle.ZeroAmount.selector); // no vault, nothing to pull
        circle.pullFromVault(1);
    }

    // ================================================================ R1-10: vaultSafe walks the adapters

    /// @dev PoC R1-10 `test_R1_10_vaultSafeIgnoresAdapterBurnSharesTimelockDrop`: an adapter's `burnShares` timelock
    ///      dropped to 0 (the adapter set unchanged). `vaultSafe` used to stay true, so new circles were created on the
    ///      vault and pending ones activated with yield on. Now creation is refused and neither the activated circle
    ///      nor an Active one can deposit (audit 2 R2-01: nothing latched in the circle; closing review: the first
    ///      `deployIdle` delists the vault in the registry, later ones revert `VaultUnsafe`).
    function test_A2R1_10_adapterTimelockDrop_isCaughtLive() public {
        address curatorKey = makeAddr("vaultCurator");
        MockVaultV2 v = new MockVaultV2(address(usdc), curatorKey);
        MorphoAdapterTimelocks adapter = new MorphoAdapterTimelocks(v, curatorKey);
        v.mockAddAdapter(address(adapter));
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(v))));
        assertTrue(registry.vaultSafe(address(v)));

        MHAccumulationCircle active = _start(3, 3, 0, address(v), false);
        _payAll(1, _everyone());
        active.deployIdle();
        MHAccumulationCircle pending = _create(_params(3, 3, 0, address(v), false));

        bytes4 burn = IMorphoMarketV1AdapterV2.burnShares.selector;
        bytes memory data = abi.encodeCall(MorphoAdapterTimelocks.decreaseTimelock, (burn, 0));
        vm.prank(curatorKey);
        adapter.submit(data);
        vm.warp(block.timestamp + 3 days);
        vm.prank(curatorKey);
        (bool ok,) = address(adapter).call(data);
        assertTrue(ok);
        assertEq(adapter.timelock(burn), 0);

        assertFalse(registry.vaultSafe(address(v)), "the live check walks the adapters");
        assertTrue(registry.isAllowedVault(address(v)), "not delisted yet: no one called revalidateVault");
        vm.prank(operator);
        vm.expectRevert(IMHCircle.BadConfig.selector);
        factory.createAccumulation(_params(3, 3, 0, address(v), false));

        circle = pending;
        for (uint256 i; i < 3; ++i) {
            _join(people[i]);
        }
        vm.warp(pending.startTime());
        circle = pending;
        _payAll(1, _everyone());
        // Activated, but cannot deposit. Closing review: its `deployIdle` delists the vault (sticky until Gov
        // re-allows) and returns without depositing.
        pending.deployIdle();
        assertEq(pending.vaultShares(), 0);
        assertFalse(registry.isAllowedVault(address(v)), "delisted by deployIdle");
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        pending.deployIdle();

        circle = active;
        _openRound(2);
        _payAll(2, _everyone());
        uint256 held = active.vaultShares();
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        active.deployIdle(); // an Active circle stops depositing
        assertEq(active.vaultShares(), held);
    }

    // ================================================================ R1-12: cancelExpired coverage (ported)

    /// @dev Kills mutants A04 (gate deleted) and A03 (gate shrunk): closed mid-circle, at maturity and up to and
    ///      including `lastLive + EXPIRY_DELAY`; open one second later for anyone while the vault cannot value its
    ///      shares; emits `CircleCancelled(Expired, …)`.
    function test_A2R1_12_cancelExpired_gate() public {
        _startYield(3, 1_000);
        _payAll(1, _everyone());
        _deploy();
        vm.prank(bot);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelExpired(); // mid-circle
        _runRounds(_everyone(), 0, 0);
        morpho.mockSetNavBroken(true);
        _mature();
        vm.prank(bot);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelExpired(); // at maturity
        vm.warp(_gate());
        vm.prank(bot);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelExpired(); // exactly at the boundary
        vm.warp(_gate() + 1);
        vm.expectEmit(true, false, false, false, address(circle));
        emit CircleCancelled(IMHAccumulationCircle.CancelReason.Expired, 0, 0);
        vm.prank(bot);
        circle.cancelExpired();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Cancelled));
        _claimAllInKind();
        assertEq(circle.claimTotal(), 0);
    }

    /// @dev Pending, Closed and Cancelled revert `NotActive`, past the gate and with a broken vault.
    function test_A2R1_12_cancelExpired_statuses() public {
        _create(_params(3, 3, 0, address(morpho), false));
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.cancelExpired(); // Pending

        _start(3, 3, 1_000, address(morpho), false);
        _runRounds(_everyone(), 0, 0);
        _mature();
        circle.finalize();
        _settleAll();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        morpho.mockSetNavBroken(true);
        vm.warp(_gate() + 1);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.cancelExpired(); // Closed
        morpho.mockSetNavBroken(false);

        _startYield(3, 0);
        vm.prank(guardian);
        circle.guardianCancel();
        vm.warp(_gate() + 1);
        vm.expectRevert(IMHCircle.NotActive.selector);
        circle.cancelExpired(); // Cancelled
    }

    /// @dev Spec §4.7 invariant 7 as written (R1_12_V1_Liveness): Active and Matured circles with a broken vault and
    ///      no Guardian reach claims through time and permissionless calls only.
    function test_A2R1_12_inv7_activeAndMaturedBrokenVault_noGuardian() public {
        _startYield(3, 1_000);
        _payAll(1, _everyone());
        _deploy();
        _openRound(2);
        _payAll(2, _allBut(1));
        _deploy();
        morpho.mockSetNavBroken(true);
        _mature();
        vm.expectRevert();
        circle.finalize();
        vm.warp(_gate() + 1);
        vm.prank(bot);
        circle.cancelExpired();
        _claimAllInKind();
        assertEq(circle.claimTotal(), 0);
        morpho.mockSetNavBroken(false); // the curator repairs the vault; a new circle breaks after maturity

        _start(3, 3, 1_000, address(morpho), false);
        _runRounds(_everyone(), 2, 1 << 2);
        _mature();
        circle.finalize();
        morpho.mockSetNavBroken(true);
        vm.expectRevert();
        circle.settleMember(people[0]);
        vm.warp(_gate() + 1);
        vm.prank(bot);
        circle.cancelExpired();
        _claimAllInKind();
        assertEq(circle.claimTotal(), 0);
    }

    /// @dev Kills mutant A05 (R2-02 reverted) through the permissionless path: every member exits, the vault then
    ///      breaks; the expiry cancel hands each exited member back its own forfeited shares (nothing to residual).
    function test_A2R1_12_R2_02_cancelExpired_allExited_returnsForfeits() public {
        _startYield(2, 1_000);
        _payAll(1, _everyone());
        _deploy();
        morpho.mockYield(20e6);
        vm.prank(people[0]);
        circle.exitEarly();
        vm.prank(people[1]);
        circle.exitEarly();
        uint256 forfeit = circle.forfeitShares();
        assertGt(forfeit, 0);
        assertEq(circle.accTotal(), 0);
        morpho.mockSetNavBroken(true);
        vm.warp(_gate() + 1);
        circle.cancelExpired();
        assertEq(circle.residualShares(), 0, "exit forfeits must not go to residual");
        assertEq(circle.claimTotal(), forfeit);
    }

    /// @dev Kills mutant A23: Matured, nobody compliant (member 0 exited after +$60, members 1 and 2 skipped round 3).
    ///      A cancellation shares member 0's forfeit among members 1 and 2, as `settleMember` would.
    function test_A2R1_12_A23_maturedCancel_allDelinquent_sharesForfeits() public {
        _start(3, 3, 0, address(morpho), false);
        _payAll(1, _everyone());
        _deploy();
        _openRound(2);
        _payAll(2, _everyone());
        _deploy();
        morpho.mockYield(60e6);
        vm.prank(people[0]);
        circle.exitEarly();
        _mature();
        circle.finalize();
        assertEq(circle.compliantSnap(), 0);
        vm.prank(guardian);
        circle.guardianCancel();
        assertLe(circle.residualShares(), 2, "only rounding dust to residual");
    }

    /// @dev The value behind A03/A04: at maturity the delinquent cannot pre-empt `finalize` with a cancel.
    function test_A2R1_12_delinquentCannotPreemptFinalize() public {
        _startYield(3, 0);
        _runRounds(_everyone(), 2, 1 << 2);
        morpho.mockYield(30e6);
        _mature();
        vm.prank(people[2]);
        vm.expectRevert(IMHCircle.NotStalled.selector);
        circle.cancelExpired();
        vm.warp(_gate() + 1);
        vm.prank(people[2]);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        circle.cancelExpired();
        circle.finalize();
        circle.settleMember(people[2]);
        assertEq(usdc.balanceOf(people[2]), 1_100e6 - 1, "capped at principal");
    }

    // ================================================================ R1-21, R1-22: acknowledged (pinned)

    /// @dev R1-21 (acknowledged, founder decision): a remaining member with a single payment takes every exiter's
    ///      forfeited yield when nobody is compliant, while with no remaining payment the forfeits go back to the
    ///      exiters (R1-09). Pinned so any change is deliberate.
    function test_A2R1_21_pinned_exitForfeitCliff() public {
        uint256 snap = vm.snapshotState();
        for (uint256 variant; variant < 2; ++variant) {
            _start(3, 12, 0, address(morpho), false);
            for (uint256 r = 1; r <= 6; ++r) {
                _openRound(r);
                _payAll(r, r == 1 && variant == 0 ? _everyone() : _allBut(2));
                _deploy();
            }
            morpho.mockYield(morpho.totalAssets() / 10);
            _openRound(7);
            vm.prank(people[0]);
            circle.exitEarly();
            vm.prank(people[1]);
            circle.exitEarly();
            _mature();
            circle.finalize();
            if (variant == 0) {
                circle.settleMember(people[2]);
                assertApproxEqAbs(
                    _net(people[2]), 129_999_998, 3, "one $100 payment takes both exiters' yield"
                );
            } else {
                vm.prank(people[0]);
                circle.claim();
                assertApproxEqAbs(
                    _net(people[0]), 60e6, 3, "with nobody left, each exiter gets its yield back"
                );
            }
            vm.revertToState(snap);
        }
    }

    /// @dev R1-22 (acknowledged): the Guardian's 30-day extension budget is per circle, not per incident; a
    ///      compromised Guardian can exhaust it. Since R1-08 a flag or finalize still waits grace + cure after any
    ///      outage, so members are never flagged in the first block after a restart, budget or not.
    function test_A2R1_22_pinned_budgetExhausted_cureStillApplies() public {
        _setupRound2();
        vm.startPrank(guardian);
        for (uint256 i; i < 4; ++i) {
            circle.extendDeadline(7 days);
        }
        circle.extendDeadline(2 days);
        vm.expectRevert(IMHCircle.ExtensionLimit.selector);
        circle.extendDeadline(1);
        vm.stopPrank();
        vm.warp(_graceEnd(2) + 1 hours);
        vm.expectRevert(IMHCircle.BadRound.selector);
        circle.flagRound(2);
    }

    // ================================================================ R1-28: MIN_DEPLOY boundary

    /// @dev Kills mutant A27 (`<` changed to `<=` at MIN_DEPLOY): exactly MIN_DEPLOY of idle USDC is deployed,
    ///      nothing below it.
    function test_A2R1_28_deployIdle_minDeployBoundary() public {
        AccumulationParams memory p = _params(2, 3, 0, address(morpho), false);
        p.config.contribution = K.MIN_DEPLOY; // $1, the smallest contribution
        _create(p);
        _join(people[0]);
        _join(people[1]);
        vm.warp(circle.startTime());
        vm.expectRevert(IMHAccumulationCircle.NothingToDeploy.selector);
        circle.deployIdle();
        _fund(people[0], K.MIN_DEPLOY);
        vm.prank(people[0]);
        circle.contribute(1, K.MIN_DEPLOY);
        assertEq(circle.idleAssets(), K.MIN_DEPLOY);
        circle.deployIdle();
        assertEq(circle.idleAssets(), 0);
    }
}
