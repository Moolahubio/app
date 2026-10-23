// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseForkFixture } from "./BaseForkFixture.sol";
import { MarketParams } from "./ForkInterfaces.sol";
import { JunkTokenR1, JunkOracleR1, IVaultV2Curator, IBlueR1, IAdapterR1 } from "./MHAuditRound1Fork.t.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";

/// @dev Vault V2 allocator surface (verbatim from morpho-org/vault-v2 VaultV2.sol @ abaae813).
interface IVaultV2Alloc {
    function isAllocator(address account) external view returns (bool);
    function setLiquidityAdapterAndData(address newLiquidityAdapter, bytes memory newLiquidityData) external;
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256);
    function forceDeallocatePenalty(address adapter) external view returns (uint256);
    function setForceDeallocatePenalty(address adapter, uint256 newForceDeallocatePenalty) external;
    function timelock(bytes4 selector) external view returns (uint256);
}

/// @notice Audit 2 R1-01 on a Base fork (block 52,933,005) with the real Gauntlet USDC Prime Vault V2, its real
///         liquidity adapter and real USDC, from the verifier PoCs (`audit/r1-verify-R1-01-1/.../VerifyR101.t.sol`,
///         `audit/r1-verify-R1-01-2/.../VerifyR1_01_Alloc.t.sol`, `IntegrationsForkPoC.t.sol`). The curator (itself
///         an allocator on Gauntlet) submits 3-day cap increases for a junk-collateral market and, instantly, points the
///         vault's liquidity adapter at that market, which blocks every redemption; 3 days later it rugs. The
///         Guardian's `forceExit` gets the circle out on day 1, in one call. Skipped without `BASE_RPC_URL`.
/// forge-config: default.isolate = true
contract MHAudit2ForkTest is BaseForkFixture {
    JunkTokenR1 internal junk;
    JunkOracleR1 internal oracle;
    MarketParams internal evil;
    MarketParams internal liqOrig;
    bytes32 internal liqOrigId;

    function _setupEvil() internal {
        junk = new JunkTokenR1();
        oracle = new JunkOracleR1();
        (MarketParams memory liq,) = _liquidityMarket();
        evil = MarketParams(
            USDC,
            address(junk),
            address(oracle),
            IAdapterR1(GAUNTLET_LIQUIDITY_ADAPTER).adaptiveCurveIrm(),
            liq.lltv
        );
        IBlueR1(MORPHO_BLUE).createMarket(evil);
    }

    function _caps() internal view returns (bytes[4] memory c) {
        bytes memory colId = abi.encode("collateralToken", address(junk));
        bytes memory mktId = abi.encode("this/marketParams", GAUNTLET_LIQUIDITY_ADAPTER, evil);
        c[0] = abi.encodeCall(IVaultV2.increaseAbsoluteCap, (colId, 1e30));
        c[1] = abi.encodeCall(IVaultV2.increaseRelativeCap, (colId, 1e18));
        c[2] = abi.encodeCall(IVaultV2.increaseAbsoluteCap, (mktId, 1e30));
        c[3] = abi.encodeCall(IVaultV2.increaseRelativeCap, (mktId, 1e18));
    }

    function _execCaps() internal {
        bytes[4] memory caps = _caps();
        for (uint256 i; i < 4; ++i) {
            (bool ok,) = GAUNTLET.call(caps[i]);
            assertTrue(ok, "caps executable by anyone after 3 days");
        }
    }

    /// @dev The allocator moves the liquidity market's free liquidity into the junk market, a thief borrows it
    ///      against worthless collateral, the bad debt is realised.
    function _rug(address cur) internal returns (uint256 x) {
        (uint128 sa,, uint128 ba,,,) = IBlueR1(MORPHO_BLUE).market(liqOrigId);
        uint256 free = uint256(sa) - uint256(ba);
        uint256 pos = IAdapterR1(GAUNTLET_LIQUIDITY_ADAPTER).expectedSupplyAssets(liqOrigId);
        x = (free < pos ? free : pos) - 1;
        vm.startPrank(cur);
        IVaultV2Curator(GAUNTLET).deallocate(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liqOrig), x);
        IVaultV2Curator(GAUNTLET).allocate(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(evil), x);
        vm.stopPrank();
        address thief = makeAddr("thief");
        junk.mint(thief, 1e30);
        vm.startPrank(thief);
        junk.approve(MORPHO_BLUE, type(uint256).max);
        IBlueR1(MORPHO_BLUE).supplyCollateral(evil, 1e30, thief, "");
        IBlueR1(MORPHO_BLUE).borrow(evil, x, 0, thief, thief);
        vm.stopPrank();
        oracle.set(0);
        IBlueR1(MORPHO_BLUE).liquidate(evil, thief, 1e30, 0, "");
    }

    /// @dev 3 × $1,000 circle in Gauntlet; the curator submits the junk caps (3-day timelock) and, instantly, sets
    ///      the liquidity adapter (and data) to `newLiqAdapter` (the junk market, or address(0)).
    function _attack(address newLiqAdapter)
        internal
        returns (MHAccumulationCircle c, uint256 navBefore, address cur, uint256 t0)
    {
        address[] memory m = _members(3, "a2r101");
        c = _accumulation("a2r101", m, 3, 0);
        _payAcc(c, m, 1);
        c.deployIdle();
        navBefore = c.nav();
        cur = IVaultV2Curator(GAUNTLET).curator();
        assertTrue(IVaultV2Alloc(GAUNTLET).isAllocator(cur), "Gauntlet's curator is an allocator");
        assertEq(IERC20(USDC).balanceOf(GAUNTLET), 0, "no idle USDC in the vault");
        (liqOrig, liqOrigId) = _liquidityMarket();
        _setupEvil();
        bytes[4] memory caps = _caps();
        t0 = block.timestamp;
        vm.startPrank(cur);
        for (uint256 i; i < 4; ++i) {
            IVaultV2Curator(GAUNTLET).submit(caps[i]);
        }
        IVaultV2Alloc(GAUNTLET)
            .setLiquidityAdapterAndData(
                newLiqAdapter, newLiqAdapter == address(0) ? bytes("") : abi.encode(evil)
            );
        vm.stopPrank();
    }

    function _forceExitAll(MHAccumulationCircle c) internal {
        uint256 value = IVaultV2(GAUNTLET).previewRedeem(c.vaultShares());
        vm.prank(guardian);
        c.forceExit(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liqOrig), value);
    }

    /// @dev PoCs `test_poc_allocatorBlocksGuardianExit_rugLandsOnCircle`, `test_finding_blockByJunkLiquidityData_lossLands`:
    ///      the circle used to lose 93.4% with the Guardian acting on day 1. Every other exit still reverts, but
    ///      `forceExit` gets every share out and the rug misses the circle.
    function test_A2R1_01_fork_allocatorBlocksExits_forceExitSavesTheCircle() public {
        (MHAccumulationCircle c, uint256 navBefore, address cur, uint256 t0) =
            _attack(GAUNTLET_LIQUIDITY_ADAPTER);
        uint256 held = c.vaultShares();
        vm.warp(t0 + 1 days);
        vm.prank(guardian);
        vm.expectRevert();
        c.emergencyExit(type(uint256).max);
        vm.prank(guardian);
        vm.expectRevert();
        c.emergencyExit(held / 100);

        _forceExitAll(c);
        assertEq(c.vaultShares(), 0, "every share out");
        assertTrue(c.yieldOff());
        assertGe(
            c.idleAssets() + 2,
            navBefore * (1e18 - 0.00001e18) / 1e18,
            "less at most Gauntlet's 0.001% penalty"
        );

        vm.warp(t0 + 3 days);
        _execCaps();
        uint256 stolen = _rug(cur);
        assertGt(stolen, 1_000_000e6, "the rug is real");
        assertEq(c.nav(), c.idleAssets(), "the circle holds only idle USDC");
        assertGe(c.nav() + navBefore / 50_000, navBefore, "circle whole");
    }

    /// @dev PoC `test_variant_zeroLiquidityAdapter_blocks`: the liquidity adapter set to address(0) blocks every
    ///      redemption too; `forceExit` names the adapter itself and still exits.
    function test_A2R1_01_fork_zeroLiquidityAdapter_forceExitStillWorks() public {
        (MHAccumulationCircle c, uint256 navBefore,, uint256 t0) = _attack(address(0));
        uint256 chunk = c.vaultShares() / 1000;
        vm.warp(t0 + 1 days);
        vm.prank(guardian);
        vm.expectRevert();
        c.emergencyExit(chunk);
        _forceExitAll(c);
        assertEq(c.vaultShares(), 0);
        assertGe(c.nav() + navBefore / 50_000, navBefore);
    }

    /// @dev PoC `test_poc_runbookSequenceDefeatedByReallocation` / `test_runbook_separateTx_defeated`: a keeper's
    ///      force-deallocation in its own transaction is undone by the allocator's next one. `forceExit` deallocates
    ///      and redeems in one call, so there is no "next transaction" to interleave.
    function test_A2R1_01_fork_reallocationBetweenTxs_forceExitIsAtomic() public {
        address keeper = makeAddr("keeper");
        deal(USDC, address(this), 100e6);
        IERC20(USDC).approve(GAUNTLET, 100e6);
        IVaultV2(GAUNTLET).deposit(100e6, keeper); // funded before the attack
        (MHAccumulationCircle c, uint256 navBefore, address cur, uint256 t0) =
            _attack(GAUNTLET_LIQUIDITY_ADAPTER);
        vm.warp(t0 + 1 days);
        uint256 need = IVaultV2(GAUNTLET).previewRedeem(c.vaultShares()) + 10;
        vm.prank(keeper);
        IVaultV2Alloc(GAUNTLET).forceDeallocate(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liqOrig), need, keeper);
        uint256 idle = IERC20(USDC).balanceOf(GAUNTLET);
        vm.prank(cur);
        IVaultV2Curator(GAUNTLET).allocate(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liqOrig), idle);
        vm.prank(guardian);
        vm.expectRevert();
        c.emergencyExit(type(uint256).max);

        _forceExitAll(c);
        assertEq(c.vaultShares(), 0);
        vm.warp(t0 + 3 days);
        _execCaps();
        _rug(cur);
        assertGe(c.nav() + navBefore / 50_000, navBefore, "circle whole");
    }

    /// @dev PoC `test_escapeCost_boundedByMaxPenalty` / `test_v1_penaltyRaisedToMax_atomicRescueStillWorks`: the
    ///      curator also raises the force-deallocation penalty to Vault V2's 2% cap (1-day timelock on Gauntlet,
    ///      inside the 3-day window). `forceExit` still exits; the circle pays at most 2%, and nothing more is at risk.
    function test_A2R1_01_fork_penaltyRaisedTo2Percent_circleLosesAtMost2Percent() public {
        (MHAccumulationCircle c, uint256 navBefore, address cur, uint256 t0) =
            _attack(GAUNTLET_LIQUIDITY_ADAPTER);
        bytes memory max_ =
            abi.encodeCall(IVaultV2Alloc.setForceDeallocatePenalty, (GAUNTLET_LIQUIDITY_ADAPTER, 0.02e18));
        uint256 penaltyTimelock =
            IVaultV2Alloc(GAUNTLET).timelock(IVaultV2Alloc.setForceDeallocatePenalty.selector);
        assertLt(penaltyTimelock, 3 days, "the penalty raise lands inside the cap window");
        vm.prank(cur);
        IVaultV2Curator(GAUNTLET).submit(max_);
        vm.warp(t0 + penaltyTimelock);
        (bool ok,) = GAUNTLET.call(max_);
        assertTrue(ok);
        vm.warp(block.timestamp + 1);
        _forceExitAll(c);
        assertEq(c.vaultShares(), 0);
        assertGe(c.nav() + navBefore * 2 / 100 + 2, navBefore, "at most the 2% penalty");
        vm.warp(t0 + 3 days);
        _execCaps();
        _rug(cur);
        assertGe(c.nav() + navBefore * 2 / 100 + 2, navBefore, "and nothing more after the rug");
    }

    /// @dev Control (`test_control_noBlock_guardianExitWorks`): without the allocator block, `forceExit` and
    ///      `emergencyExit` both work; `forceExit` with the vault's actual liquidity market costs Gauntlet's 0.001%.
    function test_A2R1_01_fork_control_noBlock() public {
        address[] memory m = _members(3, "a2r101-ctl");
        MHAccumulationCircle c = _accumulation("a2r101-ctl", m, 3, 0);
        _payAcc(c, m, 1);
        c.deployIdle();
        (liqOrig, liqOrigId) = _liquidityMarket();
        uint256 navBefore = c.nav();
        uint256 penalty = IVaultV2Alloc(GAUNTLET).forceDeallocatePenalty(GAUNTLET_LIQUIDITY_ADAPTER);
        emit log_named_uint("Gauntlet forceDeallocatePenalty (WAD)", penalty);
        uint256 value = IVaultV2(GAUNTLET).previewRedeem(c.vaultShares());
        vm.expectEmit(true, false, false, false, address(c));
        emit IMHAccumulationCircle.ForceExited(GAUNTLET_LIQUIDITY_ADAPTER, 0, 0, 0, 0);
        vm.prank(guardian);
        c.forceExit(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liqOrig), value / 2);
        vm.prank(guardian);
        c.emergencyExit(type(uint256).max);
        assertEq(c.vaultShares(), 0);
        assertGe(c.nav() + navBefore / 50_000, navBefore);
    }

    /// @dev The probe gas budget: a real Gauntlet `previewRedeem` (every adapter's `realAssets`) costs a small fraction
    ///      of `NAV_PROBE_GAS`, so the cancelExpired probe never mistakes the real vault for a broken one.
    function test_A2R1_05_fork_previewRedeemFarBelowProbeGas() public {
        address[] memory m = _members(3, "a2r105-probe");
        MHAccumulationCircle c = _accumulation("a2r105-probe", m, 3, 0);
        _payAcc(c, m, 1);
        c.deployIdle();
        uint256 held = c.vaultShares();
        vm.warp(block.timestamp + 1 hours); // the vault re-reads every adapter
        uint256 g = gasleft();
        IVaultV2(GAUNTLET).previewRedeem(held);
        g -= gasleft();
        emit log_named_uint("Gauntlet previewRedeem gas (cold)", g);
        assertLt(g * 10, K.NAV_PROBE_GAS, "an order of magnitude of headroom");
        vm.warp(uint256(c.lastLive()) + K.EXPIRY_DELAY + 1);
        vm.expectRevert(IMHAccumulationCircle.NavReadable.selector);
        c.cancelExpired();
    }
}
