// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IUSDC } from "./IUSDC.sol";

/// @title IMHCircleRegistry
/// @notice Global configuration read by the circle factory and by every live circle. Owned (Ownable2Step) by the
///         Gov Timelock. The Guardian can only restrict: pause creation and disallow vaults.
interface IMHCircleRegistry {
    /// @notice The caller is not the Guardian.
    error NotGuardian();
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice Two of operator, guardian and treasury would be the same address.
    error RoleCollision();
    /// @notice The vault failed an `allowVault` check. `check` is the selector whose check failed: `asset`, a gate
    ///         setter (gate not zero or not abdicated), `setIsAllocator`, `addAdapter`, `removeAdapter` or
    ///         `setAdapterRegistry` (timelock below 7 days and not abdicated), `adapterRegistry` (none set),
    ///         `increaseAbsoluteCap`, `increaseRelativeCap`, `setPerformanceFee`, `setManagementFee` or an
    ///         adapter's `burnShares` (timelock below 3 days and not abdicated), or `adaptersLength` (more than 16).
    error VaultCheckFailed(bytes4 check);
    /// @notice Ownership cannot be renounced.
    error RenounceDisabled();
    /// @notice Too little gas left to read an adapter's timelock views (audit R2-07: a read that fails for lack of
    ///         gas must not count as a failed check).
    error InsufficientGas();

    /// @notice Emitted when the operator changes.
    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    /// @notice Emitted when the Guardian changes.
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    /// @notice Emitted when the treasury changes.
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);
    /// @notice Emitted when a vault is allowlisted for new accumulation circles.
    event VaultAllowed(address indexed vault);
    /// @notice Emitted when a vault is removed from the allowlist: no new circle can use it, and live circles stop
    ///         depositing into it (anyone may pull their vault shares home) until it is allowed again (audit 2 R1-09,
    ///         R2-01).
    event VaultDisallowed(address indexed vault);
    /// @notice Emitted when the Guardian pauses circle creation.
    event CreationPaused(address indexed guardian);
    /// @notice Emitted when the owner unpauses circle creation.
    event CreationUnpaused();

    /// @notice USDC on this chain (immutable).
    function USDC() external view returns (IUSDC);

    /// @notice Hot key allowed to create circles through the factory. It can never move funds.
    function operator() external view returns (address);

    /// @notice Guardian Safe: restrict-only powers here and bounded powers on circles.
    function guardian() external view returns (address);

    /// @notice Treasury Safe: receives fees, residual and donations only.
    function treasury() external view returns (address);

    /// @notice Whether the factory refuses to create circles.
    function creationPaused() external view returns (bool);

    /// @notice Whether a Morpho Vault V2 may back new accumulation circles.
    /// @param vault The vault to check.
    function isAllowedVault(address vault) external view returns (bool);

    /// @notice keccak256 of the vault's adapter list recorded by `allowVault` (audit R2-07; 0 if never allowed).
    /// @param vault The vault.
    function adapterSetHash(address vault) external view returns (bytes32);

    /// @notice Whether `vault` is allowlisted and still passes, live, every `allowVault` check (audit R1-12: the
    ///         allowlist alone is a snapshot), including each adapter's `burnShares` timelock (audit 2 R1-10), with the
    ///         adapter set it was allowlisted with (audit R2-07: a newly added adapter starts with every timelock at
    ///         0, so any adapter change needs a new `allowVault`, with its off-chain pending-submission scan).
    ///         Accumulation circles read this when created. Live circles call `revalidateVault` instead on every
    ///         `deployIdle` and `pullFromVault` (closing review), so a failing vault is delisted and only a new
    ///         `allowVault` re-enables deposits; nothing is latched in the circle, so a vault allowed again is used
    ///         again (audit 2 R1-09, R2-01). Adapter views are read with bounded static calls that fail
    ///         closed, so it never reverts for a real Vault V2 (only `InsufficientGas` when called with too little
    ///         gas).
    /// @param vault The vault to check.
    function vaultSafe(address vault) external view returns (bool);

    /// @notice Anyone: delists an allowlisted vault that no longer passes the full `allowVault` checks (for
    ///         example after its curator shortened a timelock) or whose adapter set changed since `allowVault`. An
    ///         adapter without Morpho's timelock views fails the check (audit R2-07), so this delists rather than
    ///         reverts. Same effect as `disallowVault` (see `VaultDisallowed`). Pending ("sleeper") submissions are
    ///         invisible here (audit R2-01); the Guardian's monitor scans for them and calls `disallowVault`. Called by
    ///         accumulation circles on every `deployIdle` and `pullFromVault` (closing review), so the delisting
    ///         sticks even if the curator later restores the checked state.
    /// @param vault The vault to re-check.
    /// @return delisted Whether the vault was removed from the allowlist.
    function revalidateVault(address vault) external returns (bool delisted);

    /// @notice Owner: set the operator.
    /// @param newOperator Non-zero and distinct from the guardian and the treasury.
    function setOperator(address newOperator) external;

    /// @notice Owner: set the Guardian. A rotation call that the Guardian canceller refuses to cancel.
    /// @param newGuardian Non-zero and distinct from the operator and the treasury.
    function setGuardian(address newGuardian) external;

    /// @notice Owner: set the treasury.
    /// @param newTreasury Non-zero and distinct from the operator and the guardian.
    function setTreasury(address newTreasury) external;

    /// @notice Owner: allowlist a Morpho Vault V2 after the on-chain checks of spec §4.3.
    /// @param vault The Vault V2 to allow for new accumulation circles.
    function allowVault(address vault) external;

    /// @notice Owner: resume circle creation.
    function unpauseCreation() external;

    /// @notice Guardian: stop circle creation.
    function pauseCreation() external;

    /// @notice Guardian: remove a vault from the allowlist. No new circle can use it, and live circles pause deposits
    ///         into it (anyone may pull their shares home) until Gov allows it again (audit 2 R1-09, R2-01).
    /// @param vault The vault to disallow.
    function disallowVault(address vault) external;
}
