// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ERC-4626 test double over a mock asset (stands in for Curvance
///         cUSDC). Yield is simulated by minting the underlying directly to this
///         vault (raises `totalAssets`); `simulateLoss` ships underlying to a sink
///         to model a lender loss/impairment. Test-only.
contract MockERC4626 is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock cUSDC", "mcUSDC") ERC4626(asset_) {}

    function simulateLoss(uint256 amount) external {
        IERC20(asset()).transfer(address(0xdEaD), amount);
    }
}
