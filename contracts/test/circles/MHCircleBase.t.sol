// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CircleFixture } from "./CircleFixture.sol";
import { MHCircleTerms } from "../../src/circles/MHCircleTerms.sol";
import { MHCircleConstants } from "../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { RotatingParams, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

import { MockRotatingCircle, MockAccumulationCircle } from "../mocks/MockCircles.sol";

/// @notice Tests the shared `MHCircleBase` plumbing (`_pay`/`owed`, `claimOwed`, USDC-paused guard, terms hash)
///         through a factory-created mock clone.
contract MHCircleBaseTest is CircleFixture {
    MockRotatingCircle internal circle;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        vm.prank(operator);
        circle = MockRotatingCircle(factory.createRotating(_rotParams(keccak256("base"), 3)));
        usdc.mint(address(circle), 1_000e6);
    }

    // ---------------------------------------------------------------- Constructor

    function test_constructor_revertsOnZero() public {
        IUSDC u = IUSDC(address(usdc));
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MockRotatingCircle(IUSDC(address(0)), registry, reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MockRotatingCircle(u, IMHCircleRegistry(address(0)), reputation);
        vm.expectRevert(IMHCircle.ZeroAddress.selector);
        new MockRotatingCircle(u, registry, IMHReputation(address(0)));
    }

    // ---------------------------------------------------------------- _pay

    function test_pay_transfersWhenPossible() public {
        vm.recordLogs();
        circle.payForTest(alice, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(circle.owed(alice), 0);
        assertEq(circle.owedTotal(), 0);
    }

    function test_pay_queuesWhenRecipientBlacklisted() public {
        usdc.setBlacklisted(alice, true);
        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.PayoutQueued(alice, 100e6);
        circle.payForTest(alice, 100e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(circle.owed(alice), 100e6);
        assertEq(circle.owedTotal(), 100e6);
        assertEq(usdc.balanceOf(address(circle)), 1_000e6, "funds stay in the circle");
    }

    function test_pay_queuesWhenUsdcPaused() public {
        usdc.setPaused(true);
        circle.payForTest(alice, 40e6);
        circle.payForTest(bob, 60e6);
        circle.payForTest(alice, 1e6);
        assertEq(circle.owed(alice), 41e6);
        assertEq(circle.owed(bob), 60e6);
        assertEq(circle.owedTotal(), 101e6);
    }

    function test_pay_zeroIsNoop() public {
        usdc.setBlacklisted(alice, true);
        vm.recordLogs();
        circle.payForTest(alice, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(circle.owed(alice), 0);
    }

    function test_pay_revertsWhenTransferFails() public {
        // Not blacklisted, not paused, but the circle cannot cover it: SafeERC20 reverts, nothing is queued.
        vm.expectRevert();
        circle.payForTest(alice, 1_000e6 + 1);
        assertEq(circle.owed(alice), 0);
    }

    // ---------------------------------------------------------------- claimOwed

    function test_claimOwed_paysCallerOnly() public {
        usdc.setBlacklisted(alice, true);
        circle.payForTest(alice, 100e6);
        usdc.setBlacklisted(alice, false);

        // Someone else cannot pull Alice's entry: they are owed nothing.
        vm.prank(bob);
        vm.expectRevert(IMHCircle.NothingOwed.selector);
        circle.claimOwed();

        vm.expectEmit(true, false, false, true, address(circle));
        emit IMHCircle.OwedClaimed(alice, 100e6);
        vm.prank(alice);
        uint256 paid = circle.claimOwed();
        assertEq(paid, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(circle.owed(alice), 0);
        assertEq(circle.owedTotal(), 0);

        vm.prank(alice);
        vm.expectRevert(IMHCircle.NothingOwed.selector);
        circle.claimOwed();
    }

    function test_claimOwed_whilePaused_revertsAndKeepsEntry() public {
        usdc.setPaused(true);
        circle.payForTest(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.claimOwed();
        assertEq(circle.owed(alice), 100e6);

        usdc.setPaused(false);
        vm.prank(alice);
        circle.claimOwed();
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function test_claimOwed_stillBlacklisted_revertsAndKeepsEntry() public {
        usdc.setBlacklisted(alice, true);
        circle.payForTest(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert("Blacklistable: account is blacklisted");
        circle.claimOwed();
        assertEq(circle.owed(alice), 100e6);
        assertEq(circle.owedTotal(), 100e6);
    }

    function testFuzz_owedTotalEqualsSumOfEntries(uint96[6] memory amounts, uint8 blMask) public {
        usdc.mint(address(circle), 6 * uint256(type(uint96).max));
        address[3] memory who = [alice, bob, makeAddr("carol")];
        for (uint256 i; i < 3; ++i) {
            usdc.setBlacklisted(who[i], (blMask >> i) & 1 == 1);
        }
        for (uint256 i; i < 6; ++i) {
            circle.payForTest(who[i % 3], amounts[i]);
        }
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += circle.owed(who[i]);
        }
        assertEq(circle.owedTotal(), sum);
    }

    // ---------------------------------------------------------------- USDC-paused guard

    function test_requireUsdcLive() public {
        circle.requireUsdcLiveForTest();
        usdc.setPaused(true);
        vm.expectRevert(IMHCircle.UsdcPaused.selector);
        circle.requireUsdcLiveForTest();
    }

    // ---------------------------------------------------------------- Terms hash

    function test_termsHash_rotatingFormula() public view {
        RotatingParams memory p = _rotParams(keccak256("base"), 3);
        bytes32 expected =
            keccak256(abi.encode(block.chainid, address(circle), p.config, p.members, p.securityBps));
        assertEq(circle.termsHash(), expected);
        assertEq(
            MHCircleTerms.rotating(block.chainid, address(circle), p.config, p.members, p.securityBps),
            expected
        );
    }

    function test_termsHash_accumulationFormula() public {
        AccumulationParams memory p = _accParams(keccak256("acc"), 4);
        vm.prank(operator);
        MockAccumulationCircle c = MockAccumulationCircle(factory.createAccumulation(p));
        bytes32 expected =
            keccak256(abi.encode(block.chainid, address(c), p.config, p.members, new uint16[](0)));
        assertEq(c.termsHash(), expected);
    }

    function test_termsHash_bindsEveryField() public view {
        RotatingParams memory p = _rotParams(keccak256("base"), 3);
        bytes32 h = MHCircleTerms.rotating(1, address(circle), p.config, p.members, p.securityBps);
        assertTrue(
            h != MHCircleTerms.rotating(2, address(circle), p.config, p.members, p.securityBps), "chain"
        );
        assertTrue(h != MHCircleTerms.rotating(1, address(1), p.config, p.members, p.securityBps), "address");
        RotatingParams memory q = _rotParams(keccak256("base"), 3);
        q.config.feeBps = 1;
        assertTrue(h != MHCircleTerms.rotating(1, address(circle), q.config, q.members, q.securityBps), "fee");
        q = _rotParams(keccak256("base"), 3);
        (q.members[0], q.members[1]) = (q.members[1], q.members[0]);
        assertTrue(
            h != MHCircleTerms.rotating(1, address(circle), q.config, q.members, q.securityBps), "order"
        );
        q = _rotParams(keccak256("base"), 3);
        q.securityBps[2] = 5_000;
        assertTrue(
            h != MHCircleTerms.rotating(1, address(circle), q.config, q.members, q.securityBps), "sigma"
        );
    }

    // ---------------------------------------------------------------- Constants sanity (spec §4.1)

    function test_constants() public pure {
        assertEq(MHCircleConstants.MAX_MEMBERS, 50);
        assertEq(MHCircleConstants.MAX_ROUNDS, 520);
        assertEq(MHCircleConstants.MAX_ROTATING_FEE_BPS, 200);
        assertEq(MHCircleConstants.MAX_ACCUMULATION_FEE_BPS, 1_500);
        assertEq(MHCircleConstants.MIN_SECURITY_BPS, 5_000);
        assertEq(MHCircleConstants.MAX_SECURITY_BPS, 10_000);
        assertEq(MHCircleConstants.MIN_ROUND, 7 days);
        assertEq(MHCircleConstants.MAX_ROUND, 92 days);
        assertEq(MHCircleConstants.MIN_GRACE, 48 hours);
        assertEq(MHCircleConstants.MIN_CURE, 72 hours);
        assertEq(MHCircleConstants.MAX_JOIN_WINDOW, 30 days);
        assertEq(MHCircleConstants.MAX_EXTENSION_PER_CALL, 7 days);
        assertEq(MHCircleConstants.MAX_EXTENSION_TOTAL, 30 days);
        assertEq(MHCircleConstants.MIN_CONTRIBUTION, 1e6);
        assertEq(MHCircleConstants.CENT, 1e4);
        assertEq(MHCircleConstants.VIRTUAL_SHARES, 1e6);
        assertEq(MHCircleConstants.MIN_DEPLOY, 1e6);
        assertEq(MHCircleConstants.MIN_VAULT_TIMELOCK, 7 days);
    }
}
