// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMoolaHubSusuAccumulation} from "./interfaces/IMoolaHubSusuAccumulation.sol";
import {IMoolaHubAccumulationFactory} from "./interfaces/IMoolaHubAccumulationFactory.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";

/// @title MoolaHubAccumulationFactory
/// @notice Deploys one MoolaHubSusuAccumulation clone per accumulation circle,
///         deterministically (so the backend can pre-compute the address) and
///         registers each new circle as an authorized reputation reporter.
///
/// @dev Mirrors MoolaHubCircleFactory. The owner SHOULD be a multisig + timelock
///      on mainnet. Fee/treasury/guardian are uniform policy stamped into each
///      circle at creation; changing them affects only FUTURE circles.
contract MoolaHubAccumulationFactory is IMoolaHubAccumulationFactory, Ownable2Step, ReentrancyGuard {
    using Clones for address;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap, matches the circle

    address public immutable implementation;
    address public immutable usdc;
    address public immutable reputation;

    address public treasury;
    address public guardian;
    uint16 public feeBps;

    mapping(bytes32 => address) public circleOf;

    error AlreadyExists();
    error BadConfig();

    constructor(
        address implementation_,
        address usdc_,
        address treasury_,
        address guardian_,
        address reputation_,
        uint16 feeBps_,
        address owner_
    ) Ownable(owner_) {
        if (
            implementation_ == address(0) || usdc_ == address(0) || treasury_ == address(0)
                || reputation_ == address(0) || guardian_ == address(0)
        ) revert BadConfig();
        if (feeBps_ > MAX_FEE_BPS) revert BadConfig();
        implementation = implementation_;
        usdc = usdc_;
        treasury = treasury_;
        guardian = guardian_;
        reputation = reputation_;
        feeBps = feeBps_;
    }

    /// @inheritdoc IMoolaHubAccumulationFactory
    function createAccumulationCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint64 roundDuration,
        uint64 gracePeriod,
        uint256 totalRounds,
        bool lockUntilMaturity
    ) external onlyOwner nonReentrant returns (address circle) {
        if (circleOf[circleId] != address(0)) revert AlreadyExists();

        circle = implementation.cloneDeterministic(circleId);
        circleOf[circleId] = circle;
        // Emit before the external calls (CEI): circleOf is already set, and if a
        // later call reverts the whole tx (and this event) is rolled back.
        emit AccumulationCircleCreated(circleId, circle, members.length, contributionAmount, totalRounds);

        // Let the new circle report delinquents, then initialize it.
        IMoolaHubReputation(reputation).setReporter(circle, true);
        IMoolaHubSusuAccumulation(circle).initialize(
            IMoolaHubSusuAccumulation.InitConfig({
                usdc: usdc,
                contributionAmount: contributionAmount,
                feeBps: feeBps,
                treasury: treasury,
                roundDuration: roundDuration,
                gracePeriod: gracePeriod,
                totalRounds: totalRounds,
                guardian: guardian,
                reputation: reputation,
                circleId: circleId,
                lockUntilMaturity: lockUntilMaturity
            }),
            members
        );
    }

    function predictAddress(bytes32 circleId) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, circleId, address(this));
    }

    // --- Admin (multisig/timelock) ------------------------------------------

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert BadConfig();
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert BadConfig();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert BadConfig();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }
}
