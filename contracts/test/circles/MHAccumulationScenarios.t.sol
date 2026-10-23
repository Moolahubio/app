// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";

import { MockVaultV2 } from "../mocks/MockVaultV2.sol";

/// @notice Spec §4.5 accumulation example (A/B/C compliant, D missed 2 rounds, illustrative 10% fee) and its 1% loss
///         case with exact numbers, the §4.7 regressions R2, R3 and R8, the n = 50 gas bound, and fuzzed §4.7
///         accumulation properties. Exact expected values come from an independent integer Python model of the
///         spec rules over Vault V2's conversion formulas (`scratchpad/sim/acc_ref.py`, outside the repo).
contract MHAccumulationScenariosTest is AccumulationFixture {
    uint16 internal constant FEE_10PCT = 1_000;
    uint256 internal constant CENT = 1e4;
    uint256 internal constant SKIP_D = (1 << 4) | (1 << 8); // D misses rounds 4 and 8
    uint256 internal constant D = 3; // member index of D

    // ================================================================ Spec §4.5 accumulation example

    /// @dev 4 members, $100 a month, 12 rounds, deployed every round. D skips rounds 4 and 8 (P = $1,000).
    ///      `yieldOrLoss` is applied to the vault after the last contribution, so every member has the same value
    ///      per dollar (V = 1.025·P with +$115, V = 0.99·P with −$46).
    function _runSpecExample(bool loss) internal {
        _startYield(4, FEE_10PCT);
        _runRounds(_everyone(), D, SKIP_D);
        assertEq(circle.nav(), 4_600e6);
        if (loss) morpho.mockLoss(46e6);
        else morpho.mockYield(115e6);
        // Round 12 is open, so the grace of rounds 4 and 8 is long over.
        circle.flagRound(4);
        circle.flagRound(8);
        assertEq(
            reputation.strikesByReason(people[D], IMHReputation.Reason.MISSED), 2, "D: two MISSED strikes"
        );
        assertEq(reputation.strikeCount(people[0]), 0);
        _mature();
    }

    function test_specExample_compliantShareDsForfeit_fee10pct() public {
        _runSpecExample(false);
        address a = people[0];
        address d = people[D];

        // Values before maturity: A, B, C ≈ $1,230; D ≈ $1,025.
        assertApproxEqAbs(circle.memberValue(a), 1_230e6, 1);
        assertApproxEqAbs(circle.memberValue(d), 1_025e6, 1);

        // finalize: D keeps toShares($1,000) and forfeits ≈ $25.
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.Forfeited(d, 24_390_243_690_350);
        vm.expectEmit(false, false, false, true, address(circle));
        emit IMHAccumulationCircle.Finalized(4_714_999_999, 24_390_243_690_350, 3_600_000_000_000_000);
        circle.finalize();
        assertApproxEqAbs(_toAssets(circle.forfeitSnap()), 25e6, 1, "D forfeits $25");
        assertApproxEqAbs(_toAssets(circle.forfeitSnap() / 3), 8_333_333, 1, "A, B, C get $8.33 each");

        // A: gross $1,238.33, earnings $38.33, fee $3.83, net $1,234.50.
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(a, 1_200e6, 1_238_333_332, 3_833_333, true);
        circle.settleMember(a);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(people[1], 1_200e6, 1_238_333_333, 3_833_333, true);
        circle.settleMember(people[1]);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(people[2], 1_200e6, 1_238_333_333, 3_833_333, true);
        circle.settleMember(people[2]);
        // D: $1,000, no fee.
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHAccumulationCircle.MemberSettled(d, 1_000e6, 1_000e6, 0, false);
        circle.settleMember(d);

        assertEq(usdc.balanceOf(a), 1_234_499_999);
        assertEq(usdc.balanceOf(people[1]), 1_234_500_000);
        assertEq(usdc.balanceOf(people[2]), 1_234_500_000);
        assertEq(usdc.balanceOf(d), 1_000e6);
        // Within a cent of the spec's dollars-and-cents figures.
        assertApproxEqAbs(usdc.balanceOf(a), 1_234_50 * CENT, CENT);
        assertApproxEqAbs(usdc.balanceOf(d), 1_000_00 * CENT, CENT);
        assertEq(usdc.balanceOf(treasury), 11_499_999, "three fees of $3.83");
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        _assertBuckets();

        // What is left is dust: 2 forfeit shares of bonus rounding plus the virtual-share remainder (1 unit).
        assertEq(circle.residualShares(), 2);
        assertEq(circle.idleAssets(), 0);
        assertEq(morpho.convertToAssets(circle.vaultShares()), 1);
        circle.sweepResidual();
        assertEq(morpho.convertToAssets(morpho.balanceOf(treasury)), 1);
    }

    function test_specExample_onePercentLoss_noForfeitNoFee() public {
        _runSpecExample(true);
        uint256 accD = circle.memberState(people[D]).accShares;
        circle.finalize();
        assertEq(circle.memberState(people[D]).accShares, accD, "no forfeit after a loss");
        assertEq(circle.forfeitSnap(), 0);
        _settleAll();
        for (uint256 i; i < 3; ++i) {
            assertEq(usdc.balanceOf(people[i]), 1_188e6, "A, B, C get $1,188");
        }
        assertEq(usdc.balanceOf(people[D]), 990e6, "D gets $990");
        assertEq(usdc.balanceOf(treasury), 0, "no fee after a loss");
        _assertBuckets();
    }

    /// @dev Settlement order only moves floor-rounding dust (reference model, order D, C, B, A). Settling first,
    ///      D gets $999.999999: its retained shares are `floor(toShares(P))` and the payout is floored, both against
    ///      the member leaving (spec §4.3), so a delinquent member never gets more than its principal.
    function test_specExample_settlementOrderOnlyMovesDust() public {
        _runSpecExample(false);
        circle.finalize();
        for (uint256 i = 4; i > 0; --i) {
            circle.settleMember(people[i - 1]);
        }
        assertEq(usdc.balanceOf(people[D]), 999_999_999);
        for (uint256 i; i < 3; ++i) {
            assertEq(usdc.balanceOf(people[i]), 1_234_500_000);
        }
        assertEq(usdc.balanceOf(treasury), 11_499_999);
    }

    /// @dev The same circle with no vault: no yield, so nobody gains, nobody forfeits and no fee is charged.
    function test_noYieldCircle_everyoneGetsPrincipal() public {
        _start(4, 12, FEE_10PCT, address(0), false);
        _runRounds(_everyone(), D, SKIP_D);
        assertEq(circle.idleAssets(), 4_600e6);
        assertEq(circle.vaultShares(), 0);
        _mature();
        vm.recordLogs();
        circle.finalize();
        // D's value equals its principal exactly: no cap, not even a zero `Forfeited`.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k; k < logs.length; ++k) {
            assertTrue(logs[k].topics[0] != IMHAccumulationCircle.Forfeited.selector, "nothing forfeited");
        }
        assertEq(circle.forfeitSnap(), 0);
        _settleAll();
        for (uint256 i; i < 4; ++i) {
            assertEq(_net(people[i]), 0, "principal back exactly");
        }
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(circle)), 0);
        vm.expectRevert(IMHCircle.NothingToClaim.selector);
        circle.sweepResidual();
    }

    // ================================================================ Regressions

    /// @dev R2: the legacy `setAdapter` was an admin path to principal. The circle's vault is fixed at
    ///      `initialize`; no setter exists, and registry changes never reach a live circle.
    function test_R2_noAdminPathToTheVault() public {
        _startYield(3, 0);
        _runRounds(_everyone(), 0, 0);
        bytes4[6] memory selectors = [
            bytes4(keccak256("setAdapter(address)")),
            bytes4(keccak256("setVault(address)")),
            bytes4(keccak256("setConfigurer(address)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        address[5] memory admins = [gov, address(timelock), guardian, operator, treasury];
        for (uint256 i; i < admins.length; ++i) {
            for (uint256 j; j < selectors.length; ++j) {
                vm.prank(admins[i]);
                (bool ok,) = address(circle).call(abi.encodeWithSelector(selectors[j], attacker, 1));
                assertFalse(ok, "no such function");
            }
        }
        // Allowlisting another vault or delisting this one changes nothing for the live circle.
        MockVaultV2 other = new MockVaultV2(address(usdc), attacker);
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(other))));
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        assertEq(circle.vault(), address(morpho));
        assertFalse(circle.yieldOff());
        _mature();
        circle.finalize();
        _settleAll();
        for (uint256 i; i < 3; ++i) {
            assertEq(_net(people[i]), 0);
        }
        assertEq(other.totalAssets(), 0);
    }

    /// @dev R3: the legacy emergency exit used `max*` and redeemed everything at once, reverting exactly when the
    ///      vault was illiquid. Here: the Guardian switches yield off with a zero chunk, anyone pulls chunks as
    ///      liquidity returns, liquid members settle in cash and the rest in kind. The mock reverts on any `max*`
    ///      call, so none is made.
    function test_R3_illiquidity_chunkedExit_inKindSettlement() public {
        _startYield(4, FEE_10PCT);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(96e6); // 2%
        _mature();
        circle.finalize();
        uint256 navBefore = circle.nav();

        morpho.mockSetLiquidity(0); // the liquidity adapter's market is fully borrowed
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.settleMember(people[0]);
        vm.prank(guardian);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.emergencyExit(type(uint256).max); // the R3 failure mode: one big redeem
        vm.prank(guardian);
        circle.emergencyExit(0); // works while fully illiquid
        assertTrue(circle.yieldOff());

        // Liquidity trickles back: anyone pulls it in bounded chunks.
        morpho.mockSetLiquidity(1_300e6);
        uint256 chunk = morpho.previewWithdraw(650e6);
        vm.prank(attacker);
        circle.pullFromVault(chunk);
        circle.pullFromVault(chunk);
        assertApproxEqAbs(circle.idleAssets(), 1_300e6, 2);
        assertApproxEqAbs(circle.nav(), navBefore, 2, "chunked exit keeps NAV");
        _assertBuckets();

        // Audit R2-06 (was: member 0 settled in cash from the pulled idle USDC): a cash settlement takes only its
        // pro-rata part of idle and needs the vault for the rest, so while the vault stays illiquid it reverts
        // instead of draining the idle USDC ahead of the members settling in kind. Everyone settles in kind.
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.settleMember(people[0]);
        for (uint256 i; i < 4; ++i) {
            vm.prank(people[i]);
            circle.settleMemberInKind(people[i]);
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        _assertBuckets();
        // Everyone kept their yield net of the fee on earnings (vault shares valued at the redeem price).
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(_net(people[i]), int256(21_600_000), 3, "24 earned - 2.4 fee");
        }
    }

    /// @dev A conservative (discounted) `previewRedeem` understates NAV: payouts are smaller, nothing reverts, and
    ///      the difference is left as residual rather than over-withdrawn.
    function test_previewRedeemDrift_conservativeNavStaysSolvent() public {
        _startYield(3, FEE_10PCT);
        _runRounds(_everyone(), 0, 0);
        morpho.mockYield(36e6);
        morpho.mockSetPreviewRedeemDiscount(5e6);
        _mature();
        circle.finalize();
        _settleAll();
        _assertBuckets();
        for (uint256 i; i < 3; ++i) {
            assertGt(_net(people[i]), 0);
        }
        uint256 left = morpho.convertToAssets(circle.vaultShares()) + circle.idleAssets();
        assertApproxEqAbs(left, 5e6, 2, "the preview gap stays in the circle as residual");
        morpho.mockSetPreviewRedeemDiscount(0);
        circle.sweepResidual();
    }

    /// @dev PR #36 (the CI invariant counterexample as a scenario): the Guardian's `forceExit` pays a 2% force-
    ///      deallocation penalty mid-schedule, whose value accrues to the vault's other holders, so the circle's
    ///      share price falls. Each member bears the loss pro rata to the principal it had in the pool at that
    ///      moment, the losses add up to exactly the circle's NAV loss, and no fee is charged (no earnings). D,
    ///      which skipped round 2 and so held less when the price fell, ends with more per dollar than A: the
    ///      per-dollar claim of invariant 6 is for a non-decreasing price (step 4, deviation 3), as in the spec's
    ///      own 1%-loss example (no forfeit, no fee).
    function test_PR36_forceExitPenaltyMidSchedule_lossProRataToExposure() public {
        address outsider = makeAddr("outsider"); // another depositor of the vault
        usdc.mint(outsider, 1_000e6);
        vm.startPrank(outsider);
        usdc.approve(address(morpho), 1_000e6);
        morpho.deposit(1_000e6, outsider);
        vm.stopPrank();

        _start(4, 5, 35, address(morpho), false);
        _openRound(1);
        _payAll(1, _everyone());
        _openRound(2);
        _payAll(2, _allBut(D));
        _deploy();
        uint256 navBefore = circle.nav();
        assertEq(navBefore, 7 * C, "every USDC in the vault, at par");
        morpho.mockSetForceDeallocatePenalty(address(liqAdapter), 0.02e18);
        vm.prank(guardian);
        circle.forceExit(address(liqAdapter), "", navBefore);
        uint256 loss = navBefore - circle.nav();
        assertGt(loss, 0, "the penalty lowered the share price");
        for (uint256 r = 3; r <= 5; ++r) {
            _openRound(r);
            _payAll(r, r == 5 ? _allBut(D) : _everyone());
        }
        _mature();
        circle.finalize();
        assertEq(circle.forfeitSnap(), 0, "D is below its principal: nothing capped");
        _settleAll();
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));

        uint256 sumLoss;
        for (uint256 i; i < 4; ++i) {
            IMHAccumulationCircle.MemberState memory st = circle.memberState(people[i]);
            uint256 exposure = i == D ? C : 2 * C; // principal in the pool when the penalty hit
            assertLe(st.cashOut, st.principal, "a loss");
            assertApproxEqAbs(
                st.principal - st.cashOut, exposure * loss / navBefore, 1, "pro rata to exposure"
            );
            sumLoss += st.principal - st.cashOut;
        }
        assertEq(sumLoss, loss, "the members bear exactly the circle's loss");
        assertEq(usdc.balanceOf(treasury), 0, "no fee without earnings");
        // Per dollar: A (5 rounds paid) < D (3 rounds paid).
        assertLt(
            circle.memberState(people[0]).cashOut * 3,
            circle.memberState(people[D]).cashOut * 5,
            "A < D per $"
        );
    }

    /// @dev R8: no try/catch and no low-level `_pay`, so a call given too little gas reverts as a whole. Sweeps the
    ///      gas limit up to the first success and checks that every failure left no partial state.
    function test_R8_outOfGasIsAtomic() public {
        _startYield(4, FEE_10PCT);
        _openRound(1);
        _fund(people[0], C);
        _gasSweep(people[0], abi.encodeCall(MHAccumulationCircle.contribute, (1, C)));
        _payAll(1, _allBut(3));
        _gasSweep(attacker, abi.encodeCall(MHAccumulationCircle.deployIdle, ()));
        _openRound(2);
        _payAll(2, _allBut(3));
        _deploy();
        morpho.mockYield(20e6);
        _gasSweep(people[1], abi.encodeCall(MHAccumulationCircle.exitEarly, ()));
        _afterCure(1);
        _gasSweep(attacker, abi.encodeCall(MHAccumulationCircle.flagRound, (1)));
        _gasSweep(guardian, abi.encodeCall(MHAccumulationCircle.emergencyExit, (1e20)));
        _mature();
        _gasSweep(attacker, abi.encodeCall(MHAccumulationCircle.finalize, ()));
        _gasSweep(attacker, abi.encodeCall(MHAccumulationCircle.settleMember, (people[0])));
        _gasSweep(people[2], abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (people[2])));
        _assertBuckets();
    }

    function _probe() internal view returns (bytes32) {
        uint256 strikes;
        for (uint256 i; i < 4; ++i) {
            strikes += reputation.strikeCount(people[i]);
        }
        return keccak256(
            abi.encode(
                circle.status(),
                circle.totalShares(),
                circle.accTotal(),
                circle.forfeitShares(),
                circle.residualShares(),
                circle.idleAssets(),
                circle.vaultShares(),
                circle.settledCount(),
                circle.owedTotal(),
                circle.yieldOff(),
                usdc.balanceOf(address(circle)),
                morpho.balanceOf(address(circle)),
                strikes
            )
        );
    }

    function _gasSweep(address caller, bytes memory data) internal returns (uint256) {
        bytes32 before = _probe();
        for (uint256 g = 21_000; g < 2_000_000; g += 2_000) {
            vm.prank(caller);
            (bool ok,) = address(circle).call{ gas: g }(data);
            if (ok) return g;
            assertEq(_probe(), before, "partial state after running out of gas");
        }
        revert("never succeeded");
    }

    // ================================================================ Gas at n = 50 (spec §4.7 invariant 8)

    uint256 internal constant GAS_CAP = 5_000_000;

    function _measure(address caller, bytes memory data, string memory label) internal returns (uint256 g) {
        vm.prank(caller);
        g = gasleft();
        (bool ok,) = address(circle).call(data);
        g -= gasleft();
        assertTrue(ok, label);
        emit log_named_uint(label, g);
        assertLt(g, GAS_CAP);
    }

    /// @dev Worst case for `flagRound`: all 50 members missed the round, so 50 MISSED strikes.
    function test_gas_n50_flagRoundWith50Strikes() public {
        _start(50, 2, 0, address(morpho), false);
        _openRound(2);
        _afterCure(1);
        _measure(attacker, abi.encodeCall(MHAccumulationCircle.flagRound, (1)), "flagRound, 50 strikes, n=50");
        assertEq(reputation.strikeCount(people[49]), 1);
    }

    /// @dev Worst case for `finalize`: 1 compliant member and 49 delinquent members, all above principal, so 49
    ///      caps.
    function test_gas_n50_finalizeWith49Caps() public {
        _start(50, 2, FEE_10PCT, address(morpho), false);
        _pay(people[0], 1);
        _openRound(2);
        _payAll(2, _everyone());
        circle.deployIdle();
        morpho.mockYield(51e6);
        _mature();
        _measure(attacker, abi.encodeCall(MHAccumulationCircle.finalize, ()), "finalize, 49 caps, n=50");
        assertLe(circle.memberValue(people[49]), C);
        _settleAll();
        _assertBuckets();
    }

    function test_gas_n50_guardianCancelAndSettlements() public {
        _start(50, 12, FEE_10PCT, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        morpho.mockYield(50e6);
        vm.prank(people[0]);
        circle.exitEarly(); // a forfeit to split
        _measure(guardian, abi.encodeCall(MHAccumulationCircle.guardianCancel, ()), "guardianCancel, n=50");
        _measure(people[1], abi.encodeCall(MHAccumulationCircle.claim, ()), "claim");
        _measure(people[2], abi.encodeCall(MHAccumulationCircle.claimInKind, ()), "claimInKind");
        _assertBuckets();
    }

    function test_gas_n50_settlementsAndExit() public {
        _start(50, 2, FEE_10PCT, address(morpho), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        _openRound(2);
        _payAll(2, _allBut(49));
        circle.deployIdle();
        morpho.mockYield(99e6);
        _measure(people[48], abi.encodeCall(MHAccumulationCircle.exitEarly, ()), "exitEarly");
        _mature();
        circle.finalize();
        _measure(attacker, abi.encodeCall(MHAccumulationCircle.settleMember, (people[0])), "settleMember");
        _measure(
            people[1],
            abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (people[1])),
            "settleMemberInKind"
        );
        _settleAll();
        _measure(attacker, abi.encodeCall(MHAccumulationCircle.sweepResidual, ()), "sweepResidual");
    }

    // ================================================================ Fuzz (spec §4.7 invariants 1–6)

    /// @dev Fee of the circle under fuzz (kept in storage to stay clear of the stack limit).
    uint16 internal fuzzFee;

    /// @dev Random members, rounds, fee and missed rounds; a uniform yield or loss applied after the last
    ///      contribution; optional early exit. Checks the share and balance invariants after every step and, at
    ///      the end, §4.7 invariant 6: Σ bonus ≤ forfeitSnap, a delinquent member gets at most its principal, a
    ///      compliant member at least as much per dollar as a delinquent one, and the fee only on earnings.
    function testFuzz_accumulationProperties(
        uint256 nSeed,
        uint256 roundsSeed,
        uint16 feeSeed,
        int16 moveBps,
        uint256 seed
    ) public {
        uint256 n = bound(nSeed, 2, 8);
        uint256 rounds = bound(roundsSeed, 1, 6);
        fuzzFee = uint16(bound(feeSeed, 0, K.MAX_ACCUMULATION_FEE_BPS));
        int256 move = bound(int256(moveBps), -2_000, 2_000); // −20% … +20%
        // forge-lint: disable-next-line(unsafe-typecast)
        _start(n, uint32(rounds), fuzzFee, address(morpho), false);
        _payRandomly(n, rounds, seed);
        if (seed % 3 == 0) {
            vm.prank(people[0]); // an early exit, before any yield or loss
            circle.exitEarly();
            _assertBuckets();
        }
        uint256 vaultAssets = morpho.totalAssets();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 delta = vaultAssets * uint256(move < 0 ? -move : move) / 10_000;
        if (move > 0) morpho.mockYield(delta);
        else if (move < 0) morpho.mockLoss(delta);
        _mature();
        circle.finalize();
        _assertBuckets();

        (uint256 bonusSum, uint256 residualBefore) = _checkBonusBound(n);
        _settleAndCheckFees();
        assertGe(
            circle.residualShares() - residualBefore,
            circle.forfeitSnap() - bonusSum,
            "bonus dust to residual"
        );
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed));
        _assertBuckets();
        // Nothing but dust reaches the treasury beyond fees.
        uint256 fees = usdc.balanceOf(treasury);
        if (circle.idleAssets() != 0 || circle.vaultShares() != 0) circle.sweepResidual();
        uint256 residual =
            usdc.balanceOf(treasury) - fees + morpho.convertToAssets(morpho.balanceOf(treasury));
        assertLe(residual, n + 2, "residual is rounding dust");
        if (move <= 0) assertEq(fees, 0, "no fee without earnings");
    }

    /// @dev Each member skips each round with probability 1/5; the keeper deploys after each round.
    function _payRandomly(uint256 n, uint256 rounds, uint256 seed) internal {
        for (uint256 r = 1; r <= rounds; ++r) {
            _openRound(r);
            uint256 payers;
            for (uint256 i; i < n; ++i) {
                // forge-lint: disable-next-line(incorrect-shift)
                if (uint256(keccak256(abi.encode(seed, i, r))) % 5 != 0) payers |= 1 << i;
            }
            _payAll(r, payers);
            _deploy();
            _assertBuckets();
        }
    }

    /// @dev Σ floor(forfeitSnap·acc/bonusBase) over every member eligible for a bonus is at most forfeitSnap.
    function _checkBonusBound(uint256 n) internal view returns (uint256 bonusSum, uint256 residualBefore) {
        uint256 forfeitSnap = circle.forfeitSnap();
        uint256 base = circle.bonusBase();
        bool anyCompliant = circle.compliantSnap() != 0;
        for (uint256 i; i < n; ++i) {
            IMHAccumulationCircle.MemberState memory st = circle.memberState(people[i]);
            if (st.settled || base == 0 || (anyCompliant && !st.compliant)) continue;
            bonusSum += forfeitSnap * st.accShares / base;
        }
        assertLe(bonusSum, forfeitSnap, "sum of bonuses <= forfeitSnap");
        residualBefore = circle.residualShares();
    }

    /// @dev Settles everyone and checks each `MemberSettled`: fee only on earnings; a delinquent member at most its
    ///      principal (unless nobody is compliant); compliant per dollar ≥ delinquent per dollar.
    function _settleAndCheckFees() internal {
        bool anyCompliant = circle.compliantSnap() != 0;
        vm.recordLogs();
        _settleAll();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Worst compliant and best delinquent outcome per dollar, scaled by 1e18.
        uint256 minCompliant = type(uint256).max;
        uint256 maxDelinquent;
        for (uint256 k; k < logs.length; ++k) {
            if (
                logs[k].emitter != address(circle)
                    || logs[k].topics[0] != IMHAccumulationCircle.MemberSettled.selector
            ) continue;
            (uint256 principal, uint256 gross, uint256 fee, bool compliant) =
                abi.decode(logs[k].data, (uint256, uint256, uint256, bool));
            uint256 earnings = gross > principal ? gross - principal : 0;
            // Audit R1-10: when nobody is compliant everyone pays the fee on earnings.
            bool feeable = compliant || !anyCompliant;
            assertEq(fee, feeable ? earnings * fuzzFee / 10_000 : 0, "fee only on earnings");
            if (principal == 0) continue;
            if (compliant) {
                uint256 pd = (gross - fee) * 1e18 / principal;
                if (pd < minCompliant) minCompliant = pd;
            } else if (anyCompliant) {
                // Capped once at finalize (audit R1-11); only rounding moved the share price since.
                assertLe(gross, principal + 10, "a delinquent member gets at most its principal");
                uint256 pd = gross * 1e18 / principal;
                if (pd > maxDelinquent) maxDelinquent = pd;
            }
        }
        if (minCompliant != type(uint256).max && maxDelinquent != 0) {
            // Allow one micro-USDC of floor rounding on a principal of at least $1.
            assertGe(minCompliant + 1e12, maxDelinquent, "compliant >= delinquent per dollar");
        }
    }

    /// @dev §4.7 invariant 4: with owner, Guardian, operator, treasury and attacker poking every function with
    ///      random arguments mid-life (and the Guardian using its real powers: chunked emergency exits, extensions,
    ///      a cancellation), no USDC or vault share reaches a non-member except fees and dust to the treasury, and
    ///      no member loses principal when the vault only gains.
    function testFuzz_noAdminPathToPrincipal(uint256 seed) public {
        uint256 n = bound(seed, 2, 6);
        _start(n, 4, uint16(bound(seed >> 8, 0, K.MAX_ACCUMULATION_FEE_BPS)), address(morpho), false);
        address[6] memory actors = [gov, address(timelock), guardian, operator, treasury, attacker];
        uint256 yield;
        for (uint256 r = 1; r <= 4; ++r) {
            _openRound(r);
            _payAll(r, uint256(keccak256(abi.encode(seed, "pay", r))) | 1);
            _deploy();
            for (uint256 k; k < 6; ++k) {
                uint256 h = uint256(keccak256(abi.encode(seed, r, k)));
                _poke(actors[h % 6], h >> 8);
            }
            if (r == 2 && circle.vaultShares() != 0) {
                yield = (seed >> 16) % 50e6;
                morpho.mockYield(yield);
            }
            _assertBuckets();
        }
        _endLife();
        _assertBuckets();

        for (uint256 i; i < 5; ++i) {
            if (actors[i] == treasury) continue;
            assertEq(usdc.balanceOf(actors[i]), 0, "an admin received USDC");
            assertEq(morpho.balanceOf(actors[i]), 0, "an admin received vault shares");
        }
        assertEq(usdc.balanceOf(attacker), 0);
        int256 memberNet;
        for (uint256 i; i < n; ++i) {
            int256 net = _net(people[i]);
            assertGe(net, -2, "a member lost principal");
            memberNet += net;
        }
        uint256 toTreasury = usdc.balanceOf(treasury) + circle.owed(treasury)
            + morpho.convertToAssets(morpho.balanceOf(treasury));
        // Audit R1-11 / R1-31: bounded by this circle's own fee, not the global cap.
        assertLe(toTreasury, yield * circle.feeBps() / 10_000 + n + 3, "treasury: fees and dust only");
    }

    /// @dev One call by `actor` to a random circle function with random arguments; failures are expected.
    function _poke(address actor, uint256 h) internal {
        uint256 x = h >> 8;
        bytes memory data;
        uint256 pick = h % 16;
        if (pick == 0) {
            data = abi.encodeCall(MHAccumulationCircle.emergencyExit, (x % 2e20));
        } else if (pick == 1) {
            data = abi.encodeCall(MHAccumulationCircle.extendDeadline, (x % 8 days));
        } else if (pick == 2) {
            data = abi.encodeCall(MHAccumulationCircle.guardianCancel, ());
        } else if (pick == 3) {
            data = abi.encodeCall(MHAccumulationCircle.pullFromVault, (x % 2e20));
        } else if (pick == 4) {
            data = abi.encodeCall(MHAccumulationCircle.deployIdle, ());
        } else if (pick == 5) {
            data = abi.encodeCall(MHAccumulationCircle.flagRound, (x % 5));
        } else if (pick == 6) {
            data = abi.encodeCall(MHAccumulationCircle.finalize, ());
        } else if (pick == 7) {
            data = abi.encodeCall(MHAccumulationCircle.settleMember, (people[x % 6]));
        } else if (pick == 8) {
            data = abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (people[x % 6]));
        } else if (pick == 9) {
            data = abi.encodeCall(MHAccumulationCircle.sweepDonations, ());
        } else if (pick == 10) {
            data = abi.encodeCall(MHAccumulationCircle.sweepResidual, ());
        } else if (pick == 11) {
            data = abi.encodeCall(MHAccumulationCircle.claim, ());
        } else if (pick == 12) {
            data = abi.encodeCall(MHAccumulationCircle.claimInKind, ());
        } else if (pick == 13) {
            data = abi.encodeCall(MHAccumulationCircle.exitEarly, ());
        } else if (pick == 14) {
            data = abi.encodeCall(MHAccumulationCircle.contribute, (x % 5, type(uint256).max));
        } else {
            data = abi.encodeCall(IMHCircle.claimOwed, ());
        }
        vm.prank(actor);
        (bool ok,) = address(circle).call(data);
        ok; // reverts are expected for most pokes
        if (actor == guardian && h % 7 == 0) {
            vm.prank(guardian);
            registry.disallowVault(address(morpho));
        }
    }

    /// @dev Drives any state to the end: Active → finalize → settle; Cancelled → claims; then sweeps.
    function _endLife() internal {
        if (circle.status() == CircleStatus.Active) {
            _mature();
            vm.warp(block.timestamp + 30 days); // past any extension
            circle.finalize();
        }
        address[] memory m = circle.members();
        if (circle.status() == CircleStatus.Matured) _settleAll();
        // Claims after a cancellation, or exit forfeits returned when nobody remained (audit R1-09).
        for (uint256 i; i < m.length; ++i) {
            if (circle.memberState(m[i]).claimShares == 0) continue;
            vm.prank(m[i]);
            circle.claim();
        }
        if (
            circle.accTotal() == 0 && circle.claimTotal() == 0
                && (circle.idleAssets() != 0 || circle.vaultShares() != 0)
        ) {
            circle.sweepResidual();
        }
    }

    /// @dev Conversion rounding (spec §4.3) never favours the leaver: a mint-then-payout round trip returns at most
    ///      what went in, and a ceil burn for a floor payout never exceeds the shares held.
    function testFuzz_conversionRoundingAgainstTheLeaver(uint256 a, uint256 nav, uint256 total) public pure {
        a = bound(a, 0, 1e18);
        nav = bound(nav, 0, 1e18);
        total = bound(total, 0, 1e30);
        uint256 shares = a * (total + 1e6) / (nav + 1); // mint: floor
        uint256 back = shares * (nav + 1) / (total + 1e6); // payout: floor
        assertLe(back, a);
        uint256 burn = (back * (total + 1e6) + nav) / (nav + 1); // burn: ceil
        assertLe(burn, shares);
    }
}
