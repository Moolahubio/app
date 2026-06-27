// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {PassthroughAdapter} from "../../src/adapters/PassthroughAdapter.sol";
import {ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";

/// @notice Unit tests for the yield adapter layer (migration plan §5.1). The test
///         contract plays the role of the controlling V2 vault.
contract AdaptersTest is Test {
    MockUSDC usdc;
    address controller; // = address(this)
    address recipient = address(0xBEEF);
    address stranger = address(0xCAFE);

    function setUp() public {
        usdc = new MockUSDC();
        controller = address(this);
    }

    // ----------------------------- Passthrough -----------------------------

    function test_passthrough_depositWithdraw() public {
        PassthroughAdapter a = new PassthroughAdapter(address(usdc), controller);
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);

        assertEq(a.deposit(100e6), 100e6);
        assertEq(a.totalAssets(), 100e6);
        assertEq(a.maxWithdraw(), 100e6);
        assertEq(a.asset(), address(usdc));

        assertEq(a.withdraw(40e6, recipient), 40e6);
        assertEq(usdc.balanceOf(recipient), 40e6);
        assertEq(a.totalAssets(), 60e6);
    }

    function test_passthrough_noYield() public {
        PassthroughAdapter a = new PassthroughAdapter(address(usdc), controller);
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);
        // USDC minted elsewhere must never count toward this adapter.
        usdc.mint(address(0x1234), 50e6);
        assertEq(a.totalAssets(), 100e6);
    }

    function test_passthrough_onlyController() public {
        PassthroughAdapter a = new PassthroughAdapter(address(usdc), controller);
        vm.prank(stranger);
        vm.expectRevert(PassthroughAdapter.NotController.selector);
        a.deposit(1e6);
        vm.prank(stranger);
        vm.expectRevert(PassthroughAdapter.NotController.selector);
        a.withdraw(1e6, stranger);
    }

    function test_passthrough_zeroAddrReverts() public {
        vm.expectRevert(PassthroughAdapter.ZeroAddress.selector);
        new PassthroughAdapter(address(0), controller);
        vm.expectRevert(PassthroughAdapter.ZeroAddress.selector);
        new PassthroughAdapter(address(usdc), address(0));
    }

    // ------------------------------ ERC-4626 -------------------------------

    function _erc4626() internal returns (ERC4626Adapter a, MockERC4626 v) {
        v = new MockERC4626(IERC20(address(usdc)));
        a = new ERC4626Adapter(address(usdc), address(v), controller);
    }

    function test_erc4626_depositWithdraw() public {
        (ERC4626Adapter a, MockERC4626 v) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);

        a.deposit(100e6);
        assertEq(usdc.balanceOf(address(v)), 100e6);
        assertApproxEqAbs(a.totalAssets(), 100e6, 1);
        assertEq(a.asset(), address(usdc));

        a.withdraw(40e6, recipient);
        assertEq(usdc.balanceOf(recipient), 40e6);
        assertApproxEqAbs(a.totalAssets(), 60e6, 1);
    }

    function test_erc4626_yieldAccrues() public {
        (ERC4626Adapter a, MockERC4626 v) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);

        // Lender yield: underlying accrues to the 4626 vault.
        usdc.mint(address(v), 10e6);
        assertApproxEqAbs(a.totalAssets(), 110e6, 2);

        uint256 mw = a.maxWithdraw();
        assertApproxEqAbs(mw, 110e6, 2);
        a.withdraw(mw, recipient);
        assertApproxEqAbs(usdc.balanceOf(recipient), 110e6, 2);
    }

    function test_erc4626_lossReducesValue() public {
        (ERC4626Adapter a, MockERC4626 v) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);

        // Lender impairment: value drops below principal (the vault must pay
        // min(principal, redeemable) — enforced in the V2 vault, not here).
        v.simulateLoss(20e6);
        assertApproxEqAbs(a.totalAssets(), 80e6, 1);
    }

    function test_erc4626_assetMismatchReverts() public {
        MockUSDC other = new MockUSDC();
        MockERC4626 vOther = new MockERC4626(IERC20(address(other)));
        vm.expectRevert(ERC4626Adapter.AssetMismatch.selector);
        new ERC4626Adapter(address(usdc), address(vOther), controller);
    }

    function test_erc4626_onlyController() public {
        (ERC4626Adapter a,) = _erc4626();
        vm.prank(stranger);
        vm.expectRevert(ERC4626Adapter.NotController.selector);
        a.deposit(1e6);
        vm.prank(stranger);
        vm.expectRevert(ERC4626Adapter.NotController.selector);
        a.withdraw(1e6, stranger);
    }

    // ----------------------- fail-closed / robustness -----------------------

    function test_passthrough_withdrawMoreThanBalanceReverts() public {
        PassthroughAdapter a = new PassthroughAdapter(address(usdc), controller);
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);
        vm.expectRevert(); // ERC20 insufficient balance — fail closed, never partial
        a.withdraw(150e6, recipient);
    }

    function test_erc4626_withdrawMoreThanRedeemableReverts() public {
        (ERC4626Adapter a,) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw — fail closed
        a.withdraw(150e6, recipient);
    }

    function test_erc4626_noDanglingAllowanceAfterDeposit() public {
        (ERC4626Adapter a, MockERC4626 v) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);
        // A compliant 4626 pulls the full amount, leaving no residual allowance.
        assertEq(usdc.allowance(address(a), address(v)), 0);
    }

    function test_erc4626_donationToAdapterDoesNotInflate() public {
        (ERC4626Adapter a,) = _erc4626();
        usdc.mint(controller, 100e6);
        usdc.approve(address(a), type(uint256).max);
        a.deposit(100e6);
        uint256 beforeAssets = a.totalAssets();
        // USDC sent straight to the adapter (not the 4626) must not count —
        // totalAssets reads the adapter's 4626 share balance only.
        usdc.mint(address(a), 50e6);
        assertApproxEqAbs(a.totalAssets(), beforeAssets, 1);
    }
}
