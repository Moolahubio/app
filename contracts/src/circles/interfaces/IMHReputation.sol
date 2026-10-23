// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMHReputation
/// @notice Append-only strike register written by factory-created circles. Enforcement is off-chain.
interface IMHReputation {
    /// @notice Why a strike was recorded.
    /// @dev LATE: paid after grace. MISSED: an accumulation round was not paid. COVERED: a rotating gap was covered
    ///      from security. DEFAULT: the member's gap stalled the circle.
    enum Reason {
        LATE,
        MISSED,
        COVERED,
        DEFAULT
    }

    /// @notice The caller is not the factory.
    error NotFactory();
    /// @notice The caller is not a registered reporter.
    error NotReporter();
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice Ownership cannot be renounced.
    error RenounceDisabled();

    /// @notice Emitted when the factory registers a new circle as a reporter.
    event ReporterSet(address indexed reporter);
    /// @notice Emitted once per (user, circle, round, reason).
    event StrikeRecorded(address indexed user, address indexed circle, uint256 indexed round, Reason reason);

    /// @notice The only address allowed to register reporters (immutable).
    function FACTORY() external view returns (address);

    /// @notice Whether `account` is a registered reporter (a factory-created circle).
    /// @param account The address to check.
    function isReporter(address account) external view returns (bool);

    /// @notice Whether a strike was recorded for this key.
    /// @param user The member.
    /// @param circle The reporting circle.
    /// @param round The round.
    /// @param reason The reason.
    function struck(address user, address circle, uint256 round, Reason reason) external view returns (bool);

    /// @notice Total strikes recorded for `user`.
    /// @param user The member.
    function strikeCount(address user) external view returns (uint256);

    /// @notice Strikes recorded for `user` with `reason`.
    /// @param user The member.
    /// @param reason The reason.
    function strikesByReason(address user, Reason reason) external view returns (uint256);

    /// @notice Factory: register a freshly cloned circle as a reporter.
    /// @param reporter The circle clone.
    function setReporter(address reporter) external;

    /// @notice Reporter: record a strike. Idempotent per (user, circle, round, reason) and never reverts for a
    ///         registered reporter.
    /// @param user The member being struck.
    /// @param circle The reporting circle; must equal `msg.sender`, otherwise nothing is recorded.
    /// @param round The round the strike refers to.
    /// @param reason Why the strike is recorded.
    /// @return recorded True when a new strike was written, false when it already existed or was ignored.
    function record(address user, address circle, uint256 round, Reason reason)
        external
        returns (bool recorded);
}
