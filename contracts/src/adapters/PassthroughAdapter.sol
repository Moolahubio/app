// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldAdapter} from "./IYieldAdapter.sol";

/// @title PassthroughAdapter
/// @notice No-yield adapter: holds USDC idle (zero market risk). It makes a V2
///         vault behave exactly like the V1 vaults, so it is both the launch
///         adapter and the emergency target for `emergencyExitToPassthrough`
///         (migration plan §5.3/§5.8E) — and the principal-protected option.
///
/// @dev Non-custodial: only the controlling vault may move funds, and `withdraw`
///      only ever sends to a `to` the vault chooses. No admin/sweep path.
contract PassthroughAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable controller; // the V2 savings vault

    error NotController();
    error ZeroAddress();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(address usdc_, address controller_) {
        if (usdc_ == address(0) || controller_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        controller = controller_;
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets) external onlyController returns (uint256 deployed) {
        // `from` is msg.sender (== controller via onlyController) — the vault pulls
        // its own funds, never an arbitrary third party. Held idle; no yield source.
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function withdraw(uint256 assets, address to) external onlyController returns (uint256 received) {
        usdc.safeTransfer(to, assets); // reverts if short — the vault caps to maxWithdraw()
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @inheritdoc IYieldAdapter
    function asset() external view returns (address) {
        return address(usdc);
    }

    /// @inheritdoc IYieldAdapter
    function maxWithdraw() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
