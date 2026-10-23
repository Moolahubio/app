// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IUSDC } from "./interfaces/IUSDC.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "./interfaces/IVaultV2.sol";
import { MHCircleConstants as K } from "./MHCircleConstants.sol";

/// @title MHCircleRegistry
/// @notice Global circle configuration. Owned (two-step) by the Gov Timelock, which fixes the one-step `setOwner`
///         of the Base plan (R5). Restrict fast, loosen slow:
///         - owner (Timelock, 48h): `setOperator`, `setGuardian`, `setTreasury`, `allowVault`, `unpauseCreation`;
///         - Guardian (no delay): `pauseCreation`, `disallowVault`.
///         Nothing here can move funds. Live circles read `guardian()` and `treasury()` at call time.
contract MHCircleRegistry is IMHCircleRegistry, Ownable2Step {
    /// @inheritdoc IMHCircleRegistry
    IUSDC public immutable USDC;

    /// @inheritdoc IMHCircleRegistry
    address public operator;
    /// @inheritdoc IMHCircleRegistry
    address public guardian;
    /// @inheritdoc IMHCircleRegistry
    address public treasury;
    /// @inheritdoc IMHCircleRegistry
    bool public creationPaused;
    /// @inheritdoc IMHCircleRegistry
    mapping(address vault => bool allowed) public isAllowedVault;
    /// @inheritdoc IMHCircleRegistry
    mapping(address vault => bytes32 adapters) public adapterSetHash;

    /// @dev Gas forwarded to each adapter timelock view in the `allowVault` adapter walk (a Morpho adapter's view
    ///      costs a few thousand).
    uint256 private constant ADAPTER_READ_GAS = 50_000;
    /// @dev Gas that must be left before each adapter read, so the adapter gets all of `ADAPTER_READ_GAS` (63/64
    ///      rule) and a failed read is the adapter's fault, never the caller's (audit R2-07: nobody can delist an
    ///      honest vault by calling `revalidateVault` with too little gas).
    uint256 private constant ADAPTER_READ_MIN_GAS = 60_000;

    /// @param initialOwner The Gov Timelock. Never the deployer by default: it is an explicit argument.
    /// @param usdc USDC on this chain.
    /// @param initialOperator The operator hot key.
    /// @param initialGuardian The Guardian Safe.
    /// @param initialTreasury The Treasury Safe.
    constructor(
        address initialOwner,
        IUSDC usdc,
        address initialOperator,
        address initialGuardian,
        address initialTreasury
    ) Ownable(initialOwner) {
        if (address(usdc) == address(0)) revert ZeroAddress();
        _checkRoles(initialOperator, initialGuardian, initialTreasury);
        USDC = usdc;
        operator = initialOperator;
        guardian = initialGuardian;
        treasury = initialTreasury;
        emit OperatorSet(address(0), initialOperator);
        emit GuardianSet(address(0), initialGuardian);
        emit TreasurySet(address(0), initialTreasury);
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // ---------------------------------------------------------------- Owner (Timelock)

    /// @inheritdoc IMHCircleRegistry
    function setOperator(address newOperator) external onlyOwner {
        _checkRoles(newOperator, guardian, treasury);
        emit OperatorSet(operator, newOperator);
        operator = newOperator;
    }

    /// @inheritdoc IMHCircleRegistry
    function setGuardian(address newGuardian) external onlyOwner {
        _checkRoles(operator, newGuardian, treasury);
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @inheritdoc IMHCircleRegistry
    function setTreasury(address newTreasury) external onlyOwner {
        _checkRoles(operator, guardian, newTreasury);
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @inheritdoc IMHCircleRegistry
    /// @dev Spec §4.3 checks (extended in audit round 1, R1-04), against Morpho Vault V2 semantics:
    ///      1. `asset() == USDC`;
    ///      2. the receiveAssets, receiveShares and sendShares gates are address(0) and their setters abdicated
    ///         (a non-zero abdicated gate would be a permanent third-party veto over exits);
    ///      3. `setIsAllocator`, `addAdapter`, `removeAdapter` and `setAdapterRegistry` are each abdicated or
    ///         timelocked for at least 7 days, and an adapter registry is set;
    ///      4. `increaseAbsoluteCap`, `increaseRelativeCap`, `setPerformanceFee`, `setManagementFee` and every
    ///         adapter's `burnShares` (at most 16 adapters, each exposing Morpho's adapter timelocks) are each
    ///         abdicated or timelocked for at least 3 days: the Guardian's reaction window.
    ///      The send-assets gate may stay live: it can block deposits but never exits. Records the adapter set
    ///      (`adapterSetHash`), which `vaultSafe` and `revalidateVault` then require unchanged (audit R2-07).
    ///      What these views cannot see (audit R2-01): a Vault V2 timelock bounds only data submitted after it was
    ///      set. Data submitted earlier (every timelock starts at 0) keeps its original `executableAt` forever and is
    ///      then executable by anyone, so a "sleeper" `setIsAllocator`, cap increase or `decreaseTimelock` defeats
    ///      every duration checked here. Pending data cannot be enumerated on chain (`executableAt` is keyed by the
    ///      full calldata), so the off-chain scan of every `Submit` of the vault and its adapters
    ///      (`script/CheckVaultPending.s.sol`: no data may still be pending) is a mandatory part of this check, run
    ///      before the proposal is scheduled and again right before it is executed. View functions can be spoofed,
    ///      so the 48h Timelock review of the vault's code is part of the check too.
    function allowVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        IVaultV2 v = IVaultV2(vault);
        bytes4 failed = _vaultCheck(v);
        if (failed != bytes4(0)) revert VaultCheckFailed(failed);
        isAllowedVault[vault] = true;
        adapterSetHash[vault] = _adapterSetHash(v);
        emit VaultAllowed(vault);
    }

    /// @inheritdoc IMHCircleRegistry
    function vaultSafe(address vault) external view returns (bool) {
        IVaultV2 v = IVaultV2(vault);
        // Audit 2 R1-10: the full check, adapter walk included. An adapter's own timelocks (its `burnShares`) can
        // drop while the adapter set stays the same; the bounded, fail-closed reads (audit R2-07) cannot revert on a
        // real Vault V2, so the walk is safe in a circle's `initialize` (live circles call `revalidateVault`, which
        // runs the same walk, in `deployIdle` and `pullFromVault`: closing review).
        return
            isAllowedVault[vault] && _adapterSetHash(v) == adapterSetHash[vault]
                && _vaultCheck(v) == bytes4(0);
    }

    /// @inheritdoc IMHCircleRegistry
    function revalidateVault(address vault) external returns (bool delisted) {
        if (!isAllowedVault[vault]) return false;
        IVaultV2 v = IVaultV2(vault);
        if (_adapterSetHash(v) == adapterSetHash[vault] && _vaultCheck(v) == bytes4(0)) return false;
        isAllowedVault[vault] = false;
        emit VaultDisallowed(vault);
        return true;
    }

    /// @inheritdoc IMHCircleRegistry
    function unpauseCreation() external onlyOwner {
        creationPaused = false;
        emit CreationUnpaused();
    }

    /// @notice Disabled: renouncing would freeze the operator, guardian and treasury forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- Guardian (restrict only)

    /// @inheritdoc IMHCircleRegistry
    function pauseCreation() external onlyGuardian {
        creationPaused = true;
        emit CreationPaused(msg.sender);
    }

    /// @inheritdoc IMHCircleRegistry
    function disallowVault(address vault) external onlyGuardian {
        isAllowedVault[vault] = false;
        emit VaultDisallowed(vault);
    }

    // ---------------------------------------------------------------- Internal

    /// @dev Every role is explicit, non-zero and distinct from the other two (spec non-negotiable 3).
    function _checkRoles(address operator_, address guardian_, address treasury_) private pure {
        if (operator_ == address(0) || guardian_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (operator_ == guardian_ || operator_ == treasury_ || guardian_ == treasury_) {
            revert RoleCollision();
        }
    }

    /// @dev The `allowVault` checks in order; returns the selector of the first one that fails, or 0. Every caller
    ///      (`allowVault`, `vaultSafe`, `revalidateVault`) runs all of them, adapter walk included (audit 2 R1-10).
    function _vaultCheck(IVaultV2 v) private view returns (bytes4) {
        if (v.asset() != address(USDC)) return IVaultV2.asset.selector;
        if (!_gateOk(v, v.receiveAssetsGate(), IVaultV2.setReceiveAssetsGate.selector)) {
            return IVaultV2.setReceiveAssetsGate.selector;
        }
        if (!_gateOk(v, v.receiveSharesGate(), IVaultV2.setReceiveSharesGate.selector)) {
            return IVaultV2.setReceiveSharesGate.selector;
        }
        if (!_gateOk(v, v.sendSharesGate(), IVaultV2.setSendSharesGate.selector)) {
            return IVaultV2.setSendSharesGate.selector;
        }
        bytes4[4] memory slow = [
            IVaultV2.setIsAllocator.selector,
            IVaultV2.addAdapter.selector,
            IVaultV2.removeAdapter.selector,
            IVaultV2.setAdapterRegistry.selector
        ];
        for (uint256 i; i < 4; ++i) {
            if (!_timelockOk(v.abdicated(slow[i]), v.timelock(slow[i]), K.MIN_VAULT_TIMELOCK)) {
                return slow[i];
            }
        }
        if (v.adapterRegistry() == address(0)) return IVaultV2.adapterRegistry.selector;
        bytes4[4] memory fast = [
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector
        ];
        for (uint256 i; i < 4; ++i) {
            if (!_timelockOk(v.abdicated(fast[i]), v.timelock(fast[i]), K.MIN_VAULT_EXPOSURE_TIMELOCK)) {
                return fast[i];
            }
        }
        uint256 n = v.adaptersLength();
        if (n > K.MAX_VAULT_ADAPTERS) return IVaultV2.adaptersLength.selector;
        bytes4 burn = IMorphoMarketV1AdapterV2.burnShares.selector;
        for (uint256 i; i < n; ++i) {
            if (!_adapterOk(v.adapters(i), burn)) return burn;
        }
        return bytes4(0);
    }

    /// @dev Whether adapter `a`'s `burnShares` is abdicated or timelocked for at least 3 days. Audit R2-07: each
    ///      view is read with a bounded static call and a revert, missing code or a short or malformed return counts
    ///      as a failed check (fail closed), so `revalidateVault` delists a vault whose adapter lacks Morpho's
    ///      timelock views instead of reverting and leaving it allowlisted.
    function _adapterOk(address a, bytes4 burn) private view returns (bool) {
        (bool ok, uint256 abdicated) = _read(a, abi.encodeCall(IMorphoMarketV1AdapterV2.abdicated, (burn)));
        if (!ok || abdicated > 1) return false;
        if (abdicated == 1) return true;
        uint256 duration;
        (ok, duration) = _read(a, abi.encodeCall(IMorphoMarketV1AdapterV2.timelock, (burn)));
        return ok && duration >= K.MIN_VAULT_EXPOSURE_TIMELOCK;
    }

    /// @dev Static call with `ADAPTER_READ_GAS` that reads one 32-byte word into scratch space (no unbounded
    ///      return-data copy). Reverts `InsufficientGas` unless enough gas is left for the callee to get all of it.
    function _read(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        if (gasleft() < ADAPTER_READ_MIN_GAS) revert InsufficientGas();
        assembly ("memory-safe") {
            ok := staticcall(ADAPTER_READ_GAS, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            word := mload(0x00)
        }
    }

    /// @dev keccak256 of the vault's adapter list, or 0 above `MAX_VAULT_ADAPTERS` (never a recorded value, since
    ///      `allowVault` refuses more than 16 adapters). Reads only the vault's own `adapters`/`adaptersLength`.
    function _adapterSetHash(IVaultV2 v) private view returns (bytes32) {
        uint256 n = v.adaptersLength();
        if (n > K.MAX_VAULT_ADAPTERS) return bytes32(0);
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = v.adapters(i);
        }
        return keccak256(abi.encodePacked(list));
    }

    function _gateOk(IVaultV2 v, address gate, bytes4 setter) private view returns (bool) {
        return gate == address(0) && v.abdicated(setter);
    }

    function _timelockOk(bool abdicated, uint256 duration, uint256 minimum) private pure returns (bool) {
        return abdicated || duration >= minimum;
    }
}
