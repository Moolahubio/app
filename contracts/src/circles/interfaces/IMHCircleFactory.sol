// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMHCircleRegistry } from "./IMHCircleRegistry.sol";
import { IMHReputation } from "./IMHReputation.sol";
import { CircleMode, RotatingParams, AccumulationParams } from "../MHCircleTypes.sol";

/// @title IMHCircleFactory
/// @notice Ownerless EIP-1167 factory for Moolahub circles. The backend and the device trust only
///         `isCircle` and `predictAddress`.
interface IMHCircleFactory {
    /// @notice The caller is not `registry.operator()`.
    error NotOperator();
    /// @notice The registry has paused circle creation.
    error CreationPaused();
    /// @notice A constructor argument is zero.
    error ZeroAddress();
    /// @notice A constructor argument is not wired to the others (registry, reputation, implementations, USDC).
    error WiringMismatch();
    /// @notice A circle already exists for this circle id (in either mode).
    error CircleIdUsed();

    /// @notice Emitted once per created circle, after it is initialized and registered.
    event CircleCreated(
        bytes32 indexed circleId,
        address indexed circle,
        CircleMode indexed mode,
        bytes32 termsHash,
        address operator
    );

    /// @notice The circle registry (immutable).
    function REGISTRY() external view returns (IMHCircleRegistry);

    /// @notice The reputation register (immutable).
    function REPUTATION() external view returns (IMHReputation);

    /// @notice The rotating circle implementation (immutable).
    function ROTATING_IMPL() external view returns (address);

    /// @notice The accumulation circle implementation (immutable).
    function ACCUMULATION_IMPL() external view returns (address);

    /// @notice Whether `circle` was created and initialized by this factory.
    /// @param circle The address to check.
    function isCircle(address circle) external view returns (bool);

    /// @notice The circle created for `circleId`, or address(0).
    /// @param circleId The backend circle id.
    function circleOf(bytes32 circleId) external view returns (address);

    /// @notice Operator: clone, register and initialize a rotating circle.
    /// @param p The rotating circle's terms, members and per-slot sigma.
    /// @return circle The new circle (equal to `predictAddress(p.config.circleId, CircleMode.Rotating)`).
    function createRotating(RotatingParams calldata p) external returns (address circle);

    /// @notice Operator: clone, register and initialize an accumulation circle.
    /// @param p The accumulation circle's terms and members.
    /// @return circle The new circle (equal to `predictAddress(p.config.circleId, CircleMode.Accumulation)`).
    function createAccumulation(AccumulationParams calldata p) external returns (address circle);

    /// @notice The deterministic address of the circle for `circleId` in `mode`.
    /// @param circleId The backend circle id.
    /// @param mode The circle flavour.
    /// @return The CREATE2 address (salt `keccak256(abi.encode(circleId))`, deployer this factory).
    function predictAddress(bytes32 circleId, CircleMode mode) external view returns (address);
}
