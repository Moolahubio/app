// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MoolaHubGoalVaultV2} from "../src/MoolaHubGoalVaultV2.sol";
import {PassthroughAdapter} from "../src/adapters/PassthroughAdapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

contract GoalVaultV2Test is Test {
    MockUSDC usdc;
    MoolaHubGoalVaultV2 vault;
    PassthroughAdapter passthrough;
    address treasury = address(0xFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bytes32 constant G = keccak256("goal-1");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MoolaHubGoalVaultV2(address(usdc), treasury, 200, address(this)); // owner = test
        passthrough = new PassthroughAdapter(address(usdc), address(vault));
        vault.setAdapter(passthrough); // initial set (no funds yet)
    }

    // ----------------------------- helpers ----------------------------------

    function _depositAs(address who, bytes32 g, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(g, amt);
        vm.stopPrank();
    }

    function _withdrawAs(address who, bytes32 g, uint256 amt) internal {
        vm.prank(who);
        vault.withdraw(g, amt);
    }

    /// Swap the vault onto a fresh ERC-4626 adapter; returns the mock 4626 so tests
    /// can simulate yield (mint underlying to it) or loss.
    function _useErc4626() internal returns (MockERC4626 v4626) {
        v4626 = new MockERC4626(IERC20(address(usdc)));
        ERC4626Adapter a = new ERC4626Adapter(address(usdc), address(v4626), address(vault));
        vault.setAdapter(a);
    }

    // ------------------------------ unit -------------------------------------

    function test_depositWithdraw_passthrough() public {
        _depositAs(alice, G, 100e6);
        assertEq(vault.balanceOf(alice, G), 100e6);
        assertEq(vault.principalOf(alice, G), 100e6);

        _withdrawAs(alice, G, 100e6); // full exit
        assertEq(vault.balanceOf(alice, G), 0);
        assertEq(usdc.balanceOf(alice), 98e6); // 2% fee
        assertEq(usdc.balanceOf(treasury), 2e6);
        assertEq(vault.totalShares(), 0);
    }

    function test_partialWithdraw() public {
        _depositAs(alice, G, 100e6);
        _withdrawAs(alice, G, 40e6);
        assertEq(usdc.balanceOf(alice), 40e6 - 8e5); // net = 40 - 2%
        assertEq(usdc.balanceOf(treasury), 8e5);
        assertApproxEqAbs(vault.balanceOf(alice, G), 60e6, 1);
    }

    function test_lockedFee_minOfLockedAndCurrent() public {
        _depositAs(alice, G, 100e6); // locks 200 bps
        vault.setFeeBps(500); // hike
        _withdrawAs(alice, G, 50e6); // fee = min(200,500) = 200
        assertEq(usdc.balanceOf(treasury), 1e6); // 2% of 50

        vault.setFeeBps(100); // cut below locked
        _withdrawAs(alice, G, 50e6); // fee = min(200,100) = 100 -> 1%; gross ~50 (rest of slot)
        // treasury gained 0.5e6 on the second withdraw (1% of ~50)
        assertApproxEqAbs(usdc.balanceOf(treasury), 1e6 + 5e5, 2e4);
    }

    function test_yieldAccrues_individualKeepsYield() public {
        MockERC4626 v = _useErc4626();
        _depositAs(alice, G, 100e6);
        usdc.mint(address(v), 10e6); // lender yield
        assertApproxEqAbs(vault.balanceOf(alice, G), 110e6, 2);

        uint256 gross = vault.balanceOf(alice, G);
        _withdrawAs(alice, G, gross); // full exit at the grown value
        // net = gross - 2%
        assertApproxEqAbs(usdc.balanceOf(alice), gross - (gross * 200) / 10_000, 2);
        assertEq(vault.balanceOf(alice, G), 0);
    }

    function test_loss_reducesBalance_noUnderflow() public {
        MockERC4626 v = _useErc4626();
        _depositAs(alice, G, 100e6);
        v.simulateLoss(20e6);
        assertApproxEqAbs(vault.balanceOf(alice, G), 80e6, 2);

        uint256 gross = vault.balanceOf(alice, G);
        _withdrawAs(alice, G, gross); // pays the reduced value; no revert/underflow
        assertApproxEqAbs(usdc.balanceOf(alice), gross - (gross * 200) / 10_000, 2);
    }

    function test_twoUsers_yieldProRata() public {
        _useErc4626();
        _depositAs(alice, G, 100e6);
        _depositAs(bob, G, 300e6);
        MockERC4626 v = MockERC4626(address(ERC4626Adapter(address(vault.adapter())).vault4626()));
        usdc.mint(address(v), 40e6); // +10% on 400 -> alice +10, bob +30
        assertApproxEqRel(vault.balanceOf(alice, G), 110e6, 0.005e18);
        assertApproxEqRel(vault.balanceOf(bob, G), 330e6, 0.005e18);
    }

    function test_setAdapter_migratesAndPreservesBalance() public {
        _depositAs(alice, G, 100e6); // on passthrough
        _useErc4626(); // migrate to ERC-4626
        assertApproxEqAbs(vault.balanceOf(alice, G), 100e6, 2);
        // funds actually moved to the new adapter
        assertApproxEqAbs(vault.totalManagedAssets(), 100e6, 2);
    }

    function test_emergencyExit_preservesValue() public {
        MockERC4626 v = _useErc4626();
        _depositAs(alice, G, 100e6);
        usdc.mint(address(v), 10e6); // yield
        PassthroughAdapter safe = new PassthroughAdapter(address(usdc), address(vault));
        vault.emergencyExitToPassthrough(safe);
        assertApproxEqAbs(vault.balanceOf(alice, G), 110e6, 2); // realized, now no market risk
        assertEq(address(vault.adapter()), address(safe));
    }

    function test_setAdapter_assetMismatchReverts() public {
        MockUSDC other = new MockUSDC();
        PassthroughAdapter wrong = new PassthroughAdapter(address(other), address(vault));
        vm.expectRevert(MoolaHubGoalVaultV2.AssetMismatch.selector);
        vault.setAdapter(wrong);
    }

    function test_onlyOwner_setAdapter() public {
        PassthroughAdapter p2 = new PassthroughAdapter(address(usdc), address(vault));
        vm.prank(alice);
        vm.expectRevert();
        vault.setAdapter(p2);
    }

    function test_nonCustodial_strangerCannotTakeOthersFunds() public {
        _depositAs(alice, G, 100e6);
        // Bob has no shares in this slot; any withdraw reverts (msg.sender-scoped).
        vm.prank(bob);
        vm.expectRevert(MoolaHubGoalVaultV2.Insufficient.selector);
        vault.withdraw(G, 1);
        // Even the owner cannot withdraw alice's funds — withdraw is keyed to caller.
        vm.expectRevert(MoolaHubGoalVaultV2.Insufficient.selector);
        vault.withdraw(G, 1);
        assertEq(vault.balanceOf(alice, G), 100e6);
    }

    function test_deposit_requiresAdapter() public {
        MoolaHubGoalVaultV2 fresh =
            new MoolaHubGoalVaultV2(address(usdc), treasury, 200, address(this));
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(fresh), 10e6);
        vm.expectRevert(MoolaHubGoalVaultV2.NoAdapter.selector);
        fresh.deposit(G, 10e6);
        vm.stopPrank();
    }

    function test_withdrawMoreThanBalanceReverts() public {
        _depositAs(alice, G, 100e6);
        vm.prank(alice);
        vm.expectRevert(MoolaHubGoalVaultV2.Insufficient.selector);
        vault.withdraw(G, 100e6 + 1);
    }

    // ------------------------------ fuzz -------------------------------------

    function testFuzz_roundTrip(uint256 amt) public {
        amt = bound(amt, 1e6, 1e12); // 1 .. 1,000,000 USDC
        _depositAs(alice, G, amt);
        uint256 gross = vault.balanceOf(alice, G);
        assertApproxEqAbs(gross, amt, 1); // no yield -> ~principal
        _withdrawAs(alice, G, gross);
        uint256 expectedNet = gross - (gross * 200) / 10_000;
        assertApproxEqAbs(usdc.balanceOf(alice), expectedNet, 1);
        assertEq(vault.balanceOf(alice, G), 0);
        assertEq(vault.totalShares(), 0);
    }

    /// First-depositor / donation inflation attack must not let an attacker rob a
    /// later depositor: with the 1e6 virtual-share offset the victim recovers ~all
    /// of their deposit (and the attacker forfeits their donation).
    /// Launch config (PassthroughAdapter). Attacker seeds 1 wei then donates a huge
    /// amount directly to the adapter to inflate the share price before the victim
    /// deposits. The share math cancels the donation: the victim recovers ~all of
    /// their deposit, and the attacker forfeits the donation. (For an ERC4626
    /// adapter, donation-resistance relies on the lender using internal accounting
    /// — Curvance cUSDC — not a donatable balanceOf, per plan §5.4.)
    function test_firstDepositorInflation_victimNotRobbed() public {
        _depositAs(address(0xBAD), G, 1);
        usdc.mint(address(passthrough), 1_000e6); // donation straight to the adapter (10x victim)
        _depositAs(alice, G, 100e6);
        // Recovers essentially all (observed loss ~455 wei = 4.5e-6 of the deposit).
        assertApproxEqAbs(vault.balanceOf(alice, G), 100e6, 1000);
    }

    function testFuzz_inflation_victimNotRobbed(uint256 victimAmt, uint256 donation) public {
        victimAmt = bound(victimAmt, 1e6, 1e12);
        // Donation up to 100x the victim's deposit — already economically absurd to
        // grief with (the attacker forfeits it all). Beyond ~1e6x, the victim's
        // deposit instead reverts (shares round to 0), which also protects them.
        donation = bound(donation, 0, victimAmt * 100);
        _depositAs(address(0xBAD), G, 1);
        usdc.mint(address(passthrough), donation);
        _depositAs(alice, G, victimAmt);
        // Victim recovers >= 99.9% regardless of the donation within this envelope.
        assertGe(vault.balanceOf(alice, G), victimAmt - victimAmt / 1000 - 10);
    }
}
