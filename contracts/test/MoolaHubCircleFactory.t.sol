// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MoolaHubReputation} from "../src/MoolaHubReputation.sol";
import {MoolaHubSusuEscrow} from "../src/MoolaHubSusuEscrow.sol";
import {MoolaHubCircleFactory} from "../src/MoolaHubCircleFactory.sol";

contract CircleFactoryTest is Test {
    MockUSDC usdc;
    MoolaHubReputation rep;
    MoolaHubSusuEscrow impl;
    MoolaHubCircleFactory factory;

    address owner = address(0xA11CE);
    address guardian = address(0x6A12D);
    address treasury = address(0x73E45);
    address alice = address(0xA1);
    address bob = address(0xB2);

    function setUp() public {
        usdc = new MockUSDC();
        vm.startPrank(owner);
        rep = new MoolaHubReputation(owner);
        impl = new MoolaHubSusuEscrow();
        factory = new MoolaHubCircleFactory(
            address(impl), address(usdc), treasury, guardian, address(rep), 200, owner
        );
        rep.setAuthorizer(address(factory), true);
        vm.stopPrank();
    }

    function _members() internal view returns (address[] memory m) {
        m = new address[](2);
        m[0] = alice;
        m[1] = bob;
    }

    function test_createCircle_initializesEscrow() public {
        bytes32 id = keccak256("f1");
        vm.prank(owner);
        MoolaHubSusuEscrow e = MoolaHubSusuEscrow(factory.createCircle(id, 25e6, _members(), 7 days, 1 days));
        assertEq(factory.escrowOf(id), address(e));
        assertEq(e.contributionAmount(), 25e6);
        assertEq(uint256(e.totalRounds()), 2);
        assertEq(e.treasury(), treasury);
        assertEq(e.guardian(), guardian);
        assertTrue(rep.isReporter(address(e)));
    }

    function test_duplicateCircleReverts() public {
        bytes32 id = keccak256("f2");
        vm.startPrank(owner);
        factory.createCircle(id, 25e6, _members(), 7 days, 1 days);
        vm.expectRevert(MoolaHubCircleFactory.AlreadyExists.selector);
        factory.createCircle(id, 25e6, _members(), 7 days, 1 days);
        vm.stopPrank();
    }

    function test_nonOwnerCannotCreate() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.createCircle(keccak256("f3"), 25e6, _members(), 7 days, 1 days);
    }
}
