// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IVaultV2 (vendored subset)
/// @notice Minimal subset of Morpho Vault V2 used by Moolahub circles. Every signature is copied verbatim from
///         morpho-org/vault-v2 `src/interfaces/IVaultV2.sol` and `src/interfaces/IERC4626.sol`
///         (main @ abaae813e754218061e7326e37487df718edd576, fetched 2026-10-22; the audit round 1 additions were
///         re-fetched from the same commit, and audit 2's `isAdapter`/`forceDeallocate` match the vendored copy in
///         `test/vendor/vaultv2/interfaces/IVaultV2.sol`). Nothing is added or renamed.
/// @dev Semantics relied on (VaultV2.sol @ same commit):
///      - `abdicated(selector)`: once true, the timelocked function can never execute again (`timelocked()`).
///      - `timelock(selector)`: the delay `submit` applies to data submitted from now on: it fixes
///        `executableAt[data] = now + timelock` once. `decreaseTimelock(s, d)` data takes the target selector's
///        timelock at submit time. Audit R2-01: a timelock bounds ONLY data submitted after it was set. Data
///        submitted while it was shorter (every Vault V2 and every adapter starts with all timelocks at 0) keeps its
///        original `executableAt` after the timelock is raised, stays executable until executed or revoked (no
///        expiry), and anyone can execute it once matured (`timelocked()` re-checks only `abdicated`). So a 7-day
///        timelock does not mean "the next change takes 7 days" unless no data is pending; only abdication
///        neutralises pending data. `executableAt(data)` is public but keyed by the full calldata, so pending data
///        can only be found from the `Submit` logs (`script/CheckVaultPending.s.sol`).
///      - Gates: address(0) disables a gate.
///      - `maxRedeem`/`maxWithdraw` always return 0, so circles never call `max*`.
///      View functions can be spoofed by a malicious contract, so `allowVault` also needs human review.
interface IVaultV2 is IERC20 {
    // ---------------------------------------------------------------- ERC-4626 (Morpho flavour)

    /// @notice The underlying asset.
    function asset() external view returns (address);

    /// @notice Total assets under management.
    function totalAssets() external view returns (uint256);

    /// @notice Shares worth `assets` at the current price, rounded down.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Assets worth `shares` at the current price, rounded down.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Deposits `assets` and mints shares to `onBehalf`.
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);

    /// @notice Burns shares of `onBehalf` and sends exactly `assets` to `receiver`.
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares);

    /// @notice Burns exactly `shares` of `onBehalf` and sends the assets to `receiver`.
    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets);

    /// @notice Shares burned by `withdraw(assets)`, rounded up.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);

    /// @notice Assets returned by `redeem(shares)`, rounded down.
    function previewRedeem(uint256 shares) external view returns (uint256 assets);

    // ---------------------------------------------------------------- Gates

    /// @notice Gate on receiving shares (address(0) = disabled).
    function receiveSharesGate() external view returns (address);

    /// @notice Gate on sending shares (address(0) = disabled).
    function sendSharesGate() external view returns (address);

    /// @notice Gate on receiving assets on withdraw/redeem (address(0) = disabled).
    function receiveAssetsGate() external view returns (address);

    /// @notice Gate on sending assets on deposit/mint (address(0) = disabled).
    function sendAssetsGate() external view returns (address);

    // ---------------------------------------------------------------- Timelocks and abdication

    /// @notice Timelock duration of a curator function, keyed by selector.
    function timelock(bytes4 selector) external view returns (uint256);

    /// @notice Whether a curator function has been permanently disabled.
    function abdicated(bytes4 selector) external view returns (bool);

    // ---------------------------------------------------------------- Adapters

    /// @notice The registry new adapters must belong to (address(0) = any adapter may be added).
    function adapterRegistry() external view returns (address);

    /// @notice The adapter at `index`.
    function adapters(uint256 index) external view returns (address);

    /// @notice Number of adapters.
    function adaptersLength() external view returns (uint256);

    /// @notice Whether `account` is one of the vault's adapters (audit 2 R1-01).
    function isAdapter(address account) external view returns (bool);

    /// @notice Anyone: deallocates `assets` from `adapter` (with `data`) into the vault's idle assets, taking a
    ///         penalty of `assets · forceDeallocatePenalty[adapter]` (at most 2%) from `onBehalf` as a withdrawal
    ///         whose assets stay in the vault. No allowance is needed when `msg.sender == onBehalf` (audit 2 R1-01).
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares);

    // ---------------------------------------------------------------- Selectors referenced by Moolahub

    /// @notice Owner function: grant or revoke the sentinel role (immediate, not timelocked).
    function setIsSentinel(address account, bool isSentinel) external;

    /// @notice Curator function (timelocked): grant or revoke the allocator role.
    function setIsAllocator(address account, bool newIsAllocator) external;

    /// @notice Curator function (timelocked): set the receive-shares gate.
    function setReceiveSharesGate(address newReceiveSharesGate) external;

    /// @notice Curator function (timelocked): set the send-shares gate.
    function setSendSharesGate(address newSendSharesGate) external;

    /// @notice Curator function (timelocked): set the receive-assets gate.
    function setReceiveAssetsGate(address newReceiveAssetsGate) external;

    /// @notice Curator function (timelocked): add an adapter.
    function addAdapter(address account) external;

    /// @notice Curator function (timelocked): remove an adapter. No allocation check: its assets stop counting.
    function removeAdapter(address account) external;

    /// @notice Curator function (timelocked): set the adapter registry.
    function setAdapterRegistry(address newAdapterRegistry) external;

    /// @notice Curator function (timelocked): raise an id's absolute allocation cap.
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;

    /// @notice Curator function (timelocked): raise an id's relative allocation cap.
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;

    /// @notice Curator function (timelocked): set the performance fee.
    function setPerformanceFee(uint256 newPerformanceFee) external;

    /// @notice Curator function (timelocked): set the management fee (charged on total assets).
    function setManagementFee(uint256 newManagementFee) external;
}

/// @title IMorphoMarketV1AdapterV2 (vendored subset)
/// @notice The curator-timelocked surface of Morpho's market adapter checked by `allowVault`. Signatures copied
///         verbatim from morpho-org/vault-v2 `src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol` (same commit).
/// @dev `burnShares(marketId)` zeroes the adapter's supply shares in a market (a write-down of vault assets).
interface IMorphoMarketV1AdapterV2 {
    /// @notice Timelock duration of an adapter curator function, keyed by selector.
    function timelock(bytes4 selector) external view returns (uint256);

    /// @notice Whether an adapter curator function has been permanently disabled.
    function abdicated(bytes4 selector) external view returns (bool);

    /// @notice Curator function (timelocked): burns the adapter's supply shares in `marketId`.
    function burnShares(bytes32 marketId) external;
}
