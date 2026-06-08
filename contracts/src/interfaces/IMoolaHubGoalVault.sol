// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubGoalVault
/// @notice Singleton vault holding USDC per (owner, goalId). Strictly
///         non-custodial: only the owning account can withdraw its own balance;
///         there is no admin path to user funds. Deposits are free; withdrawals
///         charge a fee to the treasury. The fee applied is the LOWER of the
///         global `feeBps` and the rate locked at the time of first deposit into
///         that slot — so fee increases never retroactively cost existing
///         depositors more, and fee decreases benefit them immediately.
///         Early withdrawal is always allowed — unlockAt is advisory only.
interface IMoolaHubGoalVault {
    event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount);
    event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 grossAmount, uint256 fee);
    event UnlockSet(address indexed owner, bytes32 indexed goalId, uint64 unlockAt);
    event FeeBpsSet(uint16 feeBps);
    event TreasurySet(address indexed treasury);

    function deposit(bytes32 goalId, uint256 amount) external;
    /// @notice Withdraw `grossAmount` from a goal; caller receives gross minus the effective fee.
    ///         The fee is the lower of the current global rate and the rate locked at first deposit.
    function withdraw(bytes32 goalId, uint256 grossAmount) external;
    function setUnlock(bytes32 goalId, uint64 unlockAt_) external;

    function balanceOf(address owner, bytes32 goalId) external view returns (uint256);
    function unlockAt(address owner, bytes32 goalId) external view returns (uint64);
    /// @notice Quote using the current global fee (useful for display/discovery).
    function quoteWithdraw(uint256 grossAmount) external view returns (uint256 net, uint256 fee);
    /// @notice Quote using the effective fee for a specific (owner, goalId) slot.
    function quoteWithdrawFor(address owner, bytes32 goalId, uint256 grossAmount)
        external
        view
        returns (uint256 net, uint256 fee);
    /// @notice The effective fee rate for a (owner, goalId) slot: min(locked, global).
    ///         Returns 0 for empty/unlocked slots.
    function lockedFeeBpsOf(address owner, bytes32 goalId) external view returns (uint16);
    function feeBps() external view returns (uint16);
    function treasury() external view returns (address);
}
