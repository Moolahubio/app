// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubSusuAccumulation
/// @notice Accumulation-mode Susu circle: members save together on a shared
///         schedule, and each member withdraws THEIR OWN accumulated savings
///         (there is no rotating pot and no redistribution between members).
///         Strictly non-custodial — only the owner of a balance can withdraw it.
///         A 2% fee applies on normal withdrawals (waived if the circle is
///         cancelled). Rounds are time windows; missing one can be flagged to the
///         reputation registry. Enforcement of delinquency is off-chain.
interface IMoolaHubSusuAccumulation {
    enum Status {
        Active,
        Cancelled
    }
    // Note: "completed" is time-derived (block.timestamp >= maturity()), not a stored state.

    struct InitConfig {
        address usdc;
        uint256 contributionAmount; // USDC base units (6 dp)
        uint16 feeBps; // <= MAX_FEE_BPS
        address treasury;
        uint64 roundDuration; // seconds per round window
        uint64 gracePeriod; // seconds after a round before it can be flagged
        uint256 totalRounds; // number of contribution rounds
        address guardian; // may only pause / cancel
        address reputation; // optional (address(0) disables strike reporting)
        bytes32 circleId; // off-chain UUID, for correlation
        bool lockUntilMaturity; // if true, withdrawals only at/after maturity (or on cancel)
    }

    event Contributed(address indexed member, uint256 indexed round, uint256 amount);
    event Withdrawn(address indexed member, uint256 amount, uint256 fee);
    event DelinquentsFlagged(uint256 indexed round, uint256 count);
    event CircleCancelled(address indexed by);
    event ExcessSwept(uint256 amount);

    function initialize(InitConfig calldata cfg, address[] calldata members) external;

    function contribute() external;
    function withdraw() external;
    function flagRound(uint256 round) external; // permissionless after the round window closes
    function cancel() external; // guardian only (emergency); enables fee-free withdrawals
    function pause() external; // guardian only; blocks new contributions
    function sweepExcess() external; // sends only accidentally-sent surplus to the treasury

    function getMembers() external view returns (address[] memory);
    function savingsOf(address member) external view returns (uint256);
    function totalSaved() external view returns (uint256);
    function currentRound() external view returns (uint256); // 0 if outside any open round window
    function totalRounds() external view returns (uint256);
    function maturity() external view returns (uint256);
    function isMatured() external view returns (bool);
    function canWithdraw(address member) external view returns (bool);
    function status() external view returns (Status);
    function contributionAmount() external view returns (uint256);
    function feeBps() external view returns (uint16);
}
