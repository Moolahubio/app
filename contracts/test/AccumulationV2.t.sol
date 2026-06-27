// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MoolaHubSusuAccumulationV2 as Acc} from "../src/MoolaHubSusuAccumulationV2.sol";
import {PassthroughAdapter} from "../src/adapters/PassthroughAdapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

contract AccumulationV2Test is Test {
    MockUSDC usdc;
    Acc impl;
    Acc acc;
    address treasury = address(0xFEE);
    address guardian = address(0x6A12D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCC);
    uint256 constant AMT = 100e6;
    uint64 constant ROUND = 7 days;
    uint256 constant ROUNDS = 3;

    function setUp() public {
        usdc = new MockUSDC();
        impl = new Acc();
    }

    // --------------------------- helpers -------------------------------------

    function _deploy(bool lock) internal returns (Acc a) {
        a = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](3);
        members[0] = alice;
        members[1] = bob;
        members[2] = carol;
        a.initialize(
            Acc.InitConfig({
                usdc: address(usdc),
                contributionAmount: AMT,
                feeBps: 200,
                treasury: treasury,
                roundDuration: ROUND,
                gracePeriod: 1 days,
                totalRounds: ROUNDS,
                guardian: guardian,
                configurer: address(this), // test acts as the protocol configurer
                reputation: address(0),
                circleId: keccak256("c1"),
                lockUntilMaturity: lock
            }),
            members
        );
        // Wire a Passthrough adapter (configurer-only).
        a.setAdapter(new PassthroughAdapter(address(usdc), address(a)));
    }

    function _useErc4626(Acc a) internal returns (MockERC4626 v) {
        v = new MockERC4626(IERC20(address(usdc)));
        a.setAdapter(new ERC4626Adapter(address(usdc), address(v), address(a)));
    }

    function _contribute(Acc a, address who) internal {
        usdc.mint(who, AMT);
        vm.startPrank(who);
        usdc.approve(address(a), AMT);
        a.contribute();
        vm.stopPrank();
    }

    // ----------------------------- unit --------------------------------------

    function test_contribute_mintsShares() public {
        acc = _deploy(true);
        _contribute(acc, alice);
        assertApproxEqAbs(acc.balanceOf(alice), AMT, 1);
        assertEq(acc.principalOf(alice), AMT);
        assertTrue(acc.sharesOf(alice) > 0);
        assertTrue(acc.contributed(1, alice));
    }

    function test_withdraw_afterMaturity_withFee() public {
        acc = _deploy(true);
        _contribute(acc, alice);
        _contribute(acc, bob);
        vm.warp(acc.maturity());
        vm.prank(alice);
        acc.withdraw();
        assertEq(usdc.balanceOf(alice), AMT - (AMT * 200) / 10_000); // 98
        assertEq(usdc.balanceOf(treasury), (AMT * 200) / 10_000); // 2
        assertEq(acc.balanceOf(alice), 0);
    }

    function test_withdraw_lockedBeforeMaturity_reverts() public {
        acc = _deploy(true);
        _contribute(acc, alice);
        vm.prank(alice);
        vm.expectRevert(Acc.Locked.selector);
        acc.withdraw();
    }

    function test_withdraw_unlocked_anytime() public {
        acc = _deploy(false);
        _contribute(acc, alice);
        vm.prank(alice);
        acc.withdraw();
        assertEq(usdc.balanceOf(alice), AMT - (AMT * 200) / 10_000);
    }

    function test_noMemberTakesAnothersMoney() public {
        acc = _deploy(false);
        _contribute(acc, alice);
        _contribute(acc, bob);
        vm.prank(alice);
        acc.withdraw();
        // Bob's balance is intact; Alice only took her own.
        assertApproxEqAbs(acc.balanceOf(bob), AMT, 2);
        assertEq(usdc.balanceOf(alice), AMT - (AMT * 200) / 10_000);
    }

    function test_yieldAccrues_proRata() public {
        acc = _deploy(false);
        MockERC4626 v = _useErc4626(acc);
        _contribute(acc, alice); // round 1
        _contribute(acc, bob);
        usdc.mint(address(v), 40e6); // +20% on 200 pooled -> +20 each
        assertApproxEqRel(acc.balanceOf(alice), 120e6, 0.01e18);
        assertApproxEqRel(acc.balanceOf(bob), 120e6, 0.01e18);
    }

    function test_loss_reducesBalance_noUnderflow() public {
        acc = _deploy(false);
        MockERC4626 v = _useErc4626(acc);
        _contribute(acc, alice);
        v.simulateLoss(40e6); // halve the pool
        assertApproxEqAbs(acc.balanceOf(alice), 60e6, 2);
        uint256 expected = acc.balanceOf(alice);
        vm.prank(alice);
        acc.withdraw(); // no revert/underflow
        assertApproxEqAbs(usdc.balanceOf(alice), expected - (expected * 200) / 10_000, 2);
    }

    function test_cancel_feeFreeWithdraw_anytime() public {
        acc = _deploy(true); // locked, but cancel bypasses the lock
        _contribute(acc, alice);
        vm.prank(guardian);
        acc.cancel();
        vm.prank(alice);
        acc.withdraw();
        assertApproxEqAbs(usdc.balanceOf(alice), AMT, 1); // fee-free
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_contribute_oncePerRound() public {
        acc = _deploy(false);
        _contribute(acc, alice);
        usdc.mint(alice, AMT);
        vm.startPrank(alice);
        usdc.approve(address(acc), AMT);
        vm.expectRevert(Acc.AlreadyContributed.selector);
        acc.contribute();
        vm.stopPrank();
    }

    function test_contribute_secondRoundAfterWarp() public {
        acc = _deploy(false);
        _contribute(acc, alice); // round 1
        vm.warp(block.timestamp + ROUND); // round 2
        assertEq(acc.currentRound(), 2);
        _contribute(acc, alice); // round 2
        assertApproxEqAbs(acc.balanceOf(alice), 2 * AMT, 2);
    }

    function test_contribute_requiresAdapter() public {
        Acc a = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = bob;
        a.initialize(
            Acc.InitConfig({
                usdc: address(usdc), contributionAmount: AMT, feeBps: 200, treasury: treasury,
                roundDuration: ROUND, gracePeriod: 1 days, totalRounds: ROUNDS, guardian: guardian,
                configurer: address(this), reputation: address(0), circleId: keccak256("c2"),
                lockUntilMaturity: false
            }),
            members
        );
        usdc.mint(alice, AMT);
        vm.startPrank(alice);
        usdc.approve(address(a), AMT);
        vm.expectRevert(Acc.NoAdapter.selector);
        a.contribute();
        vm.stopPrank();
    }

    function test_initialize_rejectsTooManyMembers() public {
        Acc a = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](51);
        for (uint256 i; i < 51; i++) members[i] = address(uint160(1000 + i));
        vm.expectRevert(Acc.BadConfig.selector);
        a.initialize(
            Acc.InitConfig({
                usdc: address(usdc), contributionAmount: AMT, feeBps: 200, treasury: treasury,
                roundDuration: ROUND, gracePeriod: 1 days, totalRounds: ROUNDS, guardian: guardian,
                configurer: address(this), reputation: address(0), circleId: keccak256("c3"),
                lockUntilMaturity: false
            }),
            members
        );
    }

    function test_initialize_rejectsShortRoundDuration() public {
        Acc a = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = bob;
        vm.expectRevert(Acc.BadConfig.selector);
        a.initialize(
            Acc.InitConfig({
                usdc: address(usdc), contributionAmount: AMT, feeBps: 200, treasury: treasury,
                roundDuration: 30, gracePeriod: 1 days, totalRounds: ROUNDS, guardian: guardian,
                configurer: address(this), reputation: address(0), circleId: keccak256("c4"),
                lockUntilMaturity: false
            }),
            members
        );
    }

    function test_sweepExcess_onlyIdleNotMemberFunds() public {
        acc = _deploy(false);
        _contribute(acc, alice); // funds go to the adapter
        usdc.mint(address(acc), 5e6); // accidental direct send to the clone
        acc.sweepExcess();
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertApproxEqAbs(acc.balanceOf(alice), AMT, 2); // member funds untouched
    }

    function test_setAdapter_onlyConfigurer() public {
        acc = _deploy(false);
        PassthroughAdapter p2 = new PassthroughAdapter(address(usdc), address(acc));
        vm.prank(guardian); // guardian is NOT the configurer
        vm.expectRevert(Acc.NotConfigurer.selector);
        acc.setAdapter(p2);
    }

    function test_setAdapter_migratesAndPreservesBalance() public {
        acc = _deploy(false);
        _contribute(acc, alice); // on passthrough
        _useErc4626(acc); // configurer migrates to ERC-4626
        assertApproxEqAbs(acc.balanceOf(alice), AMT, 2);
    }

    function test_emergencyExit_preservesValue() public {
        acc = _deploy(false);
        MockERC4626 v = _useErc4626(acc);
        _contribute(acc, alice);
        usdc.mint(address(v), 20e6); // yield
        PassthroughAdapter safe = new PassthroughAdapter(address(usdc), address(acc));
        acc.emergencyExitToPassthrough(safe); // configurer (test) triggers the circuit breaker
        assertApproxEqAbs(acc.balanceOf(alice), 120e6, 2); // realized, now no market risk
        assertEq(address(acc.adapter()), address(safe));
    }

    function test_guardian_cannotTakeFunds() public {
        acc = _deploy(false);
        _contribute(acc, alice);
        // Guardian can pause/cancel but has no withdraw/setAdapter/sweep-to-self path.
        PassthroughAdapter p = new PassthroughAdapter(address(usdc), address(acc));
        vm.prank(guardian);
        acc.pause();
        vm.prank(guardian);
        vm.expectRevert(Acc.NotConfigurer.selector);
        acc.setAdapter(p);
        assertApproxEqAbs(acc.balanceOf(alice), AMT, 2);
    }

    // ----------------------------- fuzz --------------------------------------

    /// First-depositor inflation on the launch (Passthrough) config: a member
    /// contributes, donates to the adapter, then another member contributes — the
    /// victim still recovers ~their contribution (share math cancels the donation).
    function testFuzz_inflation_victimNotRobbed(uint256 donation) public {
        acc = _deploy(false);
        donation = bound(donation, 0, AMT * 100);
        _contribute(acc, alice); // attacker (member) contributes first
        usdc.mint(address(acc.adapter()), donation); // donate to the adapter
        _contribute(acc, bob); // victim
        assertGe(acc.balanceOf(bob), AMT - AMT / 1000 - 10); // >= 99.9%
    }
}
