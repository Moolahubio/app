// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MoolaHubSusuAccumulationV2 as Acc} from "../src/MoolaHubSusuAccumulationV2.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

/// @notice M5 forfeiture logic (plan §5.8): a delinquent member forfeits accrued
///         yield (receives only principal − fee); the forfeited yield redistributes
///         to compliant savers via the exchange rate. Reproduces the worked
///         examples and the all-delinquent edge.
contract AccumulationForfeitureTest is Test {
    MockUSDC usdc;
    Acc impl;
    address treasury = address(0xFEE);
    address guardian = address(0x6A12D);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint64 constant ROUND = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        impl = new Acc();
    }

    function _circle(uint256 contrib, uint256 rounds) internal returns (Acc a, MockERC4626 v) {
        a = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](2);
        members[0] = alice;
        members[1] = bob;
        a.initialize(
            Acc.InitConfig({
                usdc: address(usdc), contributionAmount: contrib, feeBps: 200, treasury: treasury,
                roundDuration: ROUND, gracePeriod: 1 days, totalRounds: rounds, guardian: guardian,
                configurer: address(this), reputation: address(0), circleId: keccak256("f"),
                lockUntilMaturity: true
            }),
            members
        );
        v = new MockERC4626(IERC20(address(usdc)));
        a.setAdapter(new ERC4626Adapter(address(usdc), address(v), address(a)));
    }

    function _contrib(Acc a, address who) internal {
        uint256 amt = a.contributionAmount();
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(a), amt);
        a.contribute();
        vm.stopPrank();
    }

    /// Compliant member: savings $1000 + profit $100 -> fee $22 -> receive $1078.
    function test_compliant_receivesPrincipalPlusYield_minusFee() public {
        (Acc a, MockERC4626 v) = _circle(500e6, 2);
        _contrib(a, alice);
        _contrib(a, bob); // round 1
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice);
        _contrib(a, bob); // round 2 -> each principal $1000, compliant
        usdc.mint(address(v), 200e6); // +$200 yield on $2000 pooled -> +$100 each
        vm.warp(a.maturity());

        assertTrue(a.isCompliant(alice));
        assertApproxEqAbs(a.balanceOf(alice), 1100e6, 2); // $1000 + $100
        vm.prank(alice);
        a.withdraw();
        assertApproxEqAbs(usdc.balanceOf(alice), 1078e6, 2); // $1100 - 2%
        assertApproxEqAbs(usdc.balanceOf(treasury), 22e6, 2);
    }

    /// Delinquent member: principal $1000, missed a round -> forfeit the yield,
    /// receive principal − 2% = $980. The forfeited yield lifts the compliant
    /// member's balance.
    function test_delinquent_forfeitsYield_redistributedToCompliant() public {
        (Acc a, MockERC4626 v) = _circle(500e6, 3);
        _contrib(a, alice);
        _contrib(a, bob); // round 1
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice);
        _contrib(a, bob); // round 2  (bob now principal $1000)
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice); // round 3: alice contributes, bob MISSES -> bob delinquent
        usdc.mint(address(v), 250e6); // yield; bob's share value rises above $1000
        vm.warp(a.maturity());

        assertTrue(a.isCompliant(alice)); // 3/3
        assertFalse(a.isCompliant(bob)); // 2/3
        assertGt(a.balanceOf(bob), 1000e6); // bob has yield to forfeit

        uint256 aliceBefore = a.balanceOf(alice);
        vm.prank(bob);
        a.withdraw(); // delinquent: principal $1000 - 2% = $980 exactly; forfeits the rest
        assertEq(usdc.balanceOf(bob), 980e6);
        assertEq(usdc.balanceOf(treasury), 20e6); // 2% of $1000

        // Bob's forfeited yield redistributed to the compliant saver (Alice).
        assertGt(a.balanceOf(alice), aliceBefore);
    }

    /// Delinquent after a loss: pay min(principal, redeemable) − fee, never assume
    /// principal is intact (no underflow).
    function test_delinquent_lossCapsAtRedeemable() public {
        (Acc a, MockERC4626 v) = _circle(500e6, 3);
        _contrib(a, alice);
        _contrib(a, bob);
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice);
        _contrib(a, bob); // bob principal $1000
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice); // bob misses round 3 -> delinquent
        v.simulateLoss(600e6); // big loss: redeemable < principal for everyone
        vm.warp(a.maturity());

        uint256 redeemable = a.balanceOf(bob);
        assertLt(redeemable, 1000e6); // loss pushed it below principal
        vm.prank(bob);
        a.withdraw(); // pays min(principal, redeemable) - fee = redeemable - 2%
        assertApproxEqAbs(usdc.balanceOf(bob), redeemable - (redeemable * 200) / 10_000, 2);
    }

    /// All-delinquent: nobody is compliant, so the orphaned forfeited yield has no
    /// saver to reward and is routed to the treasury (plan §5.8B).
    function test_allDelinquent_orphanedYieldToTreasury() public {
        (Acc a, MockERC4626 v) = _circle(500e6, 2);
        _contrib(a, alice);
        _contrib(a, bob); // round 1 only; both miss round 2 -> both delinquent (principal $500)
        usdc.mint(address(v), 100e6); // +$100 yield on $1000 pooled
        vm.warp(a.maturity());

        vm.prank(alice);
        a.withdraw(); // delinquent: $500 - 2% = $490
        vm.prank(bob);
        a.withdraw(); // delinquent + last out: $490, and the orphaned yield is swept

        assertEq(usdc.balanceOf(alice), 490e6);
        assertEq(usdc.balanceOf(bob), 490e6);
        // treasury = fees (2 x $10) + the ~$100 orphaned yield sweep.
        assertApproxEqAbs(usdc.balanceOf(treasury), 20e6 + 100e6, 3);
        assertEq(a.totalShares(), 0);
        // Conservation: everything that came in went out to members + treasury.
        assertApproxEqAbs(usdc.balanceOf(address(a)), 0, 3);
    }

    /// §5.8I: the last withdrawer can always exit, under arbitrary yield/loss.
    function testFuzz_lastWithdrawerAlwaysExits(uint256 yieldAmt, uint256 lossAmt) public {
        (Acc a, MockERC4626 v) = _circle(500e6, 2);
        _contrib(a, alice);
        _contrib(a, bob);
        vm.warp(block.timestamp + ROUND);
        _contrib(a, alice);
        _contrib(a, bob); // both compliant
        usdc.mint(address(v), bound(yieldAmt, 0, 1e12));
        uint256 pool = usdc.balanceOf(address(v));
        v.simulateLoss(bound(lossAmt, 0, pool / 2));
        vm.warp(a.maturity());

        vm.prank(alice);
        a.withdraw();
        vm.prank(bob);
        a.withdraw(); // the LAST withdrawer must never be stuck
        assertEq(a.totalShares(), 0);
        assertApproxEqAbs(usdc.balanceOf(address(a)), 0, 3); // fully drained
    }
}

/// @notice Drives random withdraw/yield/loss AFTER maturity over a pre-populated
///         circle (a1 compliant 3/3, a2 delinquent 2/3, a3 delinquent 1/3) so the
///         solvency invariant actually covers the forfeiture + last-out sweep paths.
contract ForfeitureInvariantHandler is Test {
    Acc public acc;
    MockUSDC public usdc;
    MockERC4626 public v;
    address[3] public members;

    constructor(Acc _a, MockUSDC _u, MockERC4626 _v, address[3] memory _m) {
        acc = _a;
        usdc = _u;
        v = _v;
        members = _m;
    }

    function withdraw(uint256 s) external {
        address m = members[s % 3];
        if (acc.sharesOf(m) == 0) return;
        vm.prank(m);
        try acc.withdraw() {} catch {}
    }

    function accrueYield(uint256 amt) external {
        usdc.mint(address(v), bound(amt, 0, 1e9));
    }

    function simulateLoss(uint256 amt) external {
        uint256 b = usdc.balanceOf(address(v));
        if (b == 0) return;
        v.simulateLoss(bound(amt, 0, b / 2));
    }

    function memberAt(uint256 i) external view returns (address) {
        return members[i % 3];
    }
}

contract AccumulationForfeitureInvariants is Test {
    MockUSDC usdc;
    Acc acc;
    MockERC4626 v;
    ForfeitureInvariantHandler handler;
    address[3] members = [address(0xA1), address(0xA2), address(0xA3)];

    function _c(address who) internal {
        usdc.mint(who, acc.contributionAmount());
        vm.startPrank(who);
        usdc.approve(address(acc), acc.contributionAmount());
        acc.contribute();
        vm.stopPrank();
    }

    function setUp() public {
        usdc = new MockUSDC();
        Acc impl = new Acc();
        acc = Acc(Clones.clone(address(impl)));
        address[] memory m = new address[](3);
        m[0] = members[0];
        m[1] = members[1];
        m[2] = members[2];
        acc.initialize(
            Acc.InitConfig({
                usdc: address(usdc), contributionAmount: 500e6, feeBps: 200, treasury: address(0xFEE),
                roundDuration: 7 days, gracePeriod: 1 days, totalRounds: 3, guardian: address(0x6A12D),
                configurer: address(this), reputation: address(0), circleId: keccak256("fi"),
                lockUntilMaturity: true
            }),
            m
        );
        v = new MockERC4626(IERC20(address(usdc)));
        acc.setAdapter(new ERC4626Adapter(address(usdc), address(v), address(acc)));

        // Round 1: all three. Round 2: a1,a2. Round 3: a1 only.
        _c(members[0]);
        _c(members[1]);
        _c(members[2]);
        vm.warp(block.timestamp + 7 days);
        _c(members[0]);
        _c(members[1]);
        vm.warp(block.timestamp + 7 days);
        _c(members[0]);
        usdc.mint(address(v), 300e6); // seed some yield to be (partly) forfeited
        vm.warp(acc.maturity());

        handler = new ForfeitureInvariantHandler(acc, usdc, v, members);
        targetContract(address(handler));
    }

    /// Σ balanceOf(member) ≤ totalManagedAssets across forfeiture withdrawals in
    /// any order, plus yield/loss.
    function invariant_solvency() public view {
        uint256 sumBal;
        for (uint256 i; i < 3; i++) {
            sumBal += acc.balanceOf(handler.memberAt(i));
        }
        assertLe(sumBal, acc.totalManagedAssets() + 3);
    }
}
