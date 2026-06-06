// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoolaHubReputation
/// @notice On-chain bad-actor registry. Susu escrows report members who miss a
///         contribution deadline; enforcement is decided off-chain. Only
///         reporters authorized by the factory (or the owner) may record strikes.
interface IMoolaHubReputation {
    /// @dev Reason codes for a strike.
    ///      1 = MISSED_CONTRIBUTION (member did not pay before round deadline + grace)
    enum Reason {
        UNSPECIFIED, // 0 — never used
        MISSED_CONTRIBUTION // 1
    }

    event ReporterAuthorized(address indexed reporter, bool allowed);
    event AuthorizerSet(address indexed authorizer, bool allowed);
    event StrikeRecorded(
        address indexed user, bytes32 indexed circleId, uint256 round, uint8 reason, uint256 totalStrikes
    );

    function recordStrike(address user, bytes32 circleId, uint256 round, uint8 reason) external;
    function recordStrikeBatch(address[] calldata users, bytes32 circleId, uint256 round, uint8 reason) external;
    function setReporter(address reporter, bool allowed) external;
    function setAuthorizer(address authorizer, bool allowed) external;

    function strikesOf(address user) external view returns (uint256);
    function isReporter(address reporter) external view returns (bool);
    function isAuthorizer(address authorizer) external view returns (bool);
}
