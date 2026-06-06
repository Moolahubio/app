// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";

/// @title MoolaHubReputation
/// @notice Append-only registry of "strikes" against addresses that miss a Susu
///         contribution deadline. MoolaHub decides off-chain what (if anything)
///         to do with flagged users; this contract only provides a tamper-proof,
///         queryable record.
///
/// @dev Trust model:
///      - Only authorized reporters (circle contracts) may record strikes.
///      - Authorizers (the rotation and accumulation factories) may authorize new
///        circle clones as reporters at creation time, so the owner does not have
///        to whitelist each circle. The owner manages the authorizer allowlist.
///      - Strikes are monotonic; nothing here moves funds.
contract MoolaHubReputation is IMoolaHubReputation, Ownable2Step {
    mapping(address => bool) public isAuthorizer; // factories allowed to register reporters
    mapping(address => bool) public isReporter; // circle contracts allowed to record strikes
    mapping(address => uint256) public strikesOf;
    // Per-user, per-circle, per-round guard so the same miss can't be double-counted.
    mapping(address => mapping(bytes32 => mapping(uint256 => bool))) public struck;

    error NotAuthorized();
    error ZeroAddress();
    error BadReason();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Owner authorizes/deauthorizes a factory that may register reporters.
    function setAuthorizer(address authorizer, bool allowed) external onlyOwner {
        if (authorizer == address(0)) revert ZeroAddress();
        isAuthorizer[authorizer] = allowed;
        emit AuthorizerSet(authorizer, allowed);
    }

    /// @notice Authorize/deauthorize a reporter. Callable by the owner or any authorizer.
    function setReporter(address reporter, bool allowed) external {
        if (msg.sender != owner() && !isAuthorizer[msg.sender]) revert NotAuthorized();
        if (reporter == address(0)) revert ZeroAddress();
        isReporter[reporter] = allowed;
        emit ReporterAuthorized(reporter, allowed);
    }

    /// @inheritdoc IMoolaHubReputation
    function recordStrike(address user, bytes32 circleId, uint256 round, uint8 reason) external {
        if (!isReporter[msg.sender]) revert NotAuthorized();
        if (reason == uint8(Reason.UNSPECIFIED)) revert BadReason();
        if (user == address(0)) revert ZeroAddress();
        if (struck[user][circleId][round]) return; // idempotent

        struck[user][circleId][round] = true;
        uint256 total = ++strikesOf[user];
        emit StrikeRecorded(user, circleId, round, reason, total);
    }

    /// @notice Record strikes for many users in one call (skips zero addresses and
    ///         duplicates). Lets circle contracts flag a whole round without making
    ///         an external call inside a loop.
    function recordStrikeBatch(address[] calldata users, bytes32 circleId, uint256 round, uint8 reason)
        external
    {
        if (!isReporter[msg.sender]) revert NotAuthorized();
        if (reason == uint8(Reason.UNSPECIFIED)) revert BadReason();
        uint256 n = users.length;
        for (uint256 i; i < n; ++i) {
            address user = users[i];
            if (user == address(0)) continue;
            if (struck[user][circleId][round]) continue;
            struck[user][circleId][round] = true;
            uint256 total = ++strikesOf[user];
            emit StrikeRecorded(user, circleId, round, reason, total);
        }
    }
}
