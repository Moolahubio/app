// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMorphoMarketV1AdapterV2, IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { VaultV2 } from "../vendor/vaultv2/VaultV2.sol";

/// @notice A Morpho-shaped market adapter for the REAL Vault V2: no allocations (`realAssets` 0) plus the adapter
///         curator-timelock views the registry reads (`burnShares` timelocked 3 days).
contract ClosingReviewZeroAdapter {
    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;

    constructor() {
        timelock[bytes4(keccak256("burnShares(bytes32)"))] = 3 days;
    }

    function realAssets() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Morpho's adapter registry answer, reduced to an allowlist.
contract ClosingReviewAdapterRegistry {
    mapping(address adapter => bool) public isInRegistry;

    function add(address a) external {
        isInRegistry[a] = true;
    }
}

/// @notice Closing review of the internal audit closeout, accumulation circle. Finding 4 (low, fixed): a live-check
///         failure caused by the vault's curator was not sticky; the curator could restore the checked timelock
///         itself (`increaseTimelock` is instant) and anyone's `deployIdle` re-deposited the circle's money with no
///         Gov operation and no pending-submission scan, while data submitted in the weak window stayed executable.
///         `deployIdle` and `pullFromVault` now delist a vault that fails the live check (`revalidateVault`), so only
///         Gov's reviewed `allowVault` resumes deposits. Finding 5 (informational, acknowledged): `exitEarly` has no
///         in-kind path and waits for vault liquidity (pinned). Both were first reproduced with the reviewer's PoCs.
contract MHClosingReviewAccumulationTest is AccumulationFixture {
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal vaultCurator = makeAddr("vaultCurator");
    address internal keeper = makeAddr("keeper");

    function _cur(VaultV2 v, bytes memory data, bool execute) internal {
        vm.prank(vaultCurator);
        v.submit(data);
        if (execute) {
            (bool ok, bytes memory ret) = address(v).call(data);
            require(ok, string(ret));
        }
    }

    /// @dev A real Vault V2 hardened into exactly the shape `allowVault` checks, allowlisted through the Timelock.
    function _hardenedVault() internal returns (VaultV2 v) {
        v = new VaultV2(vaultOwner, address(usdc));
        vm.prank(vaultOwner);
        v.setCurator(vaultCurator);
        ClosingReviewAdapterRegistry reg = new ClosingReviewAdapterRegistry();
        ClosingReviewZeroAdapter adapter = new ClosingReviewZeroAdapter();
        reg.add(address(adapter));
        _cur(v, abi.encodeCall(v.setAdapterRegistry, (address(reg))), true);
        _cur(v, abi.encodeCall(v.addAdapter, (address(adapter))), true);
        _cur(v, abi.encodeCall(v.abdicate, (IVaultV2.setReceiveAssetsGate.selector)), true);
        _cur(v, abi.encodeCall(v.abdicate, (IVaultV2.setReceiveSharesGate.selector)), true);
        _cur(v, abi.encodeCall(v.abdicate, (IVaultV2.setSendSharesGate.selector)), true);
        _cur(v, abi.encodeCall(v.abdicate, (IVaultV2.setAdapterRegistry.selector)), true);
        bytes4[3] memory slow =
            [IVaultV2.setIsAllocator.selector, IVaultV2.addAdapter.selector, IVaultV2.removeAdapter.selector];
        for (uint256 i; i < 3; ++i) {
            _cur(v, abi.encodeCall(v.increaseTimelock, (slow[i], 7 days)), true);
        }
        bytes4[4] memory fast = [
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector
        ];
        for (uint256 i; i < 4; ++i) {
            _cur(v, abi.encodeCall(v.increaseTimelock, (fast[i], 3 days)), true);
        }
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(v))));
        assertTrue(registry.vaultSafe(address(v)), "allowlisted and safe");
    }

    /// @dev A live circle on `v` with round 1 deposited.
    function _liveCircle(VaultV2 v) internal {
        _start(3, 12, 0, address(v), false);
        _payAll(1, _everyone());
        circle.deployIdle();
        assertGt(circle.vaultShares(), 0, "deployed");
    }

    /// @dev The curator's 3-day `decreaseTimelock(increaseAbsoluteCap, 0)` matures and is executed (by anyone).
    function _weaken(VaultV2 v) internal {
        bytes memory weaken = abi.encodeCall(v.decreaseTimelock, (IVaultV2.increaseAbsoluteCap.selector, 0));
        vm.prank(vaultCurator);
        v.submit(weaken);
        vm.warp(block.timestamp + 3 days);
        (bool ok,) = address(v).call(weaken);
        assertTrue(ok);
        assertFalse(registry.vaultSafe(address(v)), "live check fails: cap timelock 0");
        assertTrue(registry.isAllowedVault(address(v)), "not delisted yet");
    }

    /// @dev Inside the weak window the curator submits a cap increase on a market of its choice (executable at once),
    ///      then restores the checked timelock with the instant `increaseTimelock`.
    function _sleeperAndRestore(VaultV2 v) internal returns (bytes memory sleeper) {
        sleeper = abi.encodeCall(v.increaseAbsoluteCap, (abi.encode("curator market"), type(uint128).max));
        vm.prank(vaultCurator);
        v.submit(sleeper);
        _cur(v, abi.encodeCall(v.increaseTimelock, (IVaultV2.increaseAbsoluteCap.selector, 3 days)), true);
        assertEq(v.timelock(IVaultV2.increaseAbsoluteCap.selector), 3 days, "check restored");
    }

    // ================================================================ Finding 4: the live gate is sticky

    /// @dev Reviewer PoC `test_review_liveGate_curatorRestoresCheck_depositsResumeWithoutGov`, asserting the fixed
    ///      outcome: the keeper's pull in the weak window delists the vault, so after the curator restores the
    ///      timelock the registry still answers unsafe, nobody can re-deposit the circle's money, and only Gov's
    ///      reviewed `allowVault` (after the scan, here once the sleeper is revoked) resumes deposits.
    function test_CR_04_keeperPull_delists_curatorRestoreDoesNotResumeDeposits() public {
        VaultV2 v = _hardenedVault();
        _liveCircle(v);
        _weaken(v);

        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultDisallowed(address(v));
        vm.prank(keeper); // README keeper runbook: pull every share home
        circle.pullFromVault(type(uint256).max);
        assertEq(circle.vaultShares(), 0, "pulled");
        assertFalse(registry.isAllowedVault(address(v)), "delisted by the pull");

        bytes memory sleeper = _sleeperAndRestore(v);
        assertFalse(registry.vaultSafe(address(v)), "the curator cannot make it safe again");

        _openRound(2);
        _payAll(2, _everyone());
        uint256 idle = circle.idleAssets();
        vm.prank(attacker);
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        circle.deployIdle();
        assertEq(circle.idleAssets(), idle, "every unit stays idle in the circle");
        assertEq(v.balanceOf(address(circle)), 0);
        uint256 at = v.executableAt(sleeper);
        assertTrue(
            // forge-lint: disable-next-line(block-timestamp)
            at != 0 && at <= block.timestamp,
            "the sleeper is executable, but the circle holds nothing there"
        );

        // Gov's path: the mandatory pending-submission scan refuses while the sleeper is pending (A-R2-01); once the
        // curator revokes it, Gov re-allows and deposits resume.
        vm.prank(vaultCurator);
        v.revoke(sleeper);
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(v))));
        circle.deployIdle();
        assertEq(circle.idleAssets(), 0);
        assertGt(circle.vaultShares(), 0, "deposits resume after Gov's allowVault");
    }

    /// @dev Same window, no keeper: the first `deployIdle` (the backend's routine call, or anyone's) delists the vault
    ///      and returns without depositing; after the curator's restore deposits stay paused.
    function test_CR_04_deployIdleInTheWeakWindow_delistsAndDepositsNothing() public {
        VaultV2 v = _hardenedVault();
        _liveCircle(v);
        _weaken(v);
        _openRound(2);
        _payAll(2, _everyone());
        uint256 idle = circle.idleAssets();
        uint256 held = circle.vaultShares();

        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultDisallowed(address(v));
        vm.prank(attacker);
        circle.deployIdle();
        assertEq(circle.idleAssets(), idle, "nothing deposited");
        assertEq(circle.vaultShares(), held);
        assertFalse(registry.isAllowedVault(address(v)), "delisted by deployIdle");
        assertFalse(circle.yieldOff(), "nothing latched in the circle");

        _sleeperAndRestore(v);
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        circle.deployIdle();
        vm.prank(keeper);
        circle.pullFromVault(type(uint256).max); // and anyone may bring the rest home
        assertEq(circle.vaultShares(), 0);
    }

    /// @dev The same holds for an adapter's own timelock (`burnShares`), which its curator can also lower and raise.
    function test_CR_04_adapterTimelockFlip_isStickyToo() public {
        _startYield(4, 0);
        _payAll(1, _everyone());
        circle.deployIdle();
        bytes4 burn = IMorphoMarketV1AdapterV2.burnShares.selector;
        liqAdapter.mockSetTimelock(burn, 0);
        assertFalse(registry.vaultSafe(address(morpho)));
        vm.prank(keeper);
        circle.pullFromVault(type(uint256).max);
        assertFalse(registry.isAllowedVault(address(morpho)), "delisted by the pull");
        liqAdapter.mockSetTimelock(burn, 3 days); // the curator restores it
        _openRound(2);
        _payAll(2, _everyone());
        vm.expectRevert(IMHAccumulationCircle.VaultUnsafe.selector);
        circle.deployIdle();
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (address(morpho))));
        circle.deployIdle();
        assertGt(circle.vaultShares(), 0);
    }

    /// @dev An honest vault is never delisted by the circle: `pullFromVault` still reverts `YieldOn` (and leaves the
    ///      vault allowlisted), and `deployIdle` deposits.
    function test_CR_04_honestVault_neverDelisted() public {
        VaultV2 v = _hardenedVault();
        _liveCircle(v);
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.YieldOn.selector);
        circle.pullFromVault(type(uint256).max);
        assertTrue(registry.isAllowedVault(address(v)));
        _openRound(2);
        _payAll(2, _everyone());
        vm.prank(attacker);
        circle.deployIdle();
        assertEq(circle.idleAssets(), 0);
        assertTrue(registry.vaultSafe(address(v)));
    }

    // ================================================================ Finding 5: acknowledged, pinned

    /// @dev Reviewer PoC `test_review_exitEarly_blockedByIlliquidVault_despiteIdle`, pinned (acknowledged: an early
    ///      exit takes the pro-rata idle part and withdraws the rest from the vault, A-R2-06, and has no in-kind twin):
    ///      while the vault is illiquid the exit reverts even though idle USDC would cover it, and nobody but the
    ///      Guardian can move the position of a safe vault. Once liquidity returns, the exit pays its principal and
    ///      the idle/vault mix left is unchanged.
    function test_CR_05_exitEarly_waitsForVaultLiquidity_pinned() public {
        _startYield(4, 0);
        _payAll(1, _everyone());
        circle.deployIdle(); // $400 in the vault
        _openRound(2);
        _payAll(2, _everyone()); // $400 idle
        assertEq(circle.idleAssets(), 400e6);
        morpho.mockSetLiquidity(0);
        vm.prank(people[0]);
        vm.expectRevert(bytes("MockVaultV2: illiquid"));
        circle.exitEarly();
        vm.prank(attacker);
        vm.expectRevert(IMHCircle.YieldOn.selector);
        circle.pullFromVault(type(uint256).max);

        morpho.mockSetLiquidity(type(uint256).max);
        uint256 idle = circle.idleAssets();
        uint256 inVault = morpho.previewRedeem(circle.vaultShares());
        vm.prank(people[0]);
        assertEq(circle.exitEarly(), 200e6, "principal, once the vault is liquid");
        assertApproxEqAbs(
            circle.idleAssets() * inVault, (circle.nav() - circle.idleAssets()) * idle, 2e12, "mix kept"
        );
        _assertBuckets();
    }
}
