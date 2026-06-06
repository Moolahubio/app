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
}
