// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MHCircleConstants
/// @notice Hard bounds for Moolahub circles (build spec v3 §4.1 table). They live in bytecode: nobody,
///         including governance, can change them. Amounts are USDC base units (6 decimals).
library MHCircleConstants {
    /// @notice Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Maximum members per circle (the product caps at 20; every loop is bounded by this).
    uint256 internal constant MAX_MEMBERS = 50;
    /// @notice Minimum members per circle. Not in the §4.1 table: a one-member circle is degenerate.
    uint256 internal constant MIN_MEMBERS = 2;
    /// @notice Maximum number of rounds.
    uint256 internal constant MAX_ROUNDS = 520;

    /// @notice Rotating fee cap: at most 200 bps of the gross pot, charged only on a successful settlement.
    uint256 internal constant MAX_ROTATING_FEE_BPS = 200;
    /// @notice Accumulation fee cap: at most 1,500 bps of positive earnings.
    uint256 internal constant MAX_ACCUMULATION_FEE_BPS = 1_500;

    /// @notice Lower bound of the per-slot security ratio sigma.
    uint256 internal constant MIN_SECURITY_BPS = 5_000;
    /// @notice Upper bound of the per-slot security ratio sigma (100%, the default policy).
    uint256 internal constant MAX_SECURITY_BPS = 10_000;

    /// @notice Shortest round (R6: a round can never be shorter than grace).
    uint256 internal constant MIN_ROUND = 7 days;
    /// @notice Longest round.
    uint256 internal constant MAX_ROUND = 92 days;
    /// @notice Minimum grace period; grace must also be strictly shorter than a round.
    uint256 internal constant MIN_GRACE = 48 hours;
    /// @notice Minimum cure period after grace before a circle can be stalled.
    uint256 internal constant MIN_CURE = 72 hours;
    /// @notice Maximum cure period. Not in the §4.1 table: without it a huge `cure` would make a stalled circle
    ///         uncancellable forever, breaking the §4.7 liveness invariant (a permissionless path to a claim).
    uint256 internal constant MAX_CURE = 30 days;
    /// @notice Longest join window.
    uint256 internal constant MAX_JOIN_WINDOW = 30 days;
    /// @notice Latest `plannedStart` after `joinDeadline`. Not in the §4.1 table: bounds how long joined
    ///         collateral can sit in an Active circle before round 1 opens (liveness).
    uint256 internal constant MAX_START_DELAY = 30 days;

    /// @notice Largest per-round contribution. Not in the §4.1 table and not a product limit (USDC's total supply
    ///         is far below it); it keeps every `sigma · rounds · contribution` product overflow-free so no
    ///         arithmetic can brick a circle.
    uint256 internal constant MAX_CONTRIBUTION = type(uint64).max;

    /// @notice Guardian deadline extension: at most this much per call.
    uint256 internal constant MAX_EXTENSION_PER_CALL = 7 days;
    /// @notice Guardian deadline extension: at most this much in total per circle.
    uint256 internal constant MAX_EXTENSION_TOTAL = 30 days;

    /// @notice Minimum contribution ($1).
    uint256 internal constant MIN_CONTRIBUTION = 1e6;
    /// @notice One US cent in USDC base units; contributions are whole cents so they match the ledger.
    uint256 internal constant CENT = 1e4;
    /// @notice Virtual shares used by the accumulation pool's share conversion (inflation-attack offset).
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @notice Smallest idle balance `deployIdle()` will move into the vault.
    uint256 internal constant MIN_DEPLOY = 1e6;

    /// @notice Minimum Vault V2 timelock (or abdication) checked by `allowVault` (§4.3) for the curator powers
    ///         that change who allocates or where funds can go: `setIsAllocator`, `addAdapter`, `removeAdapter`
    ///         (an instant write-down: no allocation check) and `setAdapterRegistry`.
    uint256 internal constant MIN_VAULT_TIMELOCK = 7 days;
    /// @notice Minimum Vault V2 timelock (or abdication) for the curator powers that expose or write down depositor
    ///         assets within the existing adapters: `increaseAbsoluteCap`, `increaseRelativeCap`,
    ///         `setPerformanceFee`, `setManagementFee`, and each market adapter's `burnShares` (audit R1-04). This
    ///         is the Guardian's real reaction window (Gauntlet USDC Prime: 3 days); not in the §4.1 table.
    uint256 internal constant MIN_VAULT_EXPOSURE_TIMELOCK = 3 days;
    /// @notice Most adapters `allowVault` will walk (bounds the check's gas). Not in the §4.1 table.
    uint256 internal constant MAX_VAULT_ADAPTERS = 16;
    /// @notice Accumulation `cancelExpired`: how long after the vault last valued the circle's shares (`lastLive`)
    ///         anyone may cancel an Active or Matured circle whose vault still cannot value them into NAV-free claims
    ///         (audit R2-09, spec §4.7 invariant 7: a permissionless path to a claim from every state; audit 2 R1-07:
    ///         measured from the outage, not from the end of the schedule). A healthy circle refreshes `lastLive` on
    ///         every contribution, exit, flag, finalize and settlement, and is never cancellable this way (audit 2
    ///         R1-05/R1-06). Not in the §4.1 table.
    uint256 internal constant EXPIRY_DELAY = 90 days;
    /// @notice Gas given to the `previewRedeem` probe of accumulation `cancelExpired` (audit 2 R1-05/R1-06): far above
    ///         what a Vault V2 with the 16 adapters `allowVault` accepts needs to value shares, so only a vault that
    ///         cannot value them fails it. Not in the §4.1 table.
    uint256 internal constant NAV_PROBE_GAS = 3_000_000;
    /// @notice Gas that must be left before the probe, so it gets all of `NAV_PROBE_GAS` (63/64 rule) and a failed
    ///         probe is the vault's fault, never the caller's.
    uint256 internal constant NAV_PROBE_MIN_GAS = 3_100_000;
}
