// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MoolaHubReputation} from "../src/MoolaHubReputation.sol";
import {MoolaHubSusuEscrow} from "../src/MoolaHubSusuEscrow.sol";
import {MoolaHubCircleFactory} from "../src/MoolaHubCircleFactory.sol";
import {IMoolaHubSusuEscrow} from "../src/interfaces/IMoolaHubSusuEscrow.sol";

contract SusuEscrowTest is Test {
    MockUSDC usdc;
    MoolaHubReputation rep;
    MoolaHubSusuEscrow impl;
    MoolaHubCircleFactory factory;

    address owner = address(0xA11CE);
    address guardian = address(0x6A12D);
    address treasury = address(0x73E45);
    address alice = address(0xA1);
    address bob = address(0xB2);
    address carol = address(0xC3);
    address dave = address(0xD4);

    uint256 constant CONTRIB = 100e6; // 100 USDC (6dp)
    uint16 constant FEE = 200; // 2%
    uint64 constant ROUND = 7 days;
    uint64 constant GRACE = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        vm.startPrank(owner);
        rep = new MoolaHubReputation(owner);
        impl = new MoolaHubSusuEscrow();
        factory = new MoolaHubCircleFactory(
            address(impl), address(usdc), treasury, guardian, address(rep), FEE, owner
        );
        rep.setFactory(address(factory));
        vm.stopPrank();
    }

    function _members() internal view returns (address[] memory m) {
        m = new address[](3);
        m[0] = alice;
        m[1] = bob;
        m[2] = carol;
    }

    function _create(bytes32 id) internal returns (MoolaHubSusuEscrow e) {
        vm.prank(owner);
        e = MoolaHubSusuEscrow(factory.createCircle(id, CONTRIB, _members(), ROUND, GRACE));
    }

    function _fundAll(address spender) internal {
        address[3] memory ms = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(ms[i], CONTRIB * 3);
            vm.prank(ms[i]);
            usdc.approve(spender, type(uint256).max);
        }
    }

    function _roundContribute(MoolaHubSusuEscrow e) internal {
        address[3] memory ms = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(ms[i]);
            e.contribute();
        }
    }

    function test_predictMatchesDeployed() public {
        bytes32 id = keccak256("c1");
        address predicted = factory.predictAddress(id);
        MoolaHubSusuEscrow e = _create(id);
        assertEq(predicted, address(e));
        assertEq(uint256(e.currentRound()), 1);
        assertEq(uint256(e.totalRounds()), 3);
        assertEq(e.feeBps(), FEE);
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Active));
    }

    function test_fullRotation_paysPositionalRecipients_netOfFee() public {
        MoolaHubSusuEscrow e = _create(keccak256("c2"));
        _fundAll(address(e));

        uint256 pot = CONTRIB * 3;
        uint256 fee = (pot * FEE) / 10_000; // 6 USDC
        uint256 payout = pot - fee; // 294 USDC

        // Round 1 -> recipient is members[0] = alice
        _roundContribute(e);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(uint256(e.currentRound()), 2);
        // alice: 300 start - 100 contributed + 294 payout
        assertEq(usdc.balanceOf(alice), CONTRIB * 3 - CONTRIB + payout);
        assertEq(usdc.balanceOf(bob), CONTRIB * 3 - CONTRIB);

        // Round 2 -> bob
        _roundContribute(e);
        assertEq(usdc.balanceOf(treasury), fee * 2);

        // Round 3 -> carol; circle completes
        _roundContribute(e);
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Completed));
        assertEq(usdc.balanceOf(treasury), fee * 3); // 18 USDC total fees
        assertEq(usdc.balanceOf(address(e)), 0); // escrow drained

        // Each member net: paid 300, received 294 -> ends with 294
        assertEq(usdc.balanceOf(alice), payout);
        assertEq(usdc.balanceOf(bob), payout);
        assertEq(usdc.balanceOf(carol), payout);
    }

    function test_doubleContributeReverts() public {
        MoolaHubSusuEscrow e = _create(keccak256("c3"));
        _fundAll(address(e));
        vm.prank(alice);
        e.contribute();
        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuEscrow.AlreadyContributed.selector);
        e.contribute();
    }

    function test_nonMemberReverts() public {
        MoolaHubSusuEscrow e = _create(keccak256("c4"));
        usdc.mint(dave, CONTRIB);
        vm.prank(dave);
        usdc.approve(address(e), type(uint256).max);
        vm.prank(dave);
        vm.expectRevert(MoolaHubSusuEscrow.NotMember.selector);
        e.contribute();
    }

    function test_stall_cancel_refund_andStrike() public {
        MoolaHubSusuEscrow e = _create(keccak256("c5"));
        _fundAll(address(e));

        // Only alice and bob pay; carol defaults.
        vm.prank(alice);
        e.contribute();
        vm.prank(bob);
        e.contribute();

        // Cannot cancel before deadline + grace.
        vm.expectRevert(MoolaHubSusuEscrow.NotStalled.selector);
        e.cancelStalled();

        vm.warp(block.timestamp + ROUND + GRACE + 1);
        e.cancelStalled(); // permissionless

        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Cancelled));
        assertEq(rep.strikesOf(carol), 1); // defaulter flagged
        assertEq(rep.strikesOf(alice), 0);

        assertEq(e.refundableOf(alice), CONTRIB);
        assertEq(e.refundableOf(bob), CONTRIB);

        vm.prank(alice);
        e.claimRefund();
        vm.prank(bob);
        e.claimRefund();

        assertEq(usdc.balanceOf(alice), CONTRIB * 3); // fully restored
        assertEq(usdc.balanceOf(bob), CONTRIB * 3);
        assertEq(usdc.balanceOf(address(e)), 0);
        assertEq(usdc.balanceOf(treasury), 0); // no fee on a cancelled circle
    }

    function test_flagDelinquents_withoutCancel() public {
        MoolaHubSusuEscrow e = _create(keccak256("c6"));
        _fundAll(address(e));
        vm.prank(alice);
        e.contribute();
        vm.prank(bob);
        e.contribute();

        vm.expectRevert(MoolaHubSusuEscrow.NotStalled.selector);
        e.flagDelinquents();

        vm.warp(block.timestamp + ROUND + GRACE + 1);
        e.flagDelinquents();
        assertEq(rep.strikesOf(carol), 1);
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Active)); // not cancelled
    }

    function test_pause_blocksContribution_andMovesNoFunds() public {
        MoolaHubSusuEscrow e = _create(keccak256("c7"));
        _fundAll(address(e));

        vm.prank(address(0xBEEF));
        vm.expectRevert(MoolaHubSusuEscrow.NotGuardian.selector);
        e.pause();

        vm.prank(guardian);
        e.pause();

        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuEscrow.NotActive.selector);
        e.contribute();

        assertEq(usdc.balanceOf(address(e)), 0);
        assertEq(usdc.balanceOf(guardian), 0); // guardian gained nothing
    }

    function test_feeCapEnforcedAtInit() public {
        // Build a factory with an over-cap fee and expect the escrow init to revert.
        vm.startPrank(owner);
        MoolaHubCircleFactory bad = new MoolaHubCircleFactory(
            address(impl), address(usdc), treasury, guardian, address(rep), 200, owner
        );
        rep.setFactory(address(bad));
        // setFeeBps over cap must revert at the factory.
        vm.expectRevert(MoolaHubCircleFactory.BadConfig.selector);
        bad.setFeeBps(501);
        vm.stopPrank();
    }
}
