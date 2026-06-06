// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubCircleFactory
/// @notice Deploys MoolaHubSusuEscrow clones (EIP-1167) deterministically and
///         registers them. The platform fee, treasury, guardian and reputation
///         registry are held by the factory and stamped into each escrow at
///         creation, so every circle uses the same uniform policy.
interface IMoolaHubCircleFactory {
    event CircleCreated(
        bytes32 indexed circleId, address indexed escrow, uint256 members, uint256 contributionAmount
    );
    event FeeBpsSet(uint16 feeBps);
    event TreasurySet(address indexed treasury);
    event GuardianSet(address indexed guardian);

    function createCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint64 roundDuration,
        uint64 gracePeriod
    ) external returns (address escrow);

    function predictAddress(bytes32 circleId) external view returns (address);

    function escrowOf(bytes32 circleId) external view returns (address);
    function implementation() external view returns (address);
    function usdc() external view returns (address);
    function treasury() external view returns (address);
    function guardian() external view returns (address);
    function reputation() external view returns (address);
    function feeBps() external view returns (uint16);
}
