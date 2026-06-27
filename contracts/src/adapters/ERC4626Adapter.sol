// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IYieldAdapter} from "./IYieldAdapter.sol";

/// @title ERC4626Adapter
/// @notice Routes idle USDC into any ERC-4626 vault (recommended target: Curvance
///         `cUSDC`, which is itself ERC-4626). `totalAssets` reads the 4626's own
///         internal accounting (`convertToAssets` over the adapter's share
///         balance), not a DEX/oracle spot price, so it can't be flash-manipulated.
///
/// @dev Non-custodial: only the controlling vault may move funds, and `withdraw`
///      only sends to a `to` the vault specifies. No admin/sweep path. The
///      constructor pins `vault4626.asset() == usdc` so a misconfigured adapter
///      cannot be wired in. The live Curvance market address is supplied at deploy
///      time (it is a [VERIFY] item) — this contract is address-agnostic.
contract ERC4626Adapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    IERC4626 public immutable vault4626; // the yield source (e.g. Curvance cUSDC)
    address public immutable controller; // the V2 savings vault

    error NotController();
    error ZeroAddress();
    error AssetMismatch();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(address usdc_, address vault4626_, address controller_) {
        if (usdc_ == address(0) || vault4626_ == address(0) || controller_ == address(0)) {
            revert ZeroAddress();
        }
        if (IERC4626(vault4626_).asset() != usdc_) revert AssetMismatch();
        usdc = IERC20(usdc_);
        vault4626 = IERC4626(vault4626_);
        controller = controller_;
    }

    /// @inheritdoc IYieldAdapter
    function deposit(uint256 assets) external onlyController returns (uint256 deployed) {
        // `from` is msg.sender (== controller via onlyController), i.e. the vault
        // pulls its own funds — never an arbitrary third party.
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        usdc.forceApprove(address(vault4626), assets);
        // We account in assets, not the minted shares.
        // slither-disable-next-line unused-return
        vault4626.deposit(assets, address(this)); // shares minted to this adapter
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function withdraw(uint256 assets, address to) external onlyController returns (uint256 received) {
        // Burns this adapter's shares; sends `assets` USDC straight to `to`. A
        // compliant 4626 delivers exactly `assets` or reverts (fail-closed).
        // slither-disable-next-line unused-return
        vault4626.withdraw(assets, to, address(this));
        return assets;
    }

    /// @inheritdoc IYieldAdapter
    function totalAssets() external view returns (uint256) {
        return vault4626.convertToAssets(vault4626.balanceOf(address(this)));
    }

    /// @inheritdoc IYieldAdapter
    function asset() external view returns (address) {
        return address(usdc);
    }

    /// @inheritdoc IYieldAdapter
    function maxWithdraw() external view returns (uint256) {
        return vault4626.maxWithdraw(address(this));
    }
}
