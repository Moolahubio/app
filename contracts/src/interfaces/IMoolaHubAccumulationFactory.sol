// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubAccumulationFactory
/// @notice Deploys MoolaHubSusuAccumulation clones (EIP-1167) deterministically,
///         one per circle, each with its own parameters. Uniform policy (fee,
///         treasury, guardian, reputation, token) is held by the factory and
///         stamped into each circle at creation.
interface IMoolaHubAccumulationFactory {
    event AccumulationCircleCreated(
        bytes32 indexed circleId,
        address indexed circle,
        uint256 members,
        uint256 contributionAmount,
        uint256 totalRounds
    );
    event FeeBpsSet(uint16 feeBps);
    event TreasurySet(address indexed treasury);
    event GuardianSet(address indexed guardian);

    function createAccumulationCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint64 roundDuration,
        uint64 gracePeriod,
        uint256 totalRounds,
        bool lockUntilMaturity
    ) external returns (address circle);

    function predictAddress(bytes32 circleId) external view returns (address);

    function circleOf(bytes32 circleId) external view returns (address);
    function implementation() external view returns (address);
    function usdc() external view returns (address);
    function treasury() external view returns (address);
    function guardian() external view returns (address);
    function reputation() external view returns (address);
    function feeBps() external view returns (uint16);
}
