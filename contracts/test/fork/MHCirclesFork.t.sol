// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseForkFixture } from "./BaseForkFixture.sol";
import { IVaultV2Fork, IMorphoBlue, IOracle, MarketParams } from "./ForkInterfaces.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { CircleStatus } from "../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.7 Base fork tests (pinned block, real USDC, Gauntlet USDC Prime Vault V2):
///         - Appendix A addresses have code; the real `allowVault` checks pass for Gauntlet and fail for Steakhouse
///           Prime (allocator timelock 0) and for Gauntlet once its curator shortens the allocator timelock;
///         - `previewRedeem` drift over time, preview == redeem within a block, `maxRedeem`/`maxWithdraw` == 0;
///         - illiquidity (the liquidity market borrowed out) → cash settlement and a one-shot exit revert →
///           `emergencyExit(0)` → in-kind settlement → chunked `pullFromVault` as liquidity returns → cash;
///         - a curator performance-fee change through the vault's timelock;
///         - USDC blacklist and pause through Circle's real roles (pranked);
///         - a rotating circle on real USDC with a blacklisted recipient;
///         - gas snapshots (`snapshots/circles-fork.json`).
///         Skipped unless `BASE_RPC_URL` is set. Runs isolated (every top-level call is its own transaction):
///         Vault V2 accrues interest once per transaction (`firstTotalAssets` is transient), so without isolation a
///         whole test would see one frozen NAV.
/// forge-config: default.isolate = true
contract MHCirclesForkTest is BaseForkFixture {
    string internal constant GAS = "circles-fork";

    // ================================================================ Appendix A and allowVault

    function test_fork_appendixA_codeAndGauntletChecks() public view {
        address[10] memory a = [
            USDC,
            GAUNTLET,
            GAUNTLET_LIQUIDITY_ADAPTER,
            STEAKHOUSE,
            SAFE_L2,
            SAFE_PROXY_FACTORY,
            MULTISEND_CALL_ONLY,
            FALLBACK_HANDLER,
            CREATEX,
            MORPHO_BLUE
        ];
        for (uint256 i; i < a.length; ++i) {
            assertGt(a[i].code.length, 0, "Appendix A address without code");
        }
        // USDC: both views the circles rely on respond.
        assertFalse(usdc.isBlacklisted(address(this)));
        assertFalse(usdc.paused());
        // Gauntlet USDC Prime, as `allowVault` saw it in setUp.
        assertEq(vault.asset(), USDC);
        assertEq(vault.receiveAssetsGate(), address(0));
        assertEq(vault.receiveSharesGate(), address(0));
        assertEq(vault.sendSharesGate(), address(0));
        assertTrue(vault.abdicated(IVaultV2.setReceiveAssetsGate.selector));
        assertTrue(vault.abdicated(IVaultV2.setReceiveSharesGate.selector));
        assertTrue(vault.abdicated(IVaultV2.setSendSharesGate.selector));
        assertGe(vault.timelock(IVaultV2.setIsAllocator.selector), 7 days);
        assertGe(vault.timelock(IVaultV2.addAdapter.selector), 7 days);
        assertEq(vault.liquidityAdapter(), GAUNTLET_LIQUIDITY_ADAPTER);
        // Vault V2 never reports exit capacity: circles must not (and do not) call max*.
        assertEq(vault.maxRedeem(address(this)), 0);
        assertEq(vault.maxWithdraw(address(this)), 0);
        // Monitor input (spec §4.3): fee and penalty timelocks are shorter than 7 days on this vault.
        assertEq(vault.timelock(IVaultV2.setPerformanceFee.selector), 3 days, "performance-fee timelock");
        assertEq(vault.performanceFee(), 0);
        assertEq(
            vault.forceDeallocatePenalty(GAUNTLET_LIQUIDITY_ADAPTER), 1e13, "0.001% force-deallocate penalty"
        );
    }

    /// @dev Steakhouse Prime USDC has `setIsAllocator` timelocked for 0: the real check refuses it.
    function test_fork_allowVault_rejectsSteakhouse() public {
        (bool ok, bytes memory ret) =
            _govTry(address(registry), abi.encodeCall(registry.allowVault, (STEAKHOUSE)));
        assertFalse(ok);
        assertEq(
            ret,
            abi.encodeWithSelector(
                IMHCircleRegistry.VaultCheckFailed.selector, IVaultV2.setIsAllocator.selector
            )
        );
        assertFalse(registry.isAllowedVault(STEAKHOUSE));
    }

    /// @dev If Gauntlet's curator shortens the allocator timelock (itself a 7-day timelocked change), a new
    ///      `allowVault` fails. A live circle keeps its vault: the Guardian's `disallowVault` and `emergencyExit`
    ///      are the response, which is why monitors watch these timelocks.
    function test_fork_allowVault_rejectsShortenedAllocatorTimelock() public {
        bytes memory data =
            abi.encodeCall(IVaultV2Fork.decreaseTimelock, (IVaultV2.setIsAllocator.selector, 1 days));
        vm.prank(vault.curator());
        vault.submit(data);
        vm.warp(block.timestamp + 7 days);
        (bool ok,) = address(vault).call(data);
        assertTrue(ok, "decreaseTimelock executes after 7 days");
        assertEq(vault.timelock(IVaultV2.setIsAllocator.selector), 1 days);
        (bool allowed, bytes memory ret) =
            _govTry(address(registry), abi.encodeCall(registry.allowVault, (GAUNTLET)));
        assertFalse(allowed);
        assertEq(
            ret,
            abi.encodeWithSelector(
                IMHCircleRegistry.VaultCheckFailed.selector, IVaultV2.setIsAllocator.selector
            )
        );
    }

    // ================================================================ Accumulation on Gauntlet

    /// @dev NAV drifts up as the vault accrues interest; `previewRedeem` equals the actual redeem within a block;
    ///      `maxRedeem`/`maxWithdraw` stay 0 while the circle holds shares; a full lifecycle pays every member its
    ///      principal plus earnings net of the fee and leaves the circle empty.
    function test_fork_previewRedeemDrift_andFullLifecycle() public {
        address[] memory m = _members(3, "drift");
        MHAccumulationCircle c = _accumulation(keccak256("fork-drift"), m, 2, 1_000);
        _payAcc(c, m, 1);
        vm.snapshotGasLastCall(GAS, "accumulation.contribute");
        c.deployIdle();
        vm.snapshotGasLastCall(GAS, "accumulation.deployIdle (Gauntlet deposit)");
        uint256 shares = c.vaultShares();
        assertGt(shares, 0);
        assertEq(vault.maxRedeem(address(c)), 0);
        assertEq(vault.maxWithdraw(address(c)), 0);

        uint256 nav0 = c.nav();
        assertApproxEqAbs(nav0, 3_000e6, 2, "deposit rounding only");
        vm.warp(block.timestamp + 15 days);
        uint256 nav1 = c.nav();
        assertGt(nav1, nav0, "previewRedeem drifts up with interest");
        emit log_named_uint("NAV drift over 15 days (micro-USDC)", nav1 - nav0);

        // Within one block the preview is exact.
        uint256 snap = vm.snapshotState();
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(address(c));
        uint256 redeemed = vault.redeem(shares, address(c), address(c));
        assertEq(redeemed, preview, "previewRedeem == redeem in the same block");
        vm.revertToState(snap);

        _openRound(c, 2);
        _payAcc(c, m, 2);
        c.deployIdle();
        vm.warp(c.roundDeadline(2) + c.grace() + c.cure() + 1);
        c.finalize();
        vm.snapshotGasLastCall(GAS, "accumulation.finalize");
        for (uint256 i; i < m.length; ++i) {
            c.settleMember(m[i]);
            if (i == 0) vm.snapshotGasLastCall(GAS, "accumulation.settleMember (Gauntlet withdraw)");
            uint256 got = usdc.balanceOf(m[i]);
            assertGt(got, 2_000e6, "principal plus earnings");
        }
        uint256 fees = usdc.balanceOf(treasury);
        assertGt(fees, 0, "10% of positive earnings");
        assertEq(uint8(c.status()), uint8(CircleStatus.Closed));
        if (c.idleAssets() != 0 || c.vaultShares() != 0) c.sweepResidual();
        assertEq(usdc.balanceOf(address(c)), 0);
        assertEq(vault.balanceOf(address(c)), 0);
        // Fee only on earnings: at most 10% of what members gained.
        uint256 gained;
        for (uint256 i; i < m.length; ++i) {
            gained += usdc.balanceOf(m[i]) - 2_000e6;
        }
        assertLe(fees, (gained + fees) / 10 + 3);
    }

    /// @dev R3 on the real vault: the liquidity market is borrowed out, so cash settlement and a one-shot exit
    ///      revert; the Guardian switches yield off with a zero chunk; a member settles in kind; as liquidity
    ///      returns, anyone pulls a bounded chunk and the next member settles in cash. `max*` is never called.
    function test_fork_illiquidity_chunkedExit_inKindSettlement() public {
        address[] memory m = _members(3, "illiquid");
        MHAccumulationCircle c = _accumulation(keccak256("fork-illiquid"), m, 1, 1_000);
        _payAcc(c, m, 1);
        c.deployIdle();
        vm.warp(c.roundDeadline(1) + c.grace() + c.cure() + 1);
        c.finalize();

        (MarketParams memory mp, address borrower, uint256 borrowed) = _drainLiquidityMarket();
        assertEq(IERC20(USDC).balanceOf(GAUNTLET), 0, "no idle USDC in the vault");

        vm.expectRevert(); // the adapter cannot withdraw from an empty market
        c.settleMember(m[0]);
        vm.prank(guardian);
        vm.expectRevert();
        c.emergencyExit(type(uint256).max); // the legacy one-shot exit (R3)
        vm.prank(guardian);
        c.emergencyExit(0);
        vm.snapshotGasLastCall(GAS, "accumulation.emergencyExit(0)");
        assertTrue(c.yieldOff());

        // A member takes its settlement in kind (USDC part + vault shares), fee pro rata to the treasury.
        uint256 navBefore = c.nav();
        vm.prank(m[0]);
        c.settleMemberInKind(m[0]);
        vm.snapshotGasLastCall(GAS, "accumulation.settleMemberInKind");
        uint256 inKindShares = vault.balanceOf(m[0]);
        assertGt(inKindShares, 0);
        assertGt(vault.balanceOf(treasury), 0, "fee shares");
        assertLt(c.nav(), navBefore);

        // Liquidity returns in part: anyone pulls a bounded chunk into idle USDC.
        vm.startPrank(borrower);
        IERC20(USDC).approve(MORPHO_BLUE, borrowed);
        IMorphoBlue(MORPHO_BLUE).repay(mp, 2_500e6, 0, borrower, "");
        vm.stopPrank();
        uint256 chunk = vault.previewWithdraw(2_000e6);
        vm.expectRevert(IMHCircle.NotGuardian.selector); // only the Guardian chooses emergency chunks
        c.emergencyExit(chunk);
        vm.prank(attacker);
        c.pullFromVault(chunk);
        vm.snapshotGasLastCall(GAS, "accumulation.pullFromVault");
        assertApproxEqAbs(c.idleAssets(), 2_000e6, 2);

        // The next member settles in cash from idle; the last one in cash too once liquidity is back.
        c.settleMember(m[1]);
        assertGt(usdc.balanceOf(m[1]), 1_000e6);
        vm.startPrank(borrower);
        IMorphoBlue(MORPHO_BLUE).repay(mp, IERC20(USDC).balanceOf(borrower), 0, borrower, "");
        vm.stopPrank();
        c.settleMember(m[2]);
        assertEq(uint8(c.status()), uint8(CircleStatus.Closed));

        // The in-kind member redeems its vault shares directly once the market is liquid again.
        vm.prank(m[0]);
        vault.redeem(inKindShares, m[0], m[0]);
        assertGt(
            usdc.balanceOf(m[0]), 999e6, "in-kind settlement is worth its cash value (less vault rounding)"
        );
    }

    /// @dev A curator raises the performance fee through the vault's 3-day timelock: the circle's NAV grows more
    ///      slowly, members still get principal plus (smaller) earnings, and the circle's own fee is still taken
    ///      only on what members actually earned.
    function test_fork_curatorPerformanceFeeChange() public {
        address[] memory m = _members(2, "curatorFee");
        MHAccumulationCircle c = _accumulation(keccak256("fork-curator-fee"), m, 1, 1_000);
        _payAcc(c, m, 1);
        c.deployIdle();

        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 30 days);
        uint256 navNoFee = c.nav();
        vm.revertToState(snap);

        bytes memory data = abi.encodeCall(IVaultV2.setPerformanceFee, (0.25e18));
        vm.prank(vault.curator());
        vault.submit(data);
        vm.warp(block.timestamp + 3 days);
        (bool ok,) = address(vault).call(data);
        assertTrue(ok, "anyone executes after the timelock");
        assertEq(vault.performanceFee(), 0.25e18);
        vm.warp(block.timestamp + 27 days);
        uint256 navFee = c.nav();
        assertLt(navFee, navNoFee, "the curator fee slows NAV growth");
        assertGt(navFee, 2_000e6 - 2, "principal is intact");
        emit log_named_uint("NAV without curator fee", navNoFee);
        emit log_named_uint("NAV with 25% curator fee", navFee);

        vm.warp(c.roundDeadline(1) + c.grace() + c.cure() + 1);
        c.finalize();
        c.settleMember(m[0]);
        c.settleMember(m[1]);
        assertGe(usdc.balanceOf(m[0]), 1_000e6 - 1);
        assertGe(usdc.balanceOf(m[1]), 1_000e6 - 1);
    }

    /// @dev USDC pause and blacklist through Circle's real roles: timer functions revert `UsdcPaused`; an in-kind
    ///      settlement still works while paused (its USDC part is queued); a blacklisted member's payout is queued
    ///      and claimable once it is lifted.
    function test_fork_usdcBlacklistAndPause() public {
        address[] memory m = _members(3, "fiat");
        MHAccumulationCircle c = _accumulation(keccak256("fork-fiat"), m, 1, 1_000);
        _payAcc(c, m, 1);
        c.deployIdle();
        vm.warp(c.roundDeadline(1) + c.grace() + c.cure() + 1);

        vm.prank(_fiat().pauser());
        _fiat().pause();
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        c.finalize();
        vm.prank(_fiat().pauser());
        _fiat().unpause();
        c.finalize();

        // Paused: a cash settlement needs a vault withdraw (a USDC transfer) and reverts; in kind works.
        vm.prank(_fiat().pauser());
        _fiat().pause();
        vm.expectRevert();
        c.settleMember(m[0]);
        vm.prank(m[0]);
        c.settleMemberInKind(m[0]);
        assertGt(vault.balanceOf(m[0]), 0);
        vm.prank(_fiat().pauser());
        _fiat().unpause();

        // Blacklisted: the payout is queued, the member claims it once the blacklist is lifted.
        vm.prank(_fiat().blacklister());
        _fiat().blacklist(m[1]);
        vm.expectEmit(true, false, false, false, address(c));
        emit IMHCircle.PayoutQueued(m[1], 0);
        c.settleMember(m[1]);
        uint256 owed = c.owed(m[1]);
        assertGt(owed, 1_000e6);
        vm.prank(m[1]);
        vm.expectRevert();
        c.claimOwed();
        vm.prank(_fiat().blacklister());
        _fiat().unBlacklist(m[1]);
        vm.prank(m[1]);
        c.claimOwed();
        vm.snapshotGasLastCall(GAS, "claimOwed");
        assertEq(usdc.balanceOf(m[1]), owed);

        c.settleMember(m[2]);
        if (c.idleAssets() != 0 || c.vaultShares() != 0) c.sweepResidual();
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    // ================================================================ Rotating on real USDC

    /// @dev A rotating circle on real USDC: round 1's recipient is blacklisted, so its payout is queued; the circle
    ///      completes, every member nets exactly −fee, and the queued payout is claimed after the blacklist lifts.
    function test_fork_rotating_realUsdc_blacklistedRecipient() public {
        address[] memory m = _members(3, "rot");
        MHRotatingCircle c = _rotating(keccak256("fork-rotating"), m, 200);
        for (uint256 r = 1; r <= 3; ++r) {
            uint256 open = c.startTime() + (r - 1) * c.roundDuration();
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < open) vm.warp(open);
            for (uint256 i; i < 3; ++i) {
                uint256 due = c.amountDue(m[i], r);
                if (due == 0) continue;
                _fund(m[i], address(c), due);
                vm.prank(m[i]);
                c.contribute(r, due);
                if (r == 1 && i == 0) vm.snapshotGasLastCall(GAS, "rotating.contribute");
            }
            if (r == 1) {
                vm.prank(_fiat().blacklister());
                _fiat().blacklist(m[0]);
            }
            c.settleRound();
            if (r == 1) vm.snapshotGasLastCall(GAS, "rotating.settleRound (payout queued)");
            if (r == 2) vm.snapshotGasLastCall(GAS, "rotating.settleRound");
        }
        assertEq(uint8(c.status()), uint8(CircleStatus.Completed));
        vm.prank(_fiat().blacklister());
        _fiat().unBlacklist(m[0]);
        vm.prank(m[0]);
        c.claimOwed();
        for (uint256 i; i < 3; ++i) {
            uint256 sec = c.memberState(m[i]).sec;
            if (sec != 0) {
                vm.prank(m[i]);
                c.withdrawSecurity(sec);
            }
        }
        c.flushFees();
        // Every unit dealt to a member was pulled, so its balance is what it received: cashIn − balance is
        // exactly the 2% fee on the $300 pot.
        for (uint256 i; i < 3; ++i) {
            assertEq(_paidIn(c, m[i]) - usdc.balanceOf(m[i]), 6e6, "every member nets -fee");
        }
        assertEq(usdc.balanceOf(treasury), 18e6);
        assertEq(usdc.balanceOf(address(c)), 0);
    }

    // ================================================================ Helpers

    function _paidIn(MHRotatingCircle c, address who) internal view returns (uint256) {
        return c.memberState(who).cashIn;
    }

    function _openRound(MHAccumulationCircle c, uint256 r) internal {
        uint256 open = c.startTime() + (r - 1) * c.roundDuration();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < open) vm.warp(open);
    }

    /// @dev Borrows every unit of liquidity out of Gauntlet's liquidity market (cbBTC collateral via `deal`), so
    ///      the vault cannot pay any exit (it holds no idle USDC).
    function _drainLiquidityMarket()
        internal
        returns (MarketParams memory mp, address borrower, uint256 borrowed)
    {
        bytes32 id;
        (mp, id) = _liquidityMarket();
        IMorphoBlue blue = IMorphoBlue(MORPHO_BLUE);
        blue.accrueInterest(mp);
        (uint128 supplyAssets,, uint128 borrowAssets,,,) = blue.market(id);
        borrowed = uint256(supplyAssets) - uint256(borrowAssets);
        uint256 price = IOracle(mp.oracle).price();
        uint256 collateral = borrowed * 1e36 / price * 1e18 / mp.lltv * 12 / 10 + 1;
        borrower = makeAddr("liquidityBorrower");
        deal(mp.collateralToken, borrower, collateral);
        vm.startPrank(borrower);
        IERC20(mp.collateralToken).approve(MORPHO_BLUE, collateral);
        blue.supplyCollateral(mp, collateral, borrower, "");
        blue.borrow(mp, borrowed, 0, borrower, borrower);
        vm.stopPrank();
        (supplyAssets,, borrowAssets,,,) = blue.market(id);
        assertEq(supplyAssets, borrowAssets, "market fully utilised");
    }
}
