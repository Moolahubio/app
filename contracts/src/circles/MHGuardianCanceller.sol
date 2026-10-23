// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IVaultV2 } from "./interfaces/IVaultV2.sol";

/// @notice The one OZ `TimelockController` (v5.1.0) function the canceller calls.
interface ITimelockCancel {
    /// @notice Cancels a pending operation. Requires `CANCELLER_ROLE`.
    function cancel(bytes32 id) external;
}

/// @title MHGuardianCanceller
/// @notice Holds `CANCELLER_ROLE` on the Gov Timelock on behalf of the Guardian Safe. The Guardian passes the full
///         operation; the canceller recomputes its id and cancels it, unless it is a rotation that replaces the
///         sitting Guardian (`REGISTRY.guardian()` at cancel time, `G`) with some `newG != G`:
///         - a single `registry.setGuardian(newG)`, or a single `canceller.setGuardian(G)` (completing a rotation
///           whose registry half already executed);
///         - a batch whose every call is `registry.setGuardian(newG)` (the last one sets `newG`),
///           `canceller.setGuardian(newG)`, the Earn wrapper's `setIsSentinel(newG, true)` or
///           `setIsSentinel(G, false)` (audit R2-14, narrowed in audit 2 R1-16).
///         So a compromised Guardian can veto anything except its own replacement, Gov cannot make an arbitrary change
///         uncancellable by bundling it with a rotation (a mixed operation stays cancellable), and Gov cannot strip
///         the veto, the sitting Guardian's sentinel powers or a third party's sentinel role without replacing the
///         Guardian (a no-op rotation to `G` protects nothing).
/// @dev Ids are recomputed locally with exactly the OZ v5.1.0 formulas:
///      single `schedule`:       keccak256(abi.encode(target, value, data, predecessor, salt))
///      batch  `scheduleBatch`:  keccak256(abi.encode(targets, values, payloads, predecessor, salt))
///      A one-call batch therefore has a different id from the same call scheduled singly, which is why there are
///      two entry points. Hashing locally (instead of calling the Timelock's pure helpers) copies the operation
///      into memory once, so cancelling stays cheaper than scheduling (tested: about 0.34M vs 1.04M execution gas
///      for a 200-call batch) and no operation is too expensive to cancel. Audit 2 R1-18: an operation's calldata
///      can still be too large for one transaction (Gov can schedule a payload of more than ~128 KB from a
///      DELEGATECALL helper without ever sending it); cancelling one needs a Guardian helper that rebuilds the
///      calldata on chain from the `CallScheduled` logs (runbook), and monitors alert on any large `CallScheduled`.
///      The rotation scan loops over the operation's own calls; it is deliberately not capped, because a cap
///      would let Gov schedule an uncancellable oversized batch. Its length is bounded by the gas of the
///      `scheduleBatch` transaction that created it (one event per call there, cheaper per call here).
///      Audit R1-20: the caller must be both this contract's `guardian` and `REGISTRY.guardian()`. A partial
///      rotation (only `registry.setGuardian` executed) therefore removes the replaced Guardian's veto at once,
///      failing closed until `canceller.setGuardian` executes too; the runbook rotates both in one batch.
contract MHGuardianCanceller is ReentrancyGuardTransient {
    /// @notice The caller is not the Guardian.
    error NotGuardian();
    /// @notice The caller is not the Timelock.
    error NotTimelock();
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice Every call in the operation is a rotation call; the Guardian cannot cancel its own rotation.
    error RotationOnly();
    /// @notice `targets`, `values` and `payloads` have different lengths.
    error LengthMismatch();

    /// @notice Emitted when the Guardian changes (only through the Timelock).
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    /// @notice Emitted when the Guardian cancels a Timelock operation through this contract.
    event OperationCancelled(bytes32 indexed id, address indexed guardian);

    /// @notice The Gov Timelock this contract cancels on.
    address public immutable TIMELOCK;
    /// @notice The circle registry whose `setGuardian` is a rotation call.
    address public immutable REGISTRY;
    /// @notice The Earn wrapper (Morpho Vault V2) whose `setIsSentinel` is a rotation call; address(0) if the
    ///         Timelock does not own a wrapper, in which case no `setIsSentinel` call is protected.
    address public immutable WRAPPER;

    /// @notice The Guardian Safe.
    address public guardian;

    /// @param timelock The OZ TimelockController (Gov Timelock).
    /// @param registry The circle registry (final address; may not have code yet under CREATE3 deployment).
    /// @param wrapper The Timelock-owned Earn wrapper, or address(0).
    /// @param initialGuardian The Guardian Safe.
    constructor(address timelock, address registry, address wrapper, address initialGuardian) {
        if (timelock == address(0) || registry == address(0) || initialGuardian == address(0)) {
            revert ZeroAddress();
        }
        TIMELOCK = timelock;
        REGISTRY = registry;
        WRAPPER = wrapper;
        guardian = initialGuardian;
        emit GuardianSet(address(0), initialGuardian);
    }

    /// @notice Guardian: cancel a pending operation that was scheduled with `TimelockController.schedule`.
    /// @dev Reverts with `RotationOnly` if the call is a rotation call, and bubbles the Timelock's revert if the
    ///      recomputed id is not pending.
    /// @param target The scheduled call's target.
    /// @param value The scheduled call's ETH value.
    /// @param data The scheduled call's calldata.
    /// @param predecessor The scheduled predecessor.
    /// @param salt The scheduled salt.
    /// @return id The cancelled operation id.
    function cancel(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        nonReentrant
        returns (bytes32 id)
    {
        _onlyGuardian();
        if (_isProtectedSingle(target, value, data)) revert RotationOnly();
        id = keccak256(abi.encode(target, value, data, predecessor, salt));
        emit OperationCancelled(id, msg.sender);
        ITimelockCancel(TIMELOCK).cancel(id);
    }

    /// @notice Guardian: cancel a pending operation that was scheduled with `TimelockController.scheduleBatch`.
    /// @dev Reverts with `RotationOnly` if every call is a rotation call (an empty batch is not rotation-only), and
    ///      bubbles the Timelock's revert if the recomputed id is not pending.
    /// @param targets The scheduled targets.
    /// @param values The scheduled ETH values.
    /// @param payloads The scheduled calldata.
    /// @param predecessor The scheduled predecessor.
    /// @param salt The scheduled salt.
    /// @return id The cancelled operation id.
    function cancelBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external nonReentrant returns (bytes32 id) {
        _onlyGuardian();
        if (isRotationOnly(targets, values, payloads)) revert RotationOnly();
        id = keccak256(abi.encode(targets, values, payloads, predecessor, salt));
        emit OperationCancelled(id, msg.sender);
        ITimelockCancel(TIMELOCK).cancel(id);
    }

    /// @notice Timelock: rotate the Guardian. Itself a rotation call, so the Guardian cannot cancel it.
    /// @param newGuardian The new Guardian Safe.
    function setGuardian(address newGuardian) external {
        if (msg.sender != TIMELOCK) revert NotTimelock();
        if (newGuardian == address(0)) revert ZeroAddress();
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @dev A single scheduled call the Guardian may not cancel: `registry.setGuardian(newG)` with `newG` not the
    ///      sitting Guardian, or `canceller.setGuardian(G)` with `G` the registry's Guardian (completing a partial
    ///      rotation). A single `setIsSentinel` never is (audit R2-14), and neither is a no-op or a
    ///      `canceller.setGuardian` to anyone else, which would strip the veto without replacing the Guardian (audit 2
    ///      R1-16).
    function _isProtectedSingle(address target, uint256 value, bytes calldata data)
        private
        view
        returns (bool)
    {
        if (
            !isRotationCall(target, value, data) || bytes4(data[:4]) != IMHCircleRegistry.setGuardian.selector
        ) {
            return false;
        }
        bool isCurrent = _arg(data, 4) == IMHCircleRegistry(REGISTRY).guardian();
        return target == REGISTRY ? !isCurrent : isCurrent;
    }

    /// @dev The address argument at `offset` (`isRotationCall` has checked it is a clean 20-byte word).
    function _arg(bytes calldata data, uint256 offset) private pure returns (address) {
        return address(uint160(uint256(bytes32(data[offset:offset + 32]))));
    }

    /// @dev The Guardian as both this contract and the registry know it (audit R1-20).
    function _onlyGuardian() private view {
        if (msg.sender != guardian || msg.sender != IMHCircleRegistry(REGISTRY).guardian()) {
            revert NotGuardian();
        }
    }

    /// @notice Whether a batch is a rotation the Guardian may not cancel: every call is a rotation call, the batch
    ///         replaces the sitting Guardian `G = REGISTRY.guardian()` by the last `REGISTRY.setGuardian(newG)` in it,
    ///         with `newG != G`, every `canceller.setGuardian(X)` has `X == newG`, and every `setIsSentinel(account,
    ///         on)` is `(newG, true)` or `(G, false)` (audit R2-14, narrowed in audit 2 R1-16). False for an empty
    ///         batch.
    /// @param targets The batch targets.
    /// @param values The batch ETH values.
    /// @param payloads The batch calldata.
    /// @return True when the Guardian may not cancel the batch.
    function isRotationOnly(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads)
        public
        view
        returns (bool)
    {
        uint256 n = targets.length;
        if (n != values.length || n != payloads.length) revert LengthMismatch();
        if (n == 0) return false;
        address current = IMHCircleRegistry(REGISTRY).guardian();
        address newGuardian = current;
        for (uint256 i; i < n; ++i) {
            if (!isRotationCall(targets[i], values[i], payloads[i])) return false;
            if (targets[i] == REGISTRY && bytes4(payloads[i][:4]) == IMHCircleRegistry.setGuardian.selector) {
                newGuardian = _arg(payloads[i], 4);
            }
        }
        // Audit 2 R1-16: only a real replacement of the sitting Guardian is protected.
        if (newGuardian == current) return false;
        for (uint256 i; i < n; ++i) {
            bytes calldata p = payloads[i];
            if (bytes4(p[:4]) == IMHCircleRegistry.setGuardian.selector) {
                // The canceller's half must name the same new Guardian as the registry's.
                if (targets[i] != REGISTRY && _arg(p, 4) != newGuardian) return false;
                continue;
            }
            // setIsSentinel(account, on), decoded by hand so a malformed word makes the batch cancellable instead
            // of reverting here. Only adding the new Guardian or removing the one being replaced is protected.
            uint256 on = uint256(bytes32(p[36:68]));
            if (on > 1) return false;
            if (_arg(p, 4) != (on == 1 ? newGuardian : current)) return false;
        }
        return true;
    }

    /// @notice Whether a single call has the shape of a rotation call: zero value, exact ABI length, a clean address
    ///         as first argument, and one of `REGISTRY.setGuardian(address)`, `this.setGuardian(address)` or
    ///         `WRAPPER.setIsSentinel(address,bool)`.
    /// @dev Anything that is not exactly one of these (extra calldata, ETH value, another target, dirty address
    ///      bits) is cancellable. Whether a call of this shape is protected depends on the Guardian it replaces
    ///      (`cancel`, `isRotationOnly`; audit R2-14, audit 2 R1-16).
    /// @param target The call target.
    /// @param value The call's ETH value.
    /// @param data The calldata.
    /// @return True for a rotation call.
    function isRotationCall(address target, uint256 value, bytes calldata data) public view returns (bool) {
        if (value != 0 || data.length < 36 || uint256(bytes32(data[4:36])) >> 160 != 0) return false;
        bytes4 selector = bytes4(data[:4]);
        if (selector == IMHCircleRegistry.setGuardian.selector) {
            return data.length == 36 && (target == REGISTRY || target == address(this));
        }
        if (selector == IVaultV2.setIsSentinel.selector) {
            return data.length == 68 && WRAPPER != address(0) && target == WRAPPER;
        }
        return false;
    }
}
