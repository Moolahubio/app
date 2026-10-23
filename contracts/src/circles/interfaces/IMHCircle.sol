// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IUSDC } from "./IUSDC.sol";
import { IMHCircleRegistry } from "./IMHCircleRegistry.sol";
import { IMHReputation } from "./IMHReputation.sol";
import { CircleMode } from "../MHCircleTypes.sol";

/// @title IMHCircle
/// @notice Surface shared by every Moolahub circle implementation (rotating and accumulation). Errors are the
///         spec §4.5 list plus `ZeroAddress` for constructor wiring.
interface IMHCircle {
    // ---------------------------------------------------------------- Errors (spec §4.5)
    error NotMember();
    error NotGuardian();
    error NotOperator();
    error BadConfig();
    error BadTerms();
    error AlreadyJoined();
    error JoinClosed();
    error NotPending();
    error NotActive();
    error BadRound();
    error AlreadyPaid();
    error ExceedsMaxPull();
    error RoundShort();
    error NotStalled();
    error Locked();
    error NotMatured();
    error AlreadySettled();
    error InsufficientSecurity();
    error NothingToClaim();
    error NothingOwed();
    error NotEnded();
    error YieldOn();
    error UsdcPaused();
    error ExtensionLimit();
    /// @notice USDC blacklists this circle, so members cannot pay: no strike, penalty or stall (audit R2-11).
    error CircleBlacklisted();
    /// @notice A constructor argument is zero.
    error ZeroAddress();

    // ---------------------------------------------------------------- Events

    /// @notice A payout could not be sent (recipient blacklisted or USDC paused) and was queued in `owed`.
    event PayoutQueued(address indexed to, uint256 amount);
    /// @notice A queued payout was claimed by its owner.
    event OwedClaimed(address indexed to, uint256 amount);

    // ---------------------------------------------------------------- Views

    /// @notice USDC (immutable, shared by every clone of the implementation).
    function USDC() external view returns (IUSDC);

    /// @notice The circle registry (immutable).
    function REGISTRY() external view returns (IMHCircleRegistry);

    /// @notice The reputation register (immutable).
    function REPUTATION() external view returns (IMHReputation);

    /// @notice The flavour of this implementation. The factory checks it at construction.
    function circleMode() external pure returns (CircleMode);

    /// @notice The backend circle id set at `initialize`.
    function circleId() external view returns (bytes32);

    /// @notice The terms hash members pass to `join` (see `MHCircleTerms`).
    function termsHash() external view returns (bytes32);

    /// @notice USDC queued for `account` because a payout could not be sent.
    /// @param account The payee.
    function owed(address account) external view returns (uint256);

    /// @notice Sum of every `owed` entry.
    function owedTotal() external view returns (uint256);

    // ---------------------------------------------------------------- Mutations

    /// @notice Pays the caller everything queued for them in `owed`. Pays `msg.sender` only (no redirect, so a
    ///         blacklisted payee cannot route around the blacklist).
    /// @return amount The USDC sent.
    function claimOwed() external returns (uint256 amount);
}
