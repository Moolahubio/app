// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IMHReputation } from "./interfaces/IMHReputation.sol";

/// @title MHReputation
/// @notice Append-only strike register. Only factory-created circles can report, and each strike is keyed by
///         (user, circle, round, reason), so a LATE strike never blocks a later DEFAULT strike for the same round.
///         Owned (two-step) by the Gov Timelock; the owner has no power over strikes or reporters.
/// @dev `record` must never revert for a registered reporter: circles call it directly (no try/catch), so a
///      revert here would brick settlement. It only writes storage, makes no external call and has no
///      reason-dependent branch that can fail. "No strikes until every member has joined" is enforced by the
///      circles, which only report once every member has joined: a rotating circle while Active (and at the
///      cancellation that ends it), an accumulation circle's `flagRound` while Active, Matured or Closed (audit
///      R2-22; step-3 deviation 6).
contract MHReputation is IMHReputation, Ownable2Step {
    /// @inheritdoc IMHReputation
    address public immutable FACTORY;

    /// @inheritdoc IMHReputation
    mapping(address account => bool registered) public isReporter;
    /// @inheritdoc IMHReputation
    mapping(
        address user => mapping(address circle => mapping(uint256 round => mapping(Reason reason => bool)))
    ) public struck;
    /// @dev Audit 2 R1-24: every count of a user in one slot, so a first strike writes two fresh slots, not three
    ///      (about 22k gas less per strike; 1.1M at a 50-member stall). Bits [0, 48) hold the total and bits
    ///      [48·(r + 1), 48·(r + 2)) the count for reason r. A field cannot overflow: each increment needs a new
    ///      (circle, round, reason) key and a reporter transaction, far below 2^48 of them.
    mapping(address user => uint256 counts) private _counts;
    uint256 private constant COUNT_BITS = 48;
    // forge-lint: disable-next-line(incorrect-shift)
    uint256 private constant COUNT_MASK = (1 << COUNT_BITS) - 1;

    /// @param initialOwner The Gov Timelock.
    /// @param factory The circle factory (its predicted address under CREATE3 deployment).
    constructor(address initialOwner, address factory) Ownable(initialOwner) {
        if (factory == address(0)) revert ZeroAddress();
        FACTORY = factory;
    }

    /// @inheritdoc IMHReputation
    function setReporter(address reporter) external {
        if (msg.sender != FACTORY) revert NotFactory();
        if (reporter == address(0)) revert ZeroAddress();
        isReporter[reporter] = true;
        emit ReporterSet(reporter);
    }

    /// @inheritdoc IMHReputation
    function record(address user, address circle, uint256 round, Reason reason)
        external
        returns (bool recorded)
    {
        if (!isReporter[msg.sender]) revert NotReporter();
        // A circle may only strike under its own address. A mismatch is ignored rather than reverted, so that a
        // registered reporter can never be bricked by this call.
        if (circle != msg.sender) return false;
        mapping(Reason => bool) storage slot = struck[user][circle][round];
        if (slot[reason]) return false;
        slot[reason] = true;
        unchecked {
            // Cannot overflow (see `_counts`): at most one increment per distinct (circle, round, reason) key.
            // forge-lint: disable-next-line(incorrect-shift)
            _counts[user] += 1 | (1 << (COUNT_BITS * (uint256(reason) + 1)));
        }
        emit StrikeRecorded(user, circle, round, reason);
        return true;
    }

    /// @inheritdoc IMHReputation
    function strikeCount(address user) external view returns (uint256) {
        return _counts[user] & COUNT_MASK;
    }

    /// @inheritdoc IMHReputation
    function strikesByReason(address user, Reason reason) external view returns (uint256) {
        return (_counts[user] >> (COUNT_BITS * (uint256(reason) + 1))) & COUNT_MASK;
    }

    /// @notice Disabled, so `owner()` always stays the Timelock that VerifyBase asserts.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
