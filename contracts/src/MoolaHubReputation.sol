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
///      - Only authorized reporters may record strikes.
///      - The `factory` is allowed to authorize new escrow clones as reporters at
///        creation time, so the owner does not have to whitelist each circle.
///      - Strikes are monotonic; nothing here moves funds.
contract MoolaHubReputation is IMoolaHubReputation, Ownable2Step {
    address public factory;

    mapping(address => bool) public isReporter;
    mapping(address => uint256) public strikesOf;
    // Per-user, per-circle, per-round guard so the same miss can't be double-counted.
    mapping(address => mapping(bytes32 => mapping(uint256 => bool))) public struck;

    error NotAuthorized();
    error ZeroAddress();
    error BadReason();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Owner sets the factory permitted to authorize escrow reporters.
    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @notice Authorize/deauthorize a reporter. Callable by the owner or the factory.
    function setReporter(address reporter, bool allowed) external {
        if (msg.sender != owner() && msg.sender != factory) revert NotAuthorized();
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
}
