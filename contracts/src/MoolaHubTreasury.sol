// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MoolaHubTreasury
/// @notice Passive sink for platform fees (2% on Susu disbursements and Goal
///         withdrawals). Holds USDC until governance withdraws it. It never
///         touches user principal — fees are computed and split inside the
///         escrow/vault; the treasury only ever RECEIVES and, on owner authority,
///         withdraws.
///
/// @dev Owner SHOULD be a multisig (and ideally a timelock) on mainnet.
contract MoolaHubTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    /// @notice Withdraw collected fees (or any token) to a destination.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }
}
