// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MoolaHubReputation} from "../src/MoolaHubReputation.sol";
import {MoolaHubSusuAccumulation} from "../src/MoolaHubSusuAccumulation.sol";
import {MoolaHubAccumulationFactory} from "../src/MoolaHubAccumulationFactory.sol";
import {IMoolaHubSusuAccumulation} from "../src/interfaces/IMoolaHubSusuAccumulation.sol";

contract SusuAccumulationTest is Test {
    MockUSDC usdc;
    MoolaHubReputation rep;
    MoolaHubAccumulationFactory factory;
    MoolaHubSusuAccumulation acc;

    address owner = address(0xA11CE);
    address guardian = address(0x6A12D);
    address treasury = address(0x73E45);
    address alice = address(0xA1);
    address bob = address(0xB2);
    address carol = address(0xC3);

    uint256 constant CONTRIB = 100e6;
    uint16 constant FEE = 200; // 2%
    uint64 constant ROUND = 7 days;
    uint64 constant GRACE = 1 days;
    uint256 constant ROUNDS = 3;

    uint256 start;

    function setUp() public {
        usdc = new MockUSDC();

        address[] memory m = new address[](3);
        m[0] = alice;
        m[1] = bob;
        m[2] = carol;

        vm.startPrank(owner);
        rep = new MoolaHubReputation(owner);
        MoolaHubSusuAccumulation impl = new MoolaHubSusuAccumulation();
        factory = new MoolaHubAccumulationFactory(
            address(impl), address(usdc), treasury, guardian, address(rep), FEE, owner
        );
        rep.setAuthorizer(address(factory), true);
        acc = MoolaHubSusuAccumulation(
            factory.createAccumulationCircle(keccak256("acc-1"), CONTRIB, m, ROUND, GRACE, ROUNDS, true)
        );
        vm.stopPrank();

        start = block.timestamp;

        address[3] memory ms = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(ms[i], CONTRIB * ROUNDS);
            vm.prank(ms[i]);
            usdc.approve(address(acc), type(uint256).max);
        }
    }

    function _contribAll() internal {
        address[3] memory ms = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(ms[i]);
            acc.contribute();
        }
    }

    function test_contribute_accumulatesOwnSavings() public {
        _contribAll(); // round 1
        assertEq(acc.savingsOf(alice), CONTRIB);
        assertEq(acc.totalSaved(), CONTRIB * 3);

        vm.warp(start + ROUND); // round 2
        _contribAll();
        vm.warp(start + 2 * ROUND); // round 3
        _contribAll();

        assertEq(acc.savingsOf(alice), CONTRIB * 3);
        assertEq(acc.savingsOf(bob), CONTRIB * 3);
        assertEq(acc.savingsOf(carol), CONTRIB * 3);
        assertEq(usdc.balanceOf(address(acc)), CONTRIB * 9);
    }

    function test_doubleContributeSameRoundReverts() public {
        vm.prank(alice);
        acc.contribute();
        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuAccumulation.AlreadyContributed.selector);
        acc.contribute();
    }

    function test_withdraw_lockedUntilMaturity_thenChargesFee() public {
        vm.prank(alice);
        acc.contribute(); // saves 100

        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuAccumulation.Locked.selector);
        acc.withdraw();

        vm.warp(start + ROUND * ROUNDS); // maturity
        vm.prank(alice);
        acc.withdraw();
        assertEq(usdc.balanceOf(alice), CONTRIB * ROUNDS - CONTRIB + 98e6); // started 300, paid 100, got 98 back
        assertEq(usdc.balanceOf(treasury), 2e6);
        assertEq(acc.savingsOf(alice), 0);
    }

    function test_cancel_enablesFeeFreeWithdraw() public {
        vm.prank(alice);
        acc.contribute();
        vm.prank(guardian);
        acc.cancel();

        vm.prank(alice);
        acc.withdraw();
        assertEq(usdc.balanceOf(alice), CONTRIB * ROUNDS); // full refund, no fee
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_onlyOwnFundsWithdrawable() public {
        vm.prank(alice);
        acc.contribute();
        vm.warp(start + ROUND * ROUNDS);
        // Bob saved nothing -> nothing to withdraw.
        vm.prank(bob);
        vm.expectRevert(MoolaHubSusuAccumulation.NothingSaved.selector);
        acc.withdraw();
    }

    function test_flagRound_strikesNonContributors() public {
        vm.prank(alice);
        acc.contribute();
        vm.prank(bob);
        acc.contribute();
        // carol skips round 1

        vm.expectRevert(MoolaHubSusuAccumulation.RoundNotClosed.selector);
        acc.flagRound(1);

        vm.warp(start + ROUND + GRACE + 1);
        acc.flagRound(1);
        assertEq(rep.strikesOf(carol), 1);
        assertEq(rep.strikesOf(alice), 0);

        // Idempotent: flagging again doesn't add a second strike.
        acc.flagRound(1);
        assertEq(rep.strikesOf(carol), 1);
    }

    function test_noContributionOutsideSchedule() public {
        vm.warp(start + ROUND * ROUNDS); // matured -> currentRound() == 0
        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuAccumulation.NotInWindow.selector);
        acc.contribute();
    }

    function test_pauseBlocksContribution() public {
        vm.prank(guardian);
        acc.pause();
        vm.prank(alice);
        vm.expectRevert(MoolaHubSusuAccumulation.NotActive.selector);
        acc.contribute();
    }

    function test_sweepExcess_onlyTouchesSurplus() public {
        vm.prank(alice);
        acc.contribute(); // tracked 100
        usdc.mint(address(acc), 5e6); // accidental direct send
        acc.sweepExcess();
        assertEq(usdc.balanceOf(treasury), 5e6); // only the surplus
        assertEq(acc.totalSaved(), CONTRIB);
        // Alice can still withdraw her full savings later.
        vm.warp(start + ROUND * ROUNDS);
        vm.prank(alice);
        acc.withdraw();
        assertEq(acc.savingsOf(alice), 0);
    }

    function test_conservation() public {
        _contribAll();
        assertEq(
            usdc.balanceOf(address(acc)),
            acc.savingsOf(alice) + acc.savingsOf(bob) + acc.savingsOf(carol)
        );
    }

    // --- Factory ------------------------------------------------------------

    function _three() internal view returns (address[] memory m) {
        m = new address[](3);
        m[0] = alice;
        m[1] = bob;
        m[2] = carol;
    }

    function test_factory_predictMatchesDeployed() public {
        bytes32 id = keccak256("acc-predict");
        address predicted = factory.predictAddress(id);
        vm.prank(owner);
        address created = factory.createAccumulationCircle(id, CONTRIB, _three(), ROUND, GRACE, ROUNDS, true);
        assertEq(predicted, created);
        assertEq(factory.circleOf(id), created);
        MoolaHubSusuAccumulation c = MoolaHubSusuAccumulation(created);
        assertEq(c.totalRounds(), ROUNDS);
        assertEq(c.feeBps(), FEE);
        assertTrue(rep.isReporter(created));
    }

    function test_factory_duplicateReverts() public {
        bytes32 id = keccak256("acc-dup");
        vm.startPrank(owner);
        factory.createAccumulationCircle(id, CONTRIB, _three(), ROUND, GRACE, ROUNDS, true);
        vm.expectRevert(MoolaHubAccumulationFactory.AlreadyExists.selector);
        factory.createAccumulationCircle(id, CONTRIB, _three(), ROUND, GRACE, ROUNDS, true);
        vm.stopPrank();
    }

    function test_factory_nonOwnerCannotCreate() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.createAccumulationCircle(keccak256("acc-x"), CONTRIB, _three(), ROUND, GRACE, ROUNDS, true);
    }

    function test_implementationCannotBeInitialized() public {
        MoolaHubSusuAccumulation impl = new MoolaHubSusuAccumulation();
        IMoolaHubSusuAccumulation.InitConfig memory cfg;
        cfg.usdc = address(usdc);
        cfg.contributionAmount = CONTRIB;
        cfg.feeBps = FEE;
        cfg.treasury = treasury;
        cfg.roundDuration = ROUND;
        cfg.totalRounds = ROUNDS;
        cfg.guardian = guardian;
        vm.expectRevert();
        impl.initialize(cfg, _three());
    }
}
