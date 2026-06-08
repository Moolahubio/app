// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MoolaHubGoalVault} from "../src/MoolaHubGoalVault.sol";

contract GoalVaultTest is Test {
    MockUSDC usdc;
    MoolaHubGoalVault vault;

    address owner = address(0xA11CE);
    address treasury = address(0x73E45);
    address alice = address(0xA1);
    address bob = address(0xB2);

    uint16 constant FEE = 200; // 2%
    bytes32 constant GOAL = keccak256("vacation");

    function setUp() public {
        usdc = new MockUSDC();
        vm.prank(owner);
        vault = new MoolaHubGoalVault(address(usdc), treasury, FEE, owner);
    }

    function _fund(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_deposit_then_withdraw_chargesFee() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        assertEq(vault.balanceOf(alice, GOAL), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        (uint256 net, uint256 fee) = vault.quoteWithdraw(100e6);
        assertEq(fee, 2e6);
        assertEq(net, 98e6);

        vm.prank(alice);
        vault.withdraw(GOAL, 100e6);
        assertEq(vault.balanceOf(alice, GOAL), 0);
        assertEq(usdc.balanceOf(alice), 98e6);
        assertEq(usdc.balanceOf(treasury), 2e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_partialWithdraw() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        vm.prank(alice);
        vault.withdraw(GOAL, 40e6); // fee 0.8, net 39.2
        assertEq(vault.balanceOf(alice, GOAL), 60e6);
        assertEq(usdc.balanceOf(alice), 39_200000);
        assertEq(usdc.balanceOf(treasury), 800000);
    }

    function test_onlyOwnerOfFundsCanWithdraw() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        // Bob has no balance under GOAL -> cannot drain alice's funds.
        vm.prank(bob);
        vm.expectRevert(MoolaHubGoalVault.Insufficient.selector);
        vault.withdraw(GOAL, 1e6);
    }

    function test_earlyWithdrawAllowed_unlockIsAdvisory() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        vm.prank(alice);
        vault.setUnlock(GOAL, uint64(block.timestamp + 365 days));
        // Withdraw before unlock still succeeds.
        vm.prank(alice);
        vault.withdraw(GOAL, 50e6);
        assertEq(vault.balanceOf(alice, GOAL), 50e6);
    }

    function test_adminCannotTakeUserFunds_onlyFeeAndTreasuryTunable() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);

        // Owner can tune fee within cap and treasury, but there is no function to
        // move a user's balance. Confirm the admin levers and the cap.
        vm.prank(owner);
        vault.setFeeBps(500);
        assertEq(vault.feeBps(), 500);

        vm.prank(owner);
        vm.expectRevert(MoolaHubGoalVault.FeeTooHigh.selector);
        vault.setFeeBps(501);

        // Alice's balance is untouched by any admin action.
        assertEq(vault.balanceOf(alice, GOAL), 100e6);
    }

    function test_conservation() public {
        _fund(alice, 100e6);
        _fund(bob, 50e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        vm.prank(bob);
        vault.deposit(GOAL, 50e6);
        assertEq(usdc.balanceOf(address(vault)), vault.balanceOf(alice, GOAL) + vault.balanceOf(bob, GOAL));
    }

    // --- Fee-lock invariant tests --------------------------------------------

    /// @notice A fee increase after deposit must NOT raise the cost for the
    ///         existing depositor. The locked rate (2%) must apply, not the new
    ///         global rate (5%).
    function test_feeIncrease_doesNotAffectExistingDepositor() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6); // locks fee at 2%

        // Owner raises fee to 5%.
        vm.prank(owner);
        vault.setFeeBps(500);
        assertEq(vault.feeBps(), 500);

        // Alice still pays the 2% locked rate, not the new 5%.
        (uint256 net, uint256 fee) = vault.quoteWithdrawFor(alice, GOAL, 100e6);
        assertEq(fee, 2e6);  // 2% of 100
        assertEq(net, 98e6);

        vm.prank(alice);
        vault.withdraw(GOAL, 100e6);
        assertEq(usdc.balanceOf(alice), 98e6); // 2% fee, not 5%
        assertEq(usdc.balanceOf(treasury), 2e6);
    }

    /// @notice A fee decrease after deposit SHOULD benefit the existing depositor
    ///         immediately (they pay the lower of locked vs current).
    function test_feeDecrease_benefitsExistingDepositor() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6); // locks fee at 2%

        // Owner lowers fee to 1%.
        vm.prank(owner);
        vault.setFeeBps(100);

        // Alice pays the lower rate (1%), not her locked 2%.
        (uint256 net, uint256 fee) = vault.quoteWithdrawFor(alice, GOAL, 100e6);
        assertEq(fee, 1e6);  // 1% of 100
        assertEq(net, 99e6);

        vm.prank(alice);
        vault.withdraw(GOAL, 100e6);
        assertEq(usdc.balanceOf(alice), 99e6);
        assertEq(usdc.balanceOf(treasury), 1e6);
    }

    /// @notice After a full withdrawal (balance -> 0), the lock resets. The
    ///         next deposit picks up the current global fee, not the old one.
    function test_lockedFeeResets_afterFullWithdrawal() public {
        _fund(alice, 200e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6); // locks at 2%

        // Fully withdraw.
        vm.prank(alice);
        vault.withdraw(GOAL, 100e6);
        assertEq(vault.balanceOf(alice, GOAL), 0);
        assertEq(vault.lockedFeeBpsOf(alice, GOAL), 0); // lock cleared

        // Owner raises fee to 5%.
        vm.prank(owner);
        vault.setFeeBps(500);

        // New deposit picks up 5%.
        vm.prank(alice);
        vault.deposit(GOAL, 100e6);
        assertEq(vault.lockedFeeBpsOf(alice, GOAL), 500);

        vm.prank(alice);
        vault.withdraw(GOAL, 100e6);
        assertEq(usdc.balanceOf(alice), 98e6 + 95e6); // first 98 + second 95
        assertEq(usdc.balanceOf(treasury), 2e6 + 5e6);
    }

    /// @notice quoteWithdrawFor correctly handles a deposit made while feeBps==0.
    ///         The locked fee is 0, meaning the user pays nothing. If feeBps later
    ///         rises, quoteWithdrawFor must still return 0 (matching withdraw()).
    function test_quoteWithdrawFor_feeLocked_atZero() public {
        // Deploy a fresh vault with fee=0.
        vm.prank(owner);
        MoolaHubGoalVault freeVault = new MoolaHubGoalVault(address(usdc), treasury, 0, owner);

        _fund(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(freeVault), type(uint256).max);
        vm.prank(alice);
        freeVault.deposit(GOAL, 100e6); // locked at fee=0

        // Owner raises fee to 5%.
        vm.prank(owner);
        freeVault.setFeeBps(500);

        // quoteWithdrawFor must return 0 fee (matching what withdraw() will charge).
        (uint256 net, uint256 fee) = freeVault.quoteWithdrawFor(alice, GOAL, 100e6);
        assertEq(fee, 0);
        assertEq(net, 100e6);

        // Actual withdrawal confirms 0 fee charged.
        vm.prank(alice);
        freeVault.withdraw(GOAL, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6); // no fee deducted
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// @notice Partial withdrawals keep the locked fee for subsequent withdrawals.
    function test_partialWithdraw_keepsLockedFee() public {
        _fund(alice, 100e6);
        vm.prank(alice);
        vault.deposit(GOAL, 100e6); // locks at 2%

        vm.prank(owner);
        vault.setFeeBps(500); // raise to 5%

        // Partial withdrawal still uses locked 2% (min of locked=200, global=500).
        vm.prank(alice);
        vault.withdraw(GOAL, 50e6);
        assertEq(usdc.balanceOf(alice), 49e6); // 50 - 2% = 49
        assertEq(vault.balanceOf(alice, GOAL), 50e6);
        // lockedFeeBpsOf returns min(locked=200, current=500) = 200.
        assertEq(vault.lockedFeeBpsOf(alice, GOAL), 200);

        // The remaining balance also uses the locked rate.
        vm.prank(alice);
        vault.withdraw(GOAL, 50e6);
        assertEq(usdc.balanceOf(alice), 49e6 + 49e6); // 2x (50 - 2%)
    }
}
