// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MoolaHubGoalVaultV2} from "../src/MoolaHubGoalVaultV2.sol";
import {IYieldAdapter} from "../src/adapters/IYieldAdapter.sol";
import {PassthroughAdapter} from "../src/adapters/PassthroughAdapter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

/// @notice Random deposit/withdraw/yield/loss/adapter-swap driver over a fixed
///         actor set. The handler is made the vault owner so it can swap adapters.
contract GoalVaultV2Handler is Test {
    MoolaHubGoalVaultV2 public vault;
    MockUSDC public usdc;
    MockERC4626 public v4626;
    IYieldAdapter public passAdapter;
    IYieldAdapter public ercAdapter;
    address[4] public actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    bytes32 internal constant G = keccak256("inv-goal");

    constructor(
        MoolaHubGoalVaultV2 _vault,
        MockUSDC _usdc,
        MockERC4626 _v4626,
        IYieldAdapter _pass,
        IYieldAdapter _erc
    ) {
        vault = _vault;
        usdc = _usdc;
        v4626 = _v4626;
        passAdapter = _pass;
        ercAdapter = _erc;
    }

    function acceptVaultOwnership() external {
        vault.acceptOwnership();
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 4];
    }

    function deposit(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        amt = bound(amt, 1e6, 1e9);
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(vault), amt);
        vault.deposit(G, amt);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        uint256 bal = vault.balanceOf(a, G);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        vault.withdraw(G, amt);
    }

    function accrueYield(uint256 amt) external {
        usdc.mint(address(v4626), bound(amt, 0, 1e9));
    }

    function simulateLoss(uint256 amt) external {
        uint256 bal = usdc.balanceOf(address(v4626));
        if (bal == 0) return;
        v4626.simulateLoss(bound(amt, 0, bal / 2));
    }

    /// Swap the active adapter (owner action). Both are fully liquid, so migration
    /// must always succeed and preserve balances.
    function swapAdapter(uint256 seed) external {
        IYieldAdapter target = seed % 2 == 0 ? passAdapter : ercAdapter;
        if (address(vault.adapter()) == address(target)) return;
        vault.setAdapter(target);
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i % 4];
    }
}

/// @notice Core solvency invariant for the share-based vault (plan §5.4): the sum
///         of every user's redeemable balance never exceeds the assets backing
///         them — across arbitrary deposit/withdraw/yield/loss/adapter-swap runs.
contract GoalVaultV2Invariants is Test {
    MockUSDC usdc;
    MoolaHubGoalVaultV2 vault;
    MockERC4626 v4626;
    GoalVaultV2Handler handler;
    bytes32 internal constant G = keccak256("inv-goal");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new MoolaHubGoalVaultV2(address(usdc), address(0xFEE), 200, address(this));
        v4626 = new MockERC4626(IERC20(address(usdc)));
        PassthroughAdapter pass = new PassthroughAdapter(address(usdc), address(vault));
        ERC4626Adapter erc = new ERC4626Adapter(address(usdc), address(v4626), address(vault));
        vault.setAdapter(erc); // start on the yield adapter

        handler = new GoalVaultV2Handler(vault, usdc, v4626, pass, erc);
        // Hand the vault to the handler so it can exercise adapter swaps under fuzz.
        vault.transferOwnership(address(handler));
        handler.acceptVaultOwnership();
        targetContract(address(handler));
    }

    /// Σ balanceOf(user) ≤ totalManagedAssets — claims never exceed backing assets.
    function invariant_solvency() public view {
        uint256 sumBal;
        for (uint256 i; i < 4; i++) {
            sumBal += vault.balanceOf(handler.actorAt(i), G);
        }
        assertLe(sumBal, vault.totalManagedAssets() + 4); // + few-wei rounding dust
    }
}
