// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IUSDC
/// @notice Minimal view of Circle's FiatToken (USDC v2.2 on Base, `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`).
/// @dev Both views exist on FiatTokenV1+ (`Blacklistable.isBlacklisted`, `Pausable.paused`). A transfer reverts when
///      USDC is paused or when the sender or the recipient is blacklisted.
interface IUSDC is IERC20 {
    /// @notice Whether `account` is blacklisted by Circle.
    /// @param account The address to check.
    /// @return True when `account` can neither send nor receive USDC.
    function isBlacklisted(address account) external view returns (bool);

    /// @notice Whether USDC transfers are paused.
    /// @return True while every transfer reverts.
    function paused() external view returns (bool);
}
