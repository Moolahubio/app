// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Circle flavour. Selects the implementation the factory clones.
enum CircleMode {
    Rotating,
    Accumulation
}

/// @notice Circle lifecycle (spec §4.2). Rotating: Pending → Active → Completed | Cancelled.
///         Accumulation: Pending → Active → Matured → Closed | Cancelled.
enum CircleStatus {
    Pending,
    Active,
    Completed,
    Matured,
    Closed,
    Cancelled
}

/// @notice Scalar terms of a rotating circle. Hashed into `termsHash` together with `members` and `securityBps`.
/// @param circleId Backend circle id; also the CREATE2 salt input (`keccak256(abi.encode(circleId))`).
/// @param contribution Per-round contribution in USDC base units (whole cents, ≥ $1).
/// @param feeBps Fee on the gross pot, charged only on a successful settlement (≤ 200).
/// @param roundDuration Seconds per round (7–92 days).
/// @param grace Seconds after a round's deadline before a payment is late (≥ 48h, < roundDuration).
/// @param cure Seconds after grace before a stalled circle can be cancelled (≥ 72h).
/// @param joinDeadline Last timestamp at which a member can join (≤ 30 days after creation).
/// @param plannedStart Earliest start; the last join sets `startTime = max(now, plannedStart)`.
/// @param totalRounds Number of rounds; must equal the member count.
struct RotatingConfig {
    bytes32 circleId;
    uint256 contribution;
    uint16 feeBps;
    uint64 roundDuration;
    uint64 grace;
    uint64 cure;
    uint64 joinDeadline;
    uint64 plannedStart;
    uint32 totalRounds;
}

/// @notice `initialize` payload for a rotating circle.
/// @param config Scalar terms.
/// @param members Members in payout order (slot k = index k-1); unique and non-zero.
/// @param securityBps Per-slot security ratio sigma in bps (5,000–10,000), one per member.
struct RotatingParams {
    RotatingConfig config;
    address[] members;
    uint16[] securityBps;
}

/// @notice Scalar terms of an accumulation circle. Hashed into `termsHash` together with `members`.
/// @param circleId Backend circle id; also the CREATE2 salt input (`keccak256(abi.encode(circleId))`).
/// @param contribution Per-round contribution in USDC base units (whole cents, ≥ $1).
/// @param feeBps Fee on positive earnings, charged only at settlement (≤ 1,500).
/// @param roundDuration Seconds per round (7–92 days).
/// @param grace Seconds after a round's deadline before a payment is late (≥ 48h, < roundDuration).
/// @param cure Seconds of cure (≥ 72h).
/// @param joinDeadline Last timestamp at which a member can join (≤ 30 days after creation).
/// @param plannedStart Earliest start; the last join sets `startTime = max(now, plannedStart)`.
/// @param totalRounds Number of rounds (≤ 520).
/// @param vault Morpho Vault V2 allowlisted in the registry, or address(0) for no yield.
/// @param lockUntilMaturity When true, `exitEarly` is disabled.
struct AccumulationConfig {
    bytes32 circleId;
    uint256 contribution;
    uint16 feeBps;
    uint64 roundDuration;
    uint64 grace;
    uint64 cure;
    uint64 joinDeadline;
    uint64 plannedStart;
    uint32 totalRounds;
    address vault;
    bool lockUntilMaturity;
}

/// @notice `initialize` payload for an accumulation circle.
/// @param config Scalar terms.
/// @param members Members (unique and non-zero).
struct AccumulationParams {
    AccumulationConfig config;
    address[] members;
}
