// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MoolaHubSusuAccumulationV2 as Acc} from "../src/MoolaHubSusuAccumulationV2.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

contract AccumulationV2Handler is Test {
    Acc public acc;
    MockUSDC public usdc;
    MockERC4626 public v4626;
    address[3] public members = [address(0xA1), address(0xA2), address(0xA3)];

    constructor(Acc _acc, MockUSDC _usdc, MockERC4626 _v) {
        acc = _acc;
        usdc = _usdc;
        v4626 = _v;
    }

    function _m(uint256 s) internal view returns (address) {
        return members[s % 3];
    }

    function contribute(uint256 seed) external {
        address m = _m(seed);
        uint256 amt = acc.contributionAmount();
        usdc.mint(m, amt);
        vm.startPrank(m);
        usdc.approve(address(acc), amt);
        try acc.contribute() {} catch {} // round-gated; skip when not contributable
        vm.stopPrank();
    }

    function withdraw(uint256 seed) external {
        address m = _m(seed);
        if (acc.sharesOf(m) == 0) return;
        vm.prank(m);
        try acc.withdraw() {} catch {}
    }

    function advanceRound(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 120));
    }

    function accrueYield(uint256 amt) external {
        usdc.mint(address(v4626), bound(amt, 0, 1e9));
    }

    function simulateLoss(uint256 amt) external {
        uint256 bal = usdc.balanceOf(address(v4626));
        if (bal == 0) return;
        v4626.simulateLoss(bound(amt, 0, bal / 2));
    }

    function memberAt(uint256 i) external view returns (address) {
        return members[i % 3];
    }
}

/// @notice Per-clone solvency invariant for the accumulation vault: the sum of
///         members' redeemable balances never exceeds the assets backing them.
contract AccumulationV2Invariants is Test {
    MockUSDC usdc;
    Acc acc;
    MockERC4626 v4626;
    AccumulationV2Handler handler;

    function setUp() public {
        usdc = new MockUSDC();
        Acc impl = new Acc();
        acc = Acc(Clones.clone(address(impl)));
        address[] memory members = new address[](3);
        members[0] = address(0xA1);
        members[1] = address(0xA2);
        members[2] = address(0xA3);
        acc.initialize(
            Acc.InitConfig({
                usdc: address(usdc),
                contributionAmount: 100e6,
                feeBps: 200,
                treasury: address(0xFEE),
                roundDuration: 60,
                gracePeriod: 60,
                totalRounds: 100000, // long horizon so contributions keep happening under fuzz
                guardian: address(0x6A12D),
                configurer: address(this),
                reputation: address(0),
                circleId: keccak256("inv"),
                lockUntilMaturity: false
            }),
            members
        );
        v4626 = new MockERC4626(IERC20(address(usdc)));
        acc.setAdapter(new ERC4626Adapter(address(usdc), address(v4626), address(acc)));
        handler = new AccumulationV2Handler(acc, usdc, v4626);
        targetContract(address(handler));
    }

    function invariant_solvency() public view {
        uint256 sumBal;
        for (uint256 i; i < 3; i++) {
            sumBal += acc.balanceOf(handler.memberAt(i));
        }
        assertLe(sumBal, acc.totalManagedAssets() + 3);
    }
}
