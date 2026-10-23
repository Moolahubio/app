// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";

contract MHGuardianCancellerTest is CircleFixture {
    address internal newGuardian = makeAddr("guardianSafe2");

    // ---------------------------------------------------------------- Timelock configuration (spec §5)

    function test_timelockConfig_matchesSpec() public view {
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        assertEq(timelock.getMinDelay(), 48 hours);
        // Admin renounced: the Timelock is its own only admin.
        assertTrue(timelock.hasRole(admin, address(timelock)));
        assertFalse(timelock.hasRole(admin, gov));
        assertFalse(timelock.hasRole(admin, address(this)));
        // Gov proposes, executes and cancels; the canceller only cancels; the Guardian Safe holds no role directly.
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), gov));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(canceller)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(canceller)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(canceller)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
        // Wiring.
        assertEq(canceller.TIMELOCK(), address(timelock));
        assertEq(canceller.REGISTRY(), address(registry));
        assertEq(canceller.WRAPPER(), address(wrapper));
        assertEq(canceller.guardian(), guardian);
        assertEq(registry.owner(), address(timelock));
        assertEq(reputation.owner(), address(timelock));
    }

    function test_constructor_revertsOnZero_wrapperOptional() public {
        vm.expectRevert(MHGuardianCanceller.ZeroAddress.selector);
        new MHGuardianCanceller(address(0), address(registry), address(wrapper), guardian);
        vm.expectRevert(MHGuardianCanceller.ZeroAddress.selector);
        new MHGuardianCanceller(address(timelock), address(0), address(wrapper), guardian);
        vm.expectRevert(MHGuardianCanceller.ZeroAddress.selector);
        new MHGuardianCanceller(address(timelock), address(registry), address(wrapper), address(0));
        MHGuardianCanceller c =
            new MHGuardianCanceller(address(timelock), address(registry), address(0), guardian);
        assertEq(c.WRAPPER(), address(0));
    }

    // ---------------------------------------------------------------- Cancelling ordinary operations

    function test_cancel_singleOperation() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(registry), 0, data, salt);

        vm.expectEmit(true, true, false, false, address(canceller));
        emit MHGuardianCanceller.OperationCancelled(id, guardian);
        vm.expectEmit(true, false, false, false, address(timelock));
        emit TimelockController.Cancelled(id);
        vm.prank(guardian);
        bytes32 got = canceller.cancel(address(registry), 0, data, bytes32(0), salt);

        assertEq(got, id, "recomputed id == hashOperation");
        assertFalse(timelock.isOperation(id));
        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        vm.expectRevert();
        timelock.execute(address(registry), 0, data, bytes32(0), salt);
        assertEq(registry.treasury(), treasury);
    }

    function test_cancel_batchOperation() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        t[1] = address(registry);
        p[1] = abi.encodeCall(IMHCircleRegistry.setOperator, (attacker));
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t, v, p, salt);

        vm.prank(guardian);
        bytes32 got = canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertEq(got, id, "recomputed id == hashOperationBatch");
        assertFalse(timelock.isOperation(id));
    }

    function test_cancel_withPredecessor() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.unpauseCreation, ());
        bytes32 pred = keccak256("pred");
        bytes32 salt = _nextSalt();
        vm.prank(gov);
        timelock.schedule(address(registry), 0, data, pred, salt, DELAY);
        bytes32 id = timelock.hashOperation(address(registry), 0, data, pred, salt);
        vm.prank(guardian);
        assertEq(canceller.cancel(address(registry), 0, data, pred, salt), id);
        assertFalse(timelock.isOperation(id));
    }

    /// @dev A single `schedule` and a one-call `scheduleBatch` of the same call have different ids; each entry
    ///      point uses the matching hash, so the wrong one cannot cancel.
    function test_cancel_singleVsBatchHashing() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 salt = _nextSalt();
        bytes32 singleId = _schedule(address(registry), 0, data, salt);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(1);
        t[0] = address(registry);
        p[0] = data;
        bytes32 batchId = timelock.hashOperationBatch(t, v, p, bytes32(0), salt);
        assertTrue(singleId != batchId);

        // The batch entry point computes batchId, which is not pending.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, batchId, _pendingBitmap()
            )
        );
        canceller.cancelBatch(t, v, p, bytes32(0), salt);

        // Schedule the one-call batch too: now each entry point cancels exactly its own operation.
        _scheduleBatch(t, v, p, salt);
        vm.prank(guardian);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);
        assertFalse(timelock.isOperation(singleId));
        assertTrue(timelock.isOperationPending(batchId));
        vm.prank(guardian);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertFalse(timelock.isOperation(batchId));
    }

    function test_cancel_unknownOperationBubblesTimelockError() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 id = timelock.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, _pendingBitmap()
            )
        );
        canceller.cancel(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    function test_cancel_onlyGuardian() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 salt = _nextSalt();
        _schedule(address(registry), 0, data, salt);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(1);
        t[0] = address(registry);
        p[0] = data;

        address[5] memory callers = [attacker, gov, operator, treasury, address(timelock)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(MHGuardianCanceller.NotGuardian.selector);
            canceller.cancel(address(registry), 0, data, bytes32(0), salt);
            vm.prank(callers[i]);
            vm.expectRevert(MHGuardianCanceller.NotGuardian.selector);
            canceller.cancelBatch(t, v, p, bytes32(0), salt);
        }
    }

    function test_cancelBatch_lengthMismatch() public {
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](1);
        bytes[] memory p = new bytes[](2);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.LengthMismatch.selector);
        canceller.cancelBatch(t, v, p, bytes32(0), bytes32(0));
    }

    function test_cancelBatch_emptyBatchIsCancellable() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(0);
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t, v, p, salt);
        vm.prank(guardian);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    // ---------------------------------------------------------------- Rotation-only operations cannot be cancelled

    function test_rotationOnly_singleRegistrySetGuardian() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(registry), 0, data, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id));
    }

    /// @dev Audit 2 R1-16: a lone `canceller.setGuardian(X)` is protected only when X is the registry's Guardian
    ///      (completing a rotation whose registry half executed); to anyone else it would strip the veto without
    ///      replacing the Guardian, so the sitting Guardian can cancel it.
    function test_rotationOnly_singleCancellerSetGuardian() public {
        bytes memory data = abi.encodeCall(MHGuardianCanceller.setGuardian, (guardian));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(canceller), 0, data, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancel(address(canceller), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id));

        data = abi.encodeCall(MHGuardianCanceller.setGuardian, (newGuardian));
        salt = _nextSalt();
        id = _schedule(address(canceller), 0, data, salt);
        vm.prank(guardian);
        canceller.cancel(address(canceller), 0, data, bytes32(0), salt);
        assertFalse(timelock.isOperation(id), "a lone veto removal is cancellable");
    }

    /// @dev Audit R2-14 (was: a single `setIsSentinel` was uncancellable): a sentinel change that does not replace
    ///      the Guardian is not a rotation, so the sitting Guardian can cancel `setIsSentinel(guardian, false)`.
    function test_singleWrapperSetIsSentinel_isCancellable_R2_14() public {
        bytes memory data = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(wrapper), 0, data, salt);
        assertTrue(canceller.isRotationCall(address(wrapper), 0, data), "rotation shape");
        vm.prank(guardian);
        canceller.cancel(address(wrapper), 0, data, bytes32(0), salt);
        assertFalse(timelock.isOperation(id), "cancelled");
    }

    /// @dev The full rotation (registry, canceller, wrapper sentinel out/in) is one uncancellable batch, and once
    ///      executed the old Guardian has lost every power.
    function test_rotationOnly_fullRotationBatch_cannotBeCancelled_thenExecutes() public {
        vm.prank(address(timelock));
        wrapper.setIsSentinel(guardian, true);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _rotationBatch();
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t, v, p, salt);

        assertTrue(canceller.isRotationOnly(t, v, p));
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id));

        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        timelock.executeBatch(t, v, p, bytes32(0), salt);

        assertEq(registry.guardian(), newGuardian);
        assertEq(canceller.guardian(), newGuardian);
        assertFalse(wrapper.isSentinel(guardian));
        assertTrue(wrapper.isSentinel(newGuardian));

        // Old Guardian is out everywhere; the new one is in.
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 s2 = _nextSalt();
        _schedule(address(registry), 0, data, s2);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.NotGuardian.selector);
        canceller.cancel(address(registry), 0, data, bytes32(0), s2);
        vm.prank(guardian);
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.pauseCreation();
        vm.prank(newGuardian);
        canceller.cancel(address(registry), 0, data, bytes32(0), s2);
    }

    /// @dev Gov cannot shelter an arbitrary change by bundling it with a rotation call.
    function test_mixedOperation_canBeCancelled() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        t[1] = address(registry);
        p[1] = abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker));
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t, v, p, salt);

        assertFalse(canceller.isRotationOnly(t, v, p));
        vm.prank(guardian);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    function test_mixedOperation_rotationPlusCancellerRemoval_canBeCancelled() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _rotationBatch();
        address[] memory t2 = new address[](t.length + 1);
        uint256[] memory v2 = new uint256[](t.length + 1);
        bytes[] memory p2 = new bytes[](t.length + 1);
        for (uint256 i; i < t.length; ++i) {
            (t2[i], v2[i], p2[i]) = (t[i], v[i], p[i]);
        }
        t2[t.length] = address(timelock);
        p2[t.length] =
            abi.encodeCall(IAccessControl.revokeRole, (timelock.CANCELLER_ROLE(), address(canceller)));
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t2, v2, p2, salt);
        vm.prank(guardian);
        canceller.cancelBatch(t2, v2, p2, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    function test_cancellerRoleRevocation_isCancellable() public {
        bytes memory data =
            abi.encodeCall(IAccessControl.revokeRole, (timelock.CANCELLER_ROLE(), address(canceller)));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(timelock), 0, data, salt);
        vm.prank(guardian);
        canceller.cancel(address(timelock), 0, data, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    function test_nearRotationCalls_areCancellable() public {
        bytes memory rot = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));

        // ETH value attached.
        assertFalse(canceller.isRotationCall(address(registry), 1, rot));
        // Extra calldata appended.
        assertFalse(canceller.isRotationCall(address(registry), 0, abi.encodePacked(rot, uint256(1))));
        // Truncated calldata.
        assertFalse(
            canceller.isRotationCall(
                address(registry), 0, abi.encodeWithSelector(IMHCircleRegistry.setGuardian.selector)
            )
        );
        assertFalse(canceller.isRotationCall(address(registry), 0, ""));
        // Same selector on another target.
        assertFalse(canceller.isRotationCall(address(reputation), 0, rot));
        assertFalse(canceller.isRotationCall(address(wrapper), 0, rot));
        // setIsSentinel on a target that is not the wrapper.
        bytes memory sent = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        assertFalse(canceller.isRotationCall(address(registry), 0, sent));
        assertFalse(canceller.isRotationCall(makeAddr("otherVault"), 0, sent));
        // Exact rotation calls.
        assertTrue(canceller.isRotationCall(address(registry), 0, rot));
        assertTrue(canceller.isRotationCall(address(canceller), 0, rot));
        assertTrue(canceller.isRotationCall(address(wrapper), 0, sent));

        // And an operation made of a near-rotation call really is cancellable.
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(reputation), 0, rot, salt);
        vm.prank(guardian);
        canceller.cancel(address(reputation), 0, rot, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    function test_noWrapper_setIsSentinelIsNeverProtected() public {
        MHGuardianCanceller c =
            new MHGuardianCanceller(address(timelock), address(registry), address(0), guardian);
        bytes memory sent = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        assertFalse(c.isRotationCall(address(wrapper), 0, sent));
        assertFalse(c.isRotationCall(address(0), 0, sent));
    }

    // ---------------------------------------------------------------- setGuardian

    function test_setGuardian_onlyTimelock() public {
        address[4] memory callers = [guardian, gov, attacker, address(registry)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(MHGuardianCanceller.NotTimelock.selector);
            canceller.setGuardian(attacker);
        }
        vm.prank(address(timelock));
        vm.expectRevert(MHGuardianCanceller.ZeroAddress.selector);
        canceller.setGuardian(address(0));

        bytes memory data = abi.encodeCall(MHGuardianCanceller.setGuardian, (newGuardian));
        bytes32 salt = _govScheduleAndWait(address(canceller), data);
        vm.expectEmit(true, true, false, false, address(canceller));
        emit MHGuardianCanceller.GuardianSet(guardian, newGuardian);
        _govExecute(address(canceller), data, salt);
        assertEq(canceller.guardian(), newGuardian);
    }

    /// @dev Without the canceller, a Guardian holding CANCELLER_ROLE directly could veto its own removal forever.
    ///      Through the canceller it cannot, while Gov keeps its own ability to cancel anything.
    function test_guardianCannotBlockItsOwnRemoval_govCanStillCancel() public {
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(registry), 0, data, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancel(address(registry), 0, data, bytes32(0), salt);
        // Gov (also a canceller) can withdraw its own proposal.
        vm.prank(gov);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id));
    }

    // ---------------------------------------------------------------- Gas: no operation is too large to cancel

    function test_cancelBatch_cheaperThanScheduleBatch() public {
        uint256 n = 200;
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(n);
        for (uint256 i; i < n; ++i) {
            t[i] = address(registry);
            // Mostly rotation calls with one ordinary call at the end: the scan reads every element.
            p[i] = i == n - 1
                ? abi.encodeCall(IMHCircleRegistry.setTreasury, (attacker))
                : abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        }
        bytes32 salt = _nextSalt();
        vm.prank(gov);
        uint256 g0 = gasleft();
        timelock.scheduleBatch(t, v, p, bytes32(0), salt, DELAY);
        uint256 scheduleGas = g0 - gasleft();

        vm.prank(guardian);
        g0 = gasleft();
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        uint256 cancelGas = g0 - gasleft();
        assertLt(cancelGas, scheduleGas, "cancel must not cost more than schedule");
    }

    // ---------------------------------------------------------------- Helpers

    function _batch(uint256 n)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory p)
    {
        t = new address[](n);
        v = new uint256[](n);
        p = new bytes[](n);
    }

    function _rotationBatch()
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory p)
    {
        (t, v, p) = _batch(4);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        t[1] = address(canceller);
        p[1] = abi.encodeCall(MHGuardianCanceller.setGuardian, (newGuardian));
        t[2] = address(wrapper);
        p[2] = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        t[3] = address(wrapper);
        p[3] = abi.encodeCall(IVaultV2.setIsSentinel, (newGuardian, true));
    }

    function _pendingBitmap() internal pure returns (bytes32) {
        // OZ `_encodeStateBitmap(state) = bytes32(1 << uint8(state))`.
        return bytes32(2 ** uint256(uint8(TimelockController.OperationState.Waiting)))
            | bytes32(2 ** uint256(uint8(TimelockController.OperationState.Ready)));
    }
}
