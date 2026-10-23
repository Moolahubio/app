// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IMHCircleFactory } from "./interfaces/IMHCircleFactory.sol";
import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "./interfaces/IMHReputation.sol";
import { IMHCircle } from "./interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "./interfaces/IMHRotatingCircle.sol";
import { IMHAccumulationCircle } from "./interfaces/IMHAccumulationCircle.sol";
import { CircleMode, RotatingParams, AccumulationParams } from "./MHCircleTypes.sol";

/// @title MHCircleFactory
/// @notice Ownerless factory for Moolahub circles. Only `registry.operator()` can create, and not while the
///         registry has paused creation. Each create runs, in one transaction:
///         `cloneDeterministic(impl, keccak256(abi.encode(circleId)))` → `reputation.setReporter(clone)` →
///         `initialize` → `isCircle[clone] = true` → `CircleCreated`.
///         A compromised operator can only create circles that members must still join on-chain; it can never
///         move funds.
/// @dev The implementations sit behind `IMHRotatingCircle`/`IMHAccumulationCircle` and are immutables. The
///      constructor checks the wiring (implementations ↔ registry, reputation, USDC; reputation ↔ factory), so a
///      mis-wired deployment reverts instead of producing circles that point at the wrong contracts. This needs
///      the registry, reputation and both implementations to have code before the factory is deployed, which is
///      the spec §5 order (implementations in batch 1; registry and reputation before the factory in batch 2).
contract MHCircleFactory is IMHCircleFactory, ReentrancyGuardTransient {
    /// @inheritdoc IMHCircleFactory
    IMHCircleRegistry public immutable REGISTRY;
    /// @inheritdoc IMHCircleFactory
    IMHReputation public immutable REPUTATION;
    /// @inheritdoc IMHCircleFactory
    address public immutable ROTATING_IMPL;
    /// @inheritdoc IMHCircleFactory
    address public immutable ACCUMULATION_IMPL;

    /// @inheritdoc IMHCircleFactory
    mapping(address circle => bool created) public isCircle;
    /// @inheritdoc IMHCircleFactory
    mapping(bytes32 circleId => address circle) public circleOf;

    /// @param registry The circle registry.
    /// @param reputation The reputation register; its `FACTORY()` must be this contract.
    /// @param rotatingImpl The rotating implementation; must report `CircleMode.Rotating` and the same wiring.
    /// @param accumulationImpl The accumulation implementation; must report `CircleMode.Accumulation` and the
    ///        same wiring.
    constructor(
        IMHCircleRegistry registry,
        IMHReputation reputation,
        address rotatingImpl,
        address accumulationImpl
    ) {
        if (
            address(registry) == address(0) || address(reputation) == address(0) || rotatingImpl == address(0)
                || accumulationImpl == address(0)
        ) revert ZeroAddress();
        if (reputation.FACTORY() != address(this)) revert WiringMismatch();
        _checkImpl(rotatingImpl, CircleMode.Rotating, registry, reputation);
        _checkImpl(accumulationImpl, CircleMode.Accumulation, registry, reputation);
        REGISTRY = registry;
        REPUTATION = reputation;
        ROTATING_IMPL = rotatingImpl;
        ACCUMULATION_IMPL = accumulationImpl;
    }

    /// @inheritdoc IMHCircleFactory
    function createRotating(RotatingParams calldata p) external nonReentrant returns (address circle) {
        bytes32 circleId = p.config.circleId;
        _checkCreate(circleId);
        circle = Clones.cloneDeterministic(ROTATING_IMPL, _salt(circleId));
        circleOf[circleId] = circle;
        REPUTATION.setReporter(circle);
        IMHRotatingCircle(circle).initialize(p);
        isCircle[circle] = true;
        emit CircleCreated(circleId, circle, CircleMode.Rotating, IMHCircle(circle).termsHash(), msg.sender);
    }

    /// @inheritdoc IMHCircleFactory
    function createAccumulation(AccumulationParams calldata p)
        external
        nonReentrant
        returns (address circle)
    {
        bytes32 circleId = p.config.circleId;
        _checkCreate(circleId);
        circle = Clones.cloneDeterministic(ACCUMULATION_IMPL, _salt(circleId));
        circleOf[circleId] = circle;
        REPUTATION.setReporter(circle);
        IMHAccumulationCircle(circle).initialize(p);
        isCircle[circle] = true;
        emit CircleCreated(
            circleId, circle, CircleMode.Accumulation, IMHCircle(circle).termsHash(), msg.sender
        );
    }

    /// @inheritdoc IMHCircleFactory
    function predictAddress(bytes32 circleId, CircleMode mode) external view returns (address) {
        address impl = mode == CircleMode.Rotating ? ROTATING_IMPL : ACCUMULATION_IMPL;
        return Clones.predictDeterministicAddress(impl, _salt(circleId));
    }

    // ---------------------------------------------------------------- Internal

    function _checkCreate(bytes32 circleId) private view {
        if (msg.sender != REGISTRY.operator()) revert NotOperator();
        if (REGISTRY.creationPaused()) revert CreationPaused();
        if (circleOf[circleId] != address(0)) revert CircleIdUsed();
    }

    function _salt(bytes32 circleId) private pure returns (bytes32) {
        return keccak256(abi.encode(circleId));
    }

    function _checkImpl(address impl, CircleMode mode, IMHCircleRegistry registry, IMHReputation reputation)
        private
        view
    {
        IMHCircle c = IMHCircle(impl);
        if (
            c.circleMode() != mode || c.REGISTRY() != registry || c.REPUTATION() != reputation
                || c.USDC() != registry.USDC()
        ) revert WiringMismatch();
    }
}
