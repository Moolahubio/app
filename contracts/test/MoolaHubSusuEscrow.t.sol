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
        rep.setAuthorizer(address(factory), true);
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
        uint256 fullPayout = pot - fee; // 294 USDC — steady-state payout once no rounds remain

        // Round 1 -> recipient is members[0] = alice. Two future rounds remain,
        // so 2*CONTRIB of her payout is withheld as her own reserve rather than
        // paid out immediately — this is the fix: she can no longer walk away
        // with the full pot before funding her own remaining obligations.
        _roundContribute(e);
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(uint256(e.currentRound()), 2);
        uint256 round1Payout = fullPayout - CONTRIB * 2; // 94 USDC
        // alice: 300 start - 100 contributed + 94 immediate payout
        assertEq(usdc.balanceOf(alice), CONTRIB * 3 - CONTRIB + round1Payout);
        assertEq(e.heldReserve(alice), CONTRIB * 2);
        assertEq(usdc.balanceOf(bob), CONTRIB * 3 - CONTRIB);

        // Round 2 -> bob. Alice's round-2 due is drawn from her own reserve
        // (no fresh transferFrom needed), and bob's payout in turn withholds
        // his own remaining round-3 due.
        uint256 aliceBalanceBeforeRound2 = usdc.balanceOf(alice);
        _roundContribute(e);
        assertEq(usdc.balanceOf(treasury), fee * 2);
        assertEq(e.heldReserve(alice), CONTRIB); // one round drawn down
        assertEq(usdc.balanceOf(alice), aliceBalanceBeforeRound2); // no real transfer moved
        assertEq(e.heldReserve(bob), CONTRIB);

        // Round 3 -> carol; circle completes. Alice and bob both draw their
        // final round's due from reserve; nothing is left withheld anywhere.
        _roundContribute(e);
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Completed));
        assertEq(usdc.balanceOf(treasury), fee * 3); // 18 USDC total fees
        assertEq(usdc.balanceOf(address(e)), 0); // escrow drained
        assertEq(e.heldReserve(alice), 0);
        assertEq(e.heldReserve(bob), 0);
        assertEq(e.heldReserve(carol), 0);

        // Each member's final net position is unchanged from before the fix:
        // paid 300 total, received 294 total -> ends with 294. The reserve
        // only changes WHEN money moves, never the final honest-path split.
        assertEq(usdc.balanceOf(alice), fullPayout);
        assertEq(usdc.balanceOf(bob), fullPayout);
        assertEq(usdc.balanceOf(carol), fullPayout);
    }

    /// @notice The actual vulnerability being fixed: an early recipient takes
    ///         their round payout, then defaults on every future round rather
    ///         than continuing to contribute. Before this fix, the recipient
    ///         had already been paid the FULL pot, so later honest
    ///         contributors had no way to recover their own round-1
    ///         contributions once the circle stalled. Now, the recipient's
    ///         payout withheld a reserve covering their own future dues, and
    ///         that reserve is forfeited to the round's honest contributors on
    ///         cancellation instead of sitting stranded with the defaulter.
    function test_earlyRecipientDefault_forfeitsReserve_makesHonestMembersWhole() public {
        MoolaHubSusuEscrow e = _create(keccak256("c11"));
        _fundAll(address(e));

        // Round 1 settles normally; alice (position 0) is paid, with 2*CONTRIB
        // withheld as her reserve for the two rounds she has yet to fund.
        _roundContribute(e);
        assertEq(e.heldReserve(alice), CONTRIB * 2);

        // Round 2: bob and carol pay in as normal. Alice goes rogue and never
        // calls contribute() again — the round never fills.
        vm.prank(bob);
        e.contribute();
        vm.prank(carol);
        e.contribute();

        vm.warp(block.timestamp + ROUND + GRACE + 1);
        e.cancelStalled(); // permissionless

        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Cancelled));
        assertEq(rep.strikesOf(alice), 1); // the defaulter is flagged
        assertEq(e.heldReserve(alice), 0); // her reserve is forfeited, not returned to her

        // Bob and carol each contributed 200 total (round 1 + round 2) and
        // must be made whole: their round-2 contribution refunds (100 each)
        // plus an even split of alice's forfeited 200 reserve (100 each).
        assertEq(e.refundableOf(bob), CONTRIB * 2);
        assertEq(e.refundableOf(carol), CONTRIB * 2);
        assertEq(e.refundableOf(alice), 0); // she already received her round-1 payout

        vm.prank(bob);
        e.claimRefund();
        vm.prank(carol);
        e.claimRefund();

        // Both end up exactly where they started — no loss from alice's
        // default, beyond the round-1 fee already paid to the treasury.
        assertEq(usdc.balanceOf(bob), CONTRIB * 3);
        assertEq(usdc.balanceOf(carol), CONTRIB * 3);
        assertEq(usdc.balanceOf(address(e)), 0); // escrow fully drained, nothing stranded
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

    /// @notice The guardian must NOT be able to cancel a healthy (non-stalled)
    ///         circle. Removing this power closes the key-compromise extraction
    ///         path where a guardian could strand later members' principal after
    ///         early recipients have already been paid.
    function test_guardian_cannotCancelHealthyCircle() public {
        MoolaHubSusuEscrow e = _create(keccak256("c8"));
        _fundAll(address(e));

        // Round 1 fully settles — alice (position 0) gets paid.
        _roundContribute(e);
        assertEq(uint256(e.currentRound()), 2);

        // Round 2 is open and healthy (nobody has contributed yet but deadline
        // hasn't passed). Guardian attempts to force-cancel.
        vm.prank(guardian);
        vm.expectRevert(MoolaHubSusuEscrow.NotStalled.selector);
        e.cancelStalled();

        // Circle must still be active; bob and carol are not stranded.
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Active));
    }

    /// @notice Guardian pause cannot be weaponised to manufacture a stall:
    ///         cancelStalled() reverts while the circle is paused, and any
    ///         member can call unpause() to restore contribution ability.
    function test_guardian_pauseCannotManufactureStall() public {
        MoolaHubSusuEscrow e = _create(keccak256("c9"));
        _fundAll(address(e));

        // Round 1 settles normally.
        _roundContribute(e);

        // Guardian pauses during round 2.
        vm.prank(guardian);
        e.pause();
        assertTrue(e.paused());

        // Deadline passes — normally this would allow cancelStalled().
        vm.warp(block.timestamp + ROUND + GRACE + 1);

        // cancelStalled() must revert while paused.
        vm.expectRevert(MoolaHubSusuEscrow.CirclePaused.selector);
        e.cancelStalled();

        // Any member can unpause — this nullifies the manufactured stall.
        vm.prank(bob);
        e.unpause();
        assertFalse(e.paused());

        // After unpause, a genuine stall can still be cancelled normally.
        // (Here there ARE missing contributions past deadline, so it's legitimate.)
        e.cancelStalled();
        assertEq(uint8(e.status()), uint8(IMoolaHubSusuEscrow.Status.Cancelled));

        // Only round-2 contributions are refundable (none here — nobody paid in r2).
        // Alice's round-1 pot stays with alice (she legitimately received it).
        assertEq(e.refundableOf(alice), 0);
        assertEq(e.refundableOf(bob), 0);
        assertEq(e.refundableOf(carol), 0);
    }

    /// @notice Members can unpause and continue contributing normally.
    function test_member_canUnpause_andContribute() public {
        MoolaHubSusuEscrow e = _create(keccak256("c10"));
        _fundAll(address(e));

        vm.prank(guardian);
        e.pause();

        // Member unpauses.
        vm.prank(alice);
        e.unpause();
        assertFalse(e.paused());

        // Contributions resume normally.
        _roundContribute(e);
        assertEq(uint256(e.currentRound()), 2);

        // Non-member cannot unpause.
        vm.prank(guardian);
        e.pause();
        vm.prank(dave); // dave is not a member
        vm.expectRevert(MoolaHubSusuEscrow.NotMember.selector);
        e.unpause();
    }

    function test_feeCapEnforcedAtInit() public {
        // Build a factory with an over-cap fee and expect the escrow init to revert.
        vm.startPrank(owner);
        MoolaHubCircleFactory bad = new MoolaHubCircleFactory(
            address(impl), address(usdc), treasury, guardian, address(rep), 200, owner
        );
        rep.setAuthorizer(address(bad), true);
        // setFeeBps over cap must revert at the factory.
        vm.expectRevert(MoolaHubCircleFactory.BadConfig.selector);
        bad.setFeeBps(501);
        vm.stopPrank();
    }
}
