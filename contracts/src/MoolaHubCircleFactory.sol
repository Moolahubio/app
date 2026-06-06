// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMoolaHubSusuEscrow} from "./interfaces/IMoolaHubSusuEscrow.sol";
import {IMoolaHubCircleFactory} from "./interfaces/IMoolaHubCircleFactory.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";

/// @title MoolaHubCircleFactory
/// @notice Deploys MoolaHubSusuEscrow clones deterministically (so the backend
///         can pre-compute and store the address) and registers each new escrow
///         as an authorized reporter on the reputation registry.
///
/// @dev The owner SHOULD be a multisig (and a timelock) on mainnet. Fee,
///      treasury and guardian are uniform policy held here and stamped into each
///      escrow at creation; changing them affects only FUTURE circles — a
///      deployed escrow snapshots them at initialize() and is then immutable.
contract MoolaHubCircleFactory is IMoolaHubCircleFactory, Ownable2Step {
    using Clones for address;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap, matches the escrow

    address public immutable implementation;
    address public immutable usdc;
    address public immutable reputation;

    address public treasury;
    address public guardian;
    uint16 public feeBps;

    mapping(bytes32 => address) public escrowOf;

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
                || reputation_ == address(0)
        ) revert BadConfig();
        if (feeBps_ > MAX_FEE_BPS) revert BadConfig();
        implementation = implementation_;
        usdc = usdc_;
        treasury = treasury_;
        guardian = guardian_;
        reputation = reputation_;
        feeBps = feeBps_;
    }

    /// @inheritdoc IMoolaHubCircleFactory
    function createCircle(
        bytes32 circleId,
        uint256 contributionAmount,
        address[] calldata members,
        uint64 roundDuration,
        uint64 gracePeriod
    ) external onlyOwner returns (address escrow) {
        if (escrowOf[circleId] != address(0)) revert AlreadyExists();

        escrow = implementation.cloneDeterministic(circleId);
        escrowOf[circleId] = escrow;

        // Let the new escrow report delinquents.
        IMoolaHubReputation(reputation).setReporter(escrow, true);

        IMoolaHubSusuEscrow(escrow).initialize(
            IMoolaHubSusuEscrow.InitParams({
                usdc: usdc,
                contributionAmount: contributionAmount,
                members: members,
                feeBps: feeBps,
                treasury: treasury,
                roundDuration: roundDuration,
                gracePeriod: gracePeriod,
                guardian: guardian,
                reputation: reputation,
                circleId: circleId
            })
        );

        emit CircleCreated(circleId, escrow, members.length, contributionAmount);
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
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }
}
