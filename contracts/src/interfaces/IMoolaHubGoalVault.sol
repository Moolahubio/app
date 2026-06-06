// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubGoalVault
/// @notice Singleton vault holding USDC per (owner, goalId). Strictly
///         non-custodial: only the owning account can withdraw its own balance;
///         there is no admin path to user funds. Deposits are free; withdrawals
///         charge a 2% fee to the treasury (the fee is collected here so a user
///         cannot bypass it by exporting their wallet). Early withdrawal is
///         always allowed — unlockAt is advisory only.
interface IMoolaHubGoalVault {
    event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount);
    event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 grossAmount, uint256 fee);
    event UnlockSet(address indexed owner, bytes32 indexed goalId, uint64 unlockAt);
    event FeeBpsSet(uint16 feeBps);
    event TreasurySet(address indexed treasury);

    function deposit(bytes32 goalId, uint256 amount) external;
    /// @notice Withdraw `grossAmount` from a goal; caller receives gross minus the 2% fee.
    function withdraw(bytes32 goalId, uint256 grossAmount) external;
    function setUnlock(bytes32 goalId, uint64 unlockAt_) external;

    function balanceOf(address owner, bytes32 goalId) external view returns (uint256);
    function unlockAt(address owner, bytes32 goalId) external view returns (uint64);
    function quoteWithdraw(uint256 grossAmount) external view returns (uint256 net, uint256 fee);
    function feeBps() external view returns (uint16);
    function treasury() external view returns (address);
}
