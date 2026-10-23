// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BoundaryGas } from "./BoundaryGas.sol";
import { RotatingFixture } from "./RotatingFixture.sol";
import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../src/circles/interfaces/IMHRotatingCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import {
    CircleMode,
    CircleStatus,
    RotatingParams,
    AccumulationParams
} from "../../src/circles/MHCircleTypes.sol";

/// @notice R8 boundary-gas test on every state-changing public function of `MHRotatingCircle` (see `BoundaryGas`).
///         Each case sets up the most interesting state for the function (a payout, a cover with a strike, a queued
///         payout, an unwind with strikes, ...) and checks that no gas limit yields a partial outcome.
contract MHRotatingBoundaryGasTest is RotatingFixture, BoundaryGas {
    uint256 internal constant N = 4;
    uint16 internal constant FEE = 200;

    function _probe() internal view override returns (bytes32) {
        MHRotatingCircle c = circle;
        bytes memory s = abi.encode(c.status(), c.nextSettle(), c.extension(), c.joinedCount(), c.secTotal());
        s = abi.encode(s, c.potTotal(), c.feeEscrow(), c.claimTotal(), c.residual(), c.owedTotal());
        s = abi.encode(s, usdc.balanceOf(address(c)), usdc.balanceOf(treasury), c.owed(treasury));
        address[] memory m = c.members();
        for (uint256 i; i < m.length; ++i) {
            s = abi.encode(
                s,
                c.memberState(m[i]),
                c.owed(m[i]),
                usdc.balanceOf(m[i]),
                reputation.strikeCount(m[i]),
                c.pot(i + 1),
                c.paid(c.nextSettle(), m[i])
            );
        }
        return keccak256(s);
    }

    function _r(bytes memory data, address caller, string memory label) internal {
        _boundary(address(circle), caller, data, label);
    }

    // ---------------------------------------------------------------- Member actions

    function test_R8_boundary_join_lastJoinActivatesWithCollateral() public {
        _create(_params(N, FEE, 10_000));
        for (uint256 i; i < N - 1; ++i) {
            _join(slots[i], 0);
        }
        _fund(slots[N - 1], 500e6);
        _r(abi.encodeCall(MHRotatingCircle.join, (circle.termsHash(), 500e6)), slots[N - 1], "join");
    }

    function test_R8_boundary_depositCollateral() public {
        _startCircle(N, FEE, 10_000);
        _fund(slots[1], 300e6);
        _r(abi.encodeCall(MHRotatingCircle.depositCollateral, (300e6)), slots[1], "depositCollateral");
    }

    function test_R8_boundary_contribute_lateWithStrike() public {
        _startCircle(N, FEE, 10_000);
        _afterGrace(1);
        _fund(slots[2], C);
        _r(abi.encodeCall(MHRotatingCircle.contribute, (1, C)), slots[2], "contribute (late, LATE strike)");
    }

    function test_R8_boundary_withdrawSecurity() public {
        uint256[] memory col = new uint256[](2);
        col[1] = 900e6; // S_2 = 200
        _startCircle(N, FEE, 10_000, col);
        _r(abi.encodeCall(MHRotatingCircle.withdrawSecurity, (700e6)), slots[1], "withdrawSecurity");
    }

    function test_R8_boundary_claim() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, type(uint256).max ^ 1); // slot 1 defaults
        _afterCure(1);
        circle.cancelStalled();
        _r(abi.encodeCall(MHRotatingCircle.claim, ()), slots[1], "claim");
    }

    function test_R8_boundary_claimOwed() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, _everyone());
        usdc.blacklist(slots[0]);
        circle.settleRound(); // slot 1's cash is queued
        usdc.unBlacklist(slots[0]);
        _r(abi.encodeCall(IMHCircle.claimOwed, ()), slots[0], "claimOwed");
    }

    // ---------------------------------------------------------------- Permissionless transitions

    function test_R8_boundary_settleRound_coverStrikeAndPayout() public {
        uint256[] memory col = new uint256[](2);
        col[1] = 300e6; // slot 2 can be covered
        _startCircle(N, FEE, 10_000, col);
        _payAll(1, type(uint256).max ^ 2);
        _afterGrace(1);
        _r(
            abi.encodeCall(MHRotatingCircle.settleRound, ()),
            attacker,
            "settleRound (cover + strike + payout)"
        );
    }

    function test_R8_boundary_settleRound_queuedPayout() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, _everyone());
        usdc.blacklist(slots[0]);
        _r(abi.encodeCall(MHRotatingCircle.settleRound, ()), attacker, "settleRound (payout queued)");
    }

    function test_R8_boundary_cancelStalled() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, type(uint256).max ^ 3); // slots 1 and 2 default
        _afterCure(1);
        _r(abi.encodeCall(MHRotatingCircle.cancelStalled, ()), attacker, "cancelStalled (unwind + strikes)");
    }

    function test_R8_boundary_cancelUnjoined() public {
        _create(_params(N, FEE, 10_000));
        _join(slots[0], 250e6);
        _join(slots[1], 0);
        vm.warp(circle.joinDeadline() + 1);
        _r(abi.encodeCall(MHRotatingCircle.cancelUnjoined, ()), attacker, "cancelUnjoined");
    }

    function test_R8_boundary_flushFees() public {
        _startCircle(2, FEE, 10_000);
        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            _payAll(r, _everyone());
            circle.settleRound();
        }
        _r(abi.encodeCall(MHRotatingCircle.flushFees, ()), attacker, "flushFees");
    }

    function test_R8_boundary_sweepDonations() public {
        _startCircle(N, FEE, 10_000);
        usdc.mint(address(circle), 5e6);
        _r(abi.encodeCall(MHRotatingCircle.sweepDonations, ()), attacker, "sweepDonations");
    }

    function test_R8_boundary_sweepResidual() public {
        _startCircle(3, FEE, 10_000);
        _payAll(1, _everyone());
        circle.settleRound();
        _openRound(2);
        _payAll(2, type(uint256).max ^ 4); // slot 3 defaults: penalty dust leaves a residual
        _afterCure(2);
        circle.cancelStalled();
        _claimAll();
        if (circle.residual() == 0) return; // nothing to test for this layout
        _r(abi.encodeCall(MHRotatingCircle.sweepResidual, ()), attacker, "sweepResidual");
    }

    // ---------------------------------------------------------------- Guardian

    function test_R8_boundary_guardianCancel() public {
        _startCircle(N, FEE, 10_000);
        _payAll(1, _everyone());
        _r(abi.encodeCall(MHRotatingCircle.guardianCancel, ()), guardian, "guardianCancel");
    }

    function test_R8_boundary_extendDeadline() public {
        _startCircle(N, FEE, 10_000);
        _r(abi.encodeCall(MHRotatingCircle.extendDeadline, (3 days)), guardian, "extendDeadline");
    }
}

/// @notice R8 boundary-gas test on every state-changing public function of `MHAccumulationCircle`.
contract MHAccumulationBoundaryGasTest is AccumulationFixture, BoundaryGas {
    uint256 internal constant N = 3;
    uint16 internal constant FEE = 1_000;

    function _probe() internal view override returns (bytes32) {
        MHAccumulationCircle c = circle;
        bytes memory s = abi.encode(
            c.status(), c.yieldOff(), c.extension(), c.joinedCount(), c.settledCount(), c.idleAssets()
        );
        s = abi.encode(s, c.vaultShares(), c.totalShares(), c.accTotal(), c.claimTotal(), c.forfeitShares());
        s = abi.encode(s, c.forfeitSnap(), c.compliantSnap(), c.residualShares(), c.lastLive());
        s = abi.encode(
            s,
            c.owedTotal(),
            usdc.balanceOf(address(c)),
            morpho.balanceOf(address(c)),
            usdc.balanceOf(treasury),
            morpho.balanceOf(treasury),
            c.owed(treasury),
            usdc.balanceOf(address(morpho)),
            c.roundFlagged(1),
            registry.isAllowedVault(address(morpho)) // closing review: `deployIdle`/`pullFromVault` may delist
        );
        address[] memory m = c.members();
        for (uint256 i; i < m.length; ++i) {
            s = abi.encode(
                s,
                c.memberState(m[i]),
                c.owed(m[i]),
                usdc.balanceOf(m[i]),
                morpho.balanceOf(m[i]),
                reputation.strikeCount(m[i])
            );
        }
        return keccak256(s);
    }

    function _r(bytes memory data, address caller, string memory label) internal {
        _boundary(address(circle), caller, data, label);
    }

    /// @dev Two rounds paid by everyone except member 3 in round 1, deployed, with 5% yield.
    function _midLife() internal {
        _start(N, 3, FEE, address(morpho), false);
        _payAll(1, _allBut(2));
        _deploy();
        _openRound(2);
        _payAll(2, _everyone());
        _deploy();
        morpho.mockYield(morpho.totalAssets() / 20);
    }

    function _matured() internal {
        _midLife();
        _openRound(3);
        _payAll(3, _everyone());
        _deploy();
        morpho.mockYield(morpho.totalAssets() / 20);
        _mature();
        circle.finalize();
    }

    // ---------------------------------------------------------------- Member actions

    function test_R8_boundary_join_lastJoinWithDelistedVault() public {
        _create(_params(N, 3, FEE, address(morpho), false));
        _join(people[0]);
        _join(people[1]);
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        _r(
            abi.encodeCall(MHAccumulationCircle.join, (circle.termsHash(), 0)),
            people[2],
            "join (vault delisted)"
        );
    }

    function test_R8_boundary_contribute() public {
        _midLife();
        _openRound(3);
        _fund(people[2], C);
        _r(abi.encodeCall(MHAccumulationCircle.contribute, (3, C)), people[2], "contribute");
    }

    function test_R8_boundary_exitEarly_withVaultWithdraw() public {
        _midLife();
        _r(abi.encodeCall(MHAccumulationCircle.exitEarly, ()), people[1], "exitEarly (vault withdraw)");
    }

    function test_R8_boundary_settleMemberInKind() public {
        _matured();
        _r(
            abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (people[0])),
            people[0],
            "settleMemberInKind"
        );
    }

    function test_R8_boundary_claim_afterCancel() public {
        _midLife();
        vm.prank(guardian);
        circle.guardianCancel();
        _r(abi.encodeCall(MHAccumulationCircle.claim, ()), people[0], "claim (vault withdraw)");
    }

    function test_R8_boundary_claimInKind() public {
        _midLife();
        vm.prank(guardian);
        circle.guardianCancel();
        _r(abi.encodeCall(MHAccumulationCircle.claimInKind, ()), people[0], "claimInKind");
    }

    function test_R8_boundary_claimOwed() public {
        _matured();
        usdc.blacklist(people[0]);
        circle.settleMember(people[0]);
        usdc.unBlacklist(people[0]);
        _r(abi.encodeCall(IMHCircle.claimOwed, ()), people[0], "claimOwed");
    }

    // ---------------------------------------------------------------- Permissionless transitions

    function test_R8_boundary_deployIdle() public {
        _start(N, 3, FEE, address(morpho), false);
        _payAll(1, _everyone());
        _r(abi.encodeCall(MHAccumulationCircle.deployIdle, ()), attacker, "deployIdle");
    }

    function test_R8_boundary_flagRound() public {
        _midLife();
        _afterCure(1);
        _r(abi.encodeCall(MHAccumulationCircle.flagRound, (1)), attacker, "flagRound (MISSED strike)");
    }

    function test_R8_boundary_finalize_withCap() public {
        _midLife();
        _openRound(3);
        _payAll(3, _everyone());
        _deploy();
        morpho.mockYield(morpho.totalAssets() / 10);
        _mature();
        _r(abi.encodeCall(MHAccumulationCircle.finalize, ()), attacker, "finalize (cap + forfeit)");
    }

    function test_R8_boundary_settleMember_withFeeAndVaultWithdraw() public {
        _matured();
        _r(abi.encodeCall(MHAccumulationCircle.settleMember, (people[0])), attacker, "settleMember (fee)");
    }

    function test_R8_boundary_pullFromVault() public {
        _midLife();
        vm.prank(guardian);
        circle.emergencyExit(0);
        _r(
            abi.encodeCall(MHAccumulationCircle.pullFromVault, (circle.vaultShares() / 2)),
            attacker,
            "pullFromVault"
        );
    }

    function test_R8_boundary_cancelUnjoined() public {
        _create(_params(N, 3, FEE, address(morpho), false));
        _join(people[0]);
        vm.warp(circle.joinDeadline() + 1);
        _r(abi.encodeCall(MHAccumulationCircle.cancelUnjoined, ()), attacker, "cancelUnjoined");
    }

    function test_R8_boundary_sweepDonations_usdcAndShares() public {
        _midLife();
        usdc.mint(address(circle), 3e6);
        usdc.mint(attacker, 10e6);
        vm.startPrank(attacker);
        usdc.approve(address(morpho), 10e6);
        morpho.deposit(10e6, address(circle));
        vm.stopPrank();
        _r(abi.encodeCall(MHAccumulationCircle.sweepDonations, ()), attacker, "sweepDonations");
    }

    function test_R8_boundary_sweepResidual() public {
        _matured();
        _settleAll();
        _r(abi.encodeCall(MHAccumulationCircle.sweepResidual, ()), attacker, "sweepResidual");
    }

    // ---------------------------------------------------------------- Guardian

    function test_R8_boundary_emergencyExit_chunk() public {
        _midLife();
        _r(
            abi.encodeCall(MHAccumulationCircle.emergencyExit, (circle.vaultShares() / 3)),
            guardian,
            "emergencyExit (chunk)"
        );
    }

    function test_R8_boundary_guardianCancel() public {
        _midLife();
        vm.prank(people[1]);
        circle.exitEarly(); // a forfeit to split
        _r(abi.encodeCall(MHAccumulationCircle.guardianCancel, ()), guardian, "guardianCancel");
    }

    function test_R8_boundary_extendDeadline() public {
        _midLife();
        _r(abi.encodeCall(MHAccumulationCircle.extendDeadline, (2 days)), guardian, "extendDeadline");
    }

    /// @dev Audit 2 R1-12: the permissionless NAV-free cancel (with its bounded `previewRedeem` probe; too little gas
    ///      reverts `InsufficientGas`, never a cancel of a healthy vault). Its minimum is above `NAV_PROBE_MIN_GAS`.
    function test_R8_boundary_cancelExpired() public {
        _midLife();
        vm.prank(people[1]);
        circle.exitEarly(); // a forfeit to split
        morpho.mockSetNavBroken(true);
        vm.warp(uint256(circle.lastLive()) + K.EXPIRY_DELAY + 1);
        _r(abi.encodeCall(MHAccumulationCircle.cancelExpired, ()), attacker, "cancelExpired (NAV-free)");
    }

    /// @dev Audit 2 R1-01: the Guardian's atomic force-deallocate + redeem.
    function test_R8_boundary_forceExit() public {
        _midLife();
        morpho.mockSetLiquidity(0);
        morpho.mockSetForceDeallocatePenalty(address(liqAdapter), 0.01e18);
        uint256 value = morpho.previewRedeem(circle.vaultShares());
        _r(
            abi.encodeCall(MHAccumulationCircle.forceExit, (address(liqAdapter), "", value / 2)),
            guardian,
            "forceExit"
        );
    }

    /// @dev Audit 2 R1-09 / R2-01: anyone pulls vault shares home while the registry does not consider the vault
    ///      safe (a live `vaultSafe` read with the bounded adapter walk, then the redeem).
    function test_R8_boundary_pullFromVault_whileUnsafe() public {
        _midLife();
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
        _r(
            abi.encodeCall(MHAccumulationCircle.pullFromVault, (circle.vaultShares() / 2)),
            attacker,
            "pullFromVault (vault unsafe)"
        );
    }

    /// @dev Closing review: in the curator's weak window (a checked timelock lowered, the vault still allowlisted)
    ///      `pullFromVault` delists the vault and redeems in one call. Too little gas reverts all of it (the
    ///      registry's bounded reads revert `InsufficientGas`), never a pull without the delisting or the reverse.
    function test_R8_boundary_pullFromVault_weakWindowDelists() public {
        _midLife();
        morpho.mockSetTimelock(IVaultV2.increaseAbsoluteCap.selector, 0);
        _r(
            abi.encodeCall(MHAccumulationCircle.pullFromVault, (circle.vaultShares() / 2)),
            attacker,
            "pullFromVault (weak window: delists)"
        );
    }

    /// @dev Closing review: in the same window `deployIdle` delists the vault and returns without depositing; the
    ///      delisting is the whole effect, so it must land completely or not at all.
    function test_R8_boundary_deployIdle_weakWindowDelists() public {
        _midLife();
        _openRound(3);
        _payAll(3, _everyone());
        morpho.mockSetTimelock(IVaultV2.increaseAbsoluteCap.selector, 0);
        _r(abi.encodeCall(MHAccumulationCircle.deployIdle, ()), attacker, "deployIdle (weak window: delists)");
    }
}

/// @notice R8 boundary-gas test on the other contracts with an external call in a state-changing path: the
///         factory (clone → setReporter → initialize, with both real implementations) and the Guardian canceller
///         (→ Timelock.cancel). The sweep runs with 8 members (a dense sweep at 50 members would exceed the
///         test gas limit; atomicity does not depend on the member count); creation at the 50-member bound is measured against the 5M cap separately.
contract MHFactoryCancellerBoundaryGasTest is AccumulationFixture, BoundaryGas {
    bytes32 internal probeId;
    CircleMode internal probeMode;
    bytes32 internal probeOp;

    function _deployRotatingImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        override
        returns (address)
    {
        return address(new MHRotatingCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    function _probe() internal view override returns (bytes32) {
        address predicted = factory.predictAddress(probeId, probeMode);
        return keccak256(
            abi.encode(
                factory.circleOf(probeId),
                factory.isCircle(predicted),
                reputation.isReporter(predicted),
                predicted.code.length,
                predicted.code.length == 0 ? bytes32(0) : IMHCircle(predicted).termsHash(),
                timelock.isOperation(probeOp)
            )
        );
    }

    function test_R8_boundary_createRotating() public {
        RotatingParams memory p = _rotParams(keccak256("boundary-rot"), 8);
        probeId = p.config.circleId;
        probeMode = CircleMode.Rotating;
        _boundary(
            address(factory),
            operator,
            abi.encodeCall(MHCircleFactory.createRotating, (p)),
            "createRotating n=8"
        );
    }

    function test_R8_boundary_createAccumulation() public {
        AccumulationParams memory p = _accParams(keccak256("boundary-acc"), 8);
        p.config.vault = address(morpho);
        probeId = p.config.circleId;
        probeMode = CircleMode.Accumulation;
        _boundary(
            address(factory),
            operator,
            abi.encodeCall(MHCircleFactory.createAccumulation, (p)),
            "createAccumulation n=8"
        );
    }

    /// @dev Spec §4.7 invariant 8 for creation: both creates at the 50-member bound stay under 5M gas.
    function test_gas_n50_create() public {
        RotatingParams memory rp = _rotParams(keccak256("gas-rot"), 50);
        AccumulationParams memory ap = _accParams(keccak256("gas-acc"), 50);
        ap.config.vault = address(morpho);
        vm.prank(operator);
        uint256 g = gasleft();
        factory.createRotating(rp);
        g -= gasleft();
        emit log_named_uint("createRotating, n=50", g);
        assertLt(g, BOUNDARY_GAS_CAP);
        vm.prank(operator);
        g = gasleft();
        factory.createAccumulation(ap);
        g -= gasleft();
        emit log_named_uint("createAccumulation, n=50", g);
        assertLt(g, BOUNDARY_GAS_CAP);
    }

    function test_R8_boundary_cancellerCancel() public {
        bytes memory data = abi.encodeCall(registry.setTreasury, (attacker));
        probeOp = _schedule(address(registry), 0, data, keccak256("boundary-op"));
        _boundary(
            address(canceller),
            guardian,
            abi.encodeCall(
                MHGuardianCanceller.cancel, (address(registry), 0, data, bytes32(0), keccak256("boundary-op"))
            ),
            "canceller.cancel"
        );
    }
}
