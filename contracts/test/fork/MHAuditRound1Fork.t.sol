// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { BaseForkFixture } from "./BaseForkFixture.sol";
import { MarketParams } from "./ForkInterfaces.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";

/// @dev Test-only Vault V2 curator/allocator surface (signatures verbatim from morpho-org/vault-v2 @ abaae813).
interface IVaultV2Curator {
    function curator() external view returns (address);
    function submit(bytes memory data) external;
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external;
    function allocate(address adapter, bytes memory data, uint256 assets) external;
    function deallocate(address adapter, bytes memory data, uint256 assets) external;
}

/// @dev Morpho Blue subset for the junk-market scenario (verbatim from morpho-blue `IMorpho.sol`).
interface IBlueR1 {
    function createMarket(MarketParams memory marketParams) external;
    function supplyCollateral(MarketParams memory, uint256, address, bytes memory) external;
    function borrow(MarketParams memory, uint256, uint256, address, address)
        external
        returns (uint256, uint256);
    function liquidate(MarketParams memory, address, uint256, uint256, bytes memory)
        external
        returns (uint256, uint256);
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
}

interface IAdapterR1 {
    function adaptiveCurveIrm() external view returns (address);
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}

contract JunkTokenR1 is ERC20 {
    constructor() ERC20("Junk", "JNK") { }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract JunkOracleR1 {
    uint256 public price = 1e36;

    function set(uint256 p) external {
        price = p;
    }
}

/// @notice Audit round 1 regressions on a Base fork with the real Gauntlet USDC Prime Vault V2 (scratchpad
///         `audit/r1-verify-R1-03-2/.../R103NavRevertFork.t.sol`, `audit/r1-verify-R1-04-1/.../VerifyR104.t.sol`).
///         Skipped without `BASE_RPC_URL`.
/// forge-config: default.isolate = true
contract MHAuditRound1ForkTest is BaseForkFixture {
    bytes internal constant REAL_ASSETS = abi.encodeWithSignature("realAssets()");

    function _breakAdapter() internal {
        vm.mockCallRevert(GAUNTLET_LIQUIDITY_ADAPTER, REAL_ASSETS, bytes("adapter realAssets reverts"));
        vm.warp(block.timestamp + 1 hours); // elapsed > 0 so the vault re-reads realAssets
    }

    function _openRound(MHAccumulationCircle c, uint256 r) internal {
        uint256 open = c.startTime() + (r - 1) * c.roundDuration();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < open) vm.warp(open);
    }

    /// @dev 4 members × $1,000 × 2 rounds, 10% fee; round 1 in Gauntlet, round 2 ($4,000) idle; finalized.
    function _matured(bytes32 id) internal returns (MHAccumulationCircle c, address[] memory m) {
        m = _members(4, string(abi.encodePacked(id)));
        c = _accumulation(id, m, 2, 1_000);
        _payAcc(c, m, 1);
        c.deployIdle();
        _openRound(c, 2);
        _payAcc(c, m, 2);
        vm.warp(c.roundDeadline(2) + c.grace() + c.cure() + 1);
        c.finalize();
        assertEq(uint8(c.status()), uint8(CircleStatus.Matured));
    }

    // ================================================================ R1-03

    /// @dev `test_v2_matured_adapterRevert_freezesIdleUsdc_noExitAtAll` on the real vault: a reverting adapter
    ///      used to freeze every unit, the never-deployed $4,000 included. The Guardian's Matured cancel plus
    ///      `claimInKind` now pays out without any NAV read.
    function test_R1_03_fork_maturedAdapterRevert_guardianCancelPaysInKind() public {
        (MHAccumulationCircle c, address[] memory m) = _matured("r103-matured");
        _breakAdapter();
        vm.expectRevert(bytes("adapter realAssets reverts"));
        c.settleMember(m[0]);
        vm.prank(guardian);
        c.guardianCancel();
        for (uint256 i; i < m.length; ++i) {
            vm.prank(m[i]);
            (uint256 assets, uint256 vShares) = c.claimInKind();
            assertGe(assets, 999e6, "its share of the idle $4,000");
            assertGt(vShares, 0, "and its Gauntlet shares");
            assertEq(IERC20(GAUNTLET).balanceOf(m[i]), vShares);
        }
        assertLe(c.idleAssets(), 1);
    }

    /// @dev `test_v2_active_outage_strikes_andYieldTransfer` on the real vault: `flagRound` no longer strikes
    ///      members while the vault cannot value shares; after the repair they pay and nobody is capped.
    function test_R1_03_fork_activeOutage_noStrikes() public {
        address[] memory m = _members(4, "r103-active");
        MHAccumulationCircle c = _accumulation("r103-active", m, 2, 1_000);
        _payAcc(c, m, 1);
        c.deployIdle();
        _openRound(c, 2);
        address[] memory a = new address[](1);
        a[0] = m[0];
        _payAcc(c, a, 2);
        _breakAdapter();
        vm.prank(guardian);
        c.extendDeadline(7 days);
        vm.warp(c.roundDeadline(2) + c.grace() + c.cure() + 1);
        vm.prank(m[0]);
        vm.expectRevert(bytes("adapter realAssets reverts"));
        c.flagRound(2);
        vm.clearMockedCalls(); // the curator repairs the adapter
        vm.prank(guardian);
        c.extendDeadline(7 days); // round 2 is payable again
        address[] memory rest = new address[](3);
        (rest[0], rest[1], rest[2]) = (m[1], m[2], m[3]);
        _payAcc(c, rest, 2);
        vm.warp(c.roundDeadline(2) + c.grace() + c.cure() + 1);
        c.flagRound(2);
        for (uint256 i; i < 4; ++i) {
            assertEq(reputation.strikesByReason(m[i], IMHReputation.Reason.MISSED), 0);
        }
        c.finalize();
        assertEq(c.forfeitSnap(), 0);
    }

    // ================================================================ R1-04

    /// @dev Gauntlet USDC Prime passes the extended checks (setUp allowlists it through the real `allowVault`);
    ///      the values it is checked against are pinned here.
    function test_R1_04_fork_gauntletPassesExtendedChecks() public view {
        IVaultV2 v = IVaultV2(GAUNTLET);
        assertTrue(registry.vaultSafe(GAUNTLET));
        assertEq(v.timelock(IVaultV2.removeAdapter.selector), 7 days);
        assertTrue(v.abdicated(IVaultV2.setAdapterRegistry.selector));
        assertTrue(v.adapterRegistry() != address(0));
        assertEq(v.timelock(IVaultV2.increaseAbsoluteCap.selector), 3 days);
        assertEq(v.timelock(IVaultV2.increaseRelativeCap.selector), 3 days);
        assertEq(v.timelock(IVaultV2.setPerformanceFee.selector), 3 days);
        assertEq(v.timelock(IVaultV2.setManagementFee.selector), 3 days);
        assertEq(v.adaptersLength(), 1);
        assertEq(
            IMorphoMarketV1AdapterV2(v.adapters(0)).timelock(IMorphoMarketV1AdapterV2.burnShares.selector),
            3 days
        );
    }

    /// @dev A curator shortening the cap timelock below 3 days (itself a 3-day wait) makes the vault unsafe: new
    ///      circles refuse it and anyone can delist it.
    function test_R1_04_fork_shortenedCapTimelock_unsafeAndDelistable() public {
        IVaultV2Curator v = IVaultV2Curator(GAUNTLET);
        bytes memory data =
            abi.encodeCall(IVaultV2Curator.decreaseTimelock, (IVaultV2.increaseAbsoluteCap.selector, 1 days));
        vm.prank(v.curator());
        v.submit(data);
        vm.warp(block.timestamp + 3 days);
        (bool ok,) = GAUNTLET.call(data);
        assertTrue(ok, "decreaseTimelock executed after 3 days");
        assertFalse(registry.vaultSafe(GAUNTLET));
        assertTrue(registry.revalidateVault(GAUNTLET));
        assertFalse(registry.isAllowedVault(GAUNTLET));
        (bool allowed, bytes memory ret) =
            _govTry(address(registry), abi.encodeCall(registry.allowVault, (GAUNTLET)));
        assertFalse(allowed);
        assertEq(
            keccak256(ret),
            keccak256(
                abi.encodeWithSelector(
                    IMHCircleRegistry.VaultCheckFailed.selector, IVaultV2.increaseAbsoluteCap.selector
                )
            )
        );
    }

    JunkTokenR1 internal junk;
    JunkOracleR1 internal oracle;
    MarketParams internal evil;

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

    /// @dev The curator (also an allocator) moves the liquidity market's free liquidity into the junk market and
    ///      a thief borrows it against worthless collateral; the bad debt is realised.
    function _rug(address cur) internal {
        (MarketParams memory liq, bytes32 liqId) = _liquidityMarket();
        (uint128 sa,, uint128 ba,,,) = IBlueR1(MORPHO_BLUE).market(liqId);
        uint256 free = uint256(sa) - uint256(ba);
        uint256 pos = IAdapterR1(GAUNTLET_LIQUIDITY_ADAPTER).expectedSupplyAssets(liqId);
        uint256 x = (free < pos ? free : pos) - 1;
        vm.startPrank(cur);
        IVaultV2Curator(GAUNTLET).deallocate(GAUNTLET_LIQUIDITY_ADAPTER, abi.encode(liq), x);
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

    /// @dev `test_v2_guardianExitInside3DaysProtectsCircle`: the cap path's real window is 3 days (now the
    ///      documented Guardian SLA); a Guardian `emergencyExit` inside it keeps the circle whole while the curator
    ///      routes the vault into a junk market and realises bad debt.
    function test_R1_04_fork_guardianExitInside3DaysProtectsCircle() public {
        address[] memory m = _members(3, "r104");
        MHAccumulationCircle circ = _accumulation("r104", m, 3, 1_000);
        _payAcc(circ, m, 1);
        circ.deployIdle();
        uint256 navBefore = circ.nav();
        address cur = IVaultV2Curator(GAUNTLET).curator();
        _setupEvil();
        bytes[4] memory caps = _caps();
        uint256 t0 = block.timestamp;
        vm.startPrank(cur);
        for (uint256 i; i < 4; ++i) {
            IVaultV2Curator(GAUNTLET).submit(caps[i]);
        }
        vm.stopPrank();

        vm.warp(t0 + 2 days); // the Guardian reacts to the Submit events inside the 3-day window
        vm.prank(guardian);
        circ.emergencyExit(type(uint256).max);
        assertEq(circ.vaultShares(), 0);

        vm.warp(t0 + 3 days);
        for (uint256 i; i < 4; ++i) {
            (bool ok,) = GAUNTLET.call(caps[i]);
            assertTrue(ok);
        }
        _rug(cur);
        assertGe(circ.nav() + 1, navBefore, "the circle is whole");
    }
}
