// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IYieldAdapter
/// @notice Swappable yield backend for the V2 savings vaults (migration plan §5.1).
///         The vault keeps share accounting; the adapter custodies the deployed
///         USDC and reports its current redeemable value (`totalAssets`).
///
/// @dev Non-custodial by construction: an adapter only ever moves funds on behalf
///      of its single controlling vault, and `withdraw` only sends to a `to` the
///      vault specifies — there is NO admin/owner path to move funds to an EOA.
///      `totalAssets` must derive from the yield source's own internal accounting
///      (e.g. a cToken/4626 share balance), never a manipulable DEX spot price.
interface IYieldAdapter {
    /// @notice Pull `assets` USDC from the controller (vault) and deploy it to the
    ///         yield source. The vault must have approved this adapter first.
    /// @return deployed Amount accepted/deployed (== `assets` on success).
    function deposit(uint256 assets) external returns (uint256 deployed);

    /// @notice Redeem `assets` USDC from the yield source and send it to `to`.
    /// @return received Amount actually delivered to `to`.
    function withdraw(uint256 assets, address to) external returns (uint256 received);

    /// @notice Current redeemable value held by the adapter (principal + accrued
    ///         yield, or less after a loss). Drives the vault's exchange rate.
    function totalAssets() external view returns (uint256);

    /// @notice The underlying asset; MUST equal the vault's USDC.
    function asset() external view returns (address);

    /// @notice Upper bound on an immediate withdrawal, given lender liquidity.
    function maxWithdraw() external view returns (uint256);
}
