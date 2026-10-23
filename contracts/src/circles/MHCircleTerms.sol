// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RotatingConfig, AccumulationConfig } from "./MHCircleTypes.sol";

/// @title MHCircleTerms
/// @notice The terms hash members sign on-chain by passing it to `join` (spec §4.2):
///         `termsHash = keccak256(abi.encode(block.chainid, address(this), params, members, securityBps))`.
/// @dev `params` is the scalar config struct (all value types, so it ABI-encodes inline). Accumulation circles
///      have no per-slot security, so they hash an empty `uint16[]` in that position to keep one formula.
///      The chain id and the clone address bind the hash to one circle on one chain.
library MHCircleTerms {
    /// @notice Terms hash of a rotating circle.
    /// @param chainId The chain id (block.chainid inside the circle).
    /// @param circle The circle clone address.
    /// @param config Scalar terms.
    /// @param members Members in payout order.
    /// @param securityBps Per-slot sigma in bps.
    /// @return The terms hash.
    function rotating(
        uint256 chainId,
        address circle,
        RotatingConfig memory config,
        address[] memory members,
        uint16[] memory securityBps
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, circle, config, members, securityBps));
    }

    /// @notice Terms hash of an accumulation circle (empty `securityBps`).
    /// @param chainId The chain id (block.chainid inside the circle).
    /// @param circle The circle clone address.
    /// @param config Scalar terms, including `vault` and `lockUntilMaturity`.
    /// @param members Members.
    /// @return The terms hash.
    function accumulation(
        uint256 chainId,
        address circle,
        AccumulationConfig memory config,
        address[] memory members
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, circle, config, members, new uint16[](0)));
    }
}
