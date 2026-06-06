// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubSusuEscrow
/// @notice Per-circle rotating savings escrow (ROSCA / Susu). Custodies USDC
///         contributions and pays each round's positional recipient
///         automatically once the round fills. Non-discretionary: no one can
///         change the recipient or redirect funds. A 2% fee on each disbursement
///         is routed to the treasury (so a recipient owed 1000 receives 980).
interface IMoolaHubSusuEscrow {
    enum Status {
        Active,
        Completed,
        Cancelled
    }

    struct InitParams {
        address usdc;
        uint256 contributionAmount; // USDC base units (6 dp)
        address[] members; // index order == payout order
        uint16 feeBps; // <= MAX_FEE_BPS
        address treasury;
        uint64 roundDuration; // seconds per round
        uint64 gracePeriod; // seconds after deadline before a round can be cancelled/flagged
        address guardian; // may only pause + open refunds
        address reputation; // optional (address(0) disables strike reporting)
        bytes32 circleId; // off-chain UUID, for correlation
    }

    event Contributed(address indexed member, uint256 indexed round, uint256 amount);
    event RoundSettled(uint256 indexed round, address indexed recipient, uint256 payout, uint256 fee);
    event CircleCompleted(uint256 totalRounds);
    event CircleCancelled(uint256 atRound, address indexed by);
    event Refunded(address indexed member, uint256 amount);
    event DelinquentsFlagged(uint256 indexed round, uint256 count);

    function initialize(InitParams calldata p) external;

    function contribute() external;
    function contributeWithPermit(uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function flagDelinquents() external; // permissionless after deadline + grace
    function cancelStalled() external; // permissionless after deadline + grace
    function claimRefund() external; // contributor pulls unsettled contributions back
    function pause() external; // guardian only

    function status() external view returns (Status);
    function currentRound() external view returns (uint256);
    function totalRounds() external view returns (uint256);
    function contributionAmount() external view returns (uint256);
    function potAmount() external view returns (uint256);
    function getMembers() external view returns (address[] memory);
    function currentRecipient() external view returns (address);
    function hasContributed(uint256 round, address member) external view returns (bool);
    function refundableOf(address member) external view returns (uint256);
}
