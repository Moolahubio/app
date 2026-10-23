// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { IMHCircle } from "../../src/circles/interfaces/IMHCircle.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IVaultV2, IMorphoMarketV1AdapterV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { RotatingParams, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";
import { MockVaultV2, MockAdapterV2 } from "../mocks/MockVaultV2.sol";

/// @notice An adapter whose timelock views return fewer than 32 bytes (audit 2 R1-28).
contract ShortReturnAdapter {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 16)
        }
    }
}

/// @notice An adapter whose `abdicated` view returns 2, a malformed bool (audit 2 R1-28).
contract MalformedAbdicatedAdapter {
    function abdicated(bytes4) external pure returns (uint256) {
        return 2;
    }

    function timelock(bytes4) external pure returns (uint256) {
        return 30 days;
    }
}

/// @notice Audit 2, round 1: regressions for the canceller, the registry and circle initialization (R1-10, R1-12
///         ports G06/G15/G16, R1-16, R1-17, R1-28), on the real governance stack of `CircleFixture` with the real
///         circle implementations behind the factory.
contract MHAudit2GovernanceTest is CircleFixture {
    address internal newGuardian = makeAddr("guardianSafe2");
    address internal thirdSentinel = makeAddr("privySentinel");

    function _deployRotatingImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        override
        returns (address)
    {
        return address(new MHRotatingCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    function _deployAccumulationImpl(IMHCircleRegistry pRegistry, IMHReputation pReputation)
        internal
        override
        returns (address)
    {
        return address(new MHAccumulationCircle(IUSDC(address(usdc)), pRegistry, pReputation));
    }

    function _batch(uint256 n)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory p)
    {
        t = new address[](n);
        v = new uint256[](n);
        p = new bytes[](n);
    }

    // ================================================================ R1-16: the rotation exception

    /// @dev R1-16 (a): a lone `canceller.setGuardian(X)` that does not complete a rotation strips the veto without
    ///      replacing the Guardian; the sitting Guardian can now cancel it. Completing a rotation (X is the registry's
    ///      Guardian) stays protected.
    function test_A2R1_16_loneCancellerSetGuardian_cancellableUnlessCompleting() public {
        bytes memory strip = abi.encodeCall(MHGuardianCanceller.setGuardian, (makeAddr("sink")));
        bytes32 salt = _nextSalt();
        bytes32 id = _schedule(address(canceller), 0, strip, salt);
        vm.prank(guardian);
        canceller.cancel(address(canceller), 0, strip, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));

        bytes memory complete = abi.encodeCall(MHGuardianCanceller.setGuardian, (guardian));
        salt = _nextSalt();
        _schedule(address(canceller), 0, complete, salt);
        vm.prank(guardian);
        vm.expectRevert(MHGuardianCanceller.RotationOnly.selector);
        canceller.cancel(address(canceller), 0, complete, bytes32(0), salt);
    }

    /// @dev R1-16 (a): in a batch, the canceller's half must name the same new Guardian as the registry's (a typo or a
    ///      mismatch silently disabled the veto); otherwise the batch is cancellable.
    function test_A2R1_16_mismatchedRotationBatch_isCancellable() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        t[1] = address(canceller);
        p[1] = abi.encodeCall(MHGuardianCanceller.setGuardian, (makeAddr("typo")));
        assertFalse(canceller.isRotationOnly(t, v, p), "mismatched halves");
        p[1] = abi.encodeCall(MHGuardianCanceller.setGuardian, (newGuardian));
        assertTrue(canceller.isRotationOnly(t, v, p), "a matching rotation");
        bytes32 salt = _nextSalt();
        p[1] = abi.encodeCall(MHGuardianCanceller.setGuardian, (makeAddr("typo")));
        bytes32 id = _scheduleBatch(t, v, p, salt);
        vm.prank(guardian);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    /// @dev R1-16 (b): a no-op `registry.setGuardian(currentGuardian)` used to make any `setIsSentinel(other, false)`
    ///      protected; Gov could remove a third-party sentinel without replacing the Guardian. A no-op rotation now
    ///      protects nothing, and inside a real rotation only the replaced Guardian may be removed.
    function test_A2R1_16_noOpRotation_protectsNothing() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (guardian));
        t[1] = address(wrapper);
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (thirdSentinel, false));
        assertFalse(canceller.isRotationOnly(t, v, p), "no-op rotation");
        bytes32 salt = _nextSalt();
        bytes32 id = _scheduleBatch(t, v, p, salt);
        vm.prank(guardian);
        canceller.cancelBatch(t, v, p, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));

        // A real rotation that also removes a third-party sentinel is cancellable too.
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        assertFalse(canceller.isRotationOnly(t, v, p), "removing someone other than the replaced Guardian");
        // Removing exactly the replaced Guardian is part of the rotation.
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        assertTrue(canceller.isRotationOnly(t, v, p));
        // A no-op rotation that strips the sitting Guardian's own sentinel role (Gov removing its powers without
        // replacing it) is cancellable, and so is a batch holding only the no-op (kills mutant N11).
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (guardian));
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        assertFalse(canceller.isRotationOnly(t, v, p), "no-op rotation stripping the sitting Guardian");
        (address[] memory t1, uint256[] memory v1, bytes[] memory p1) = _batch(1);
        t1[0] = address(registry);
        p1[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (guardian));
        assertFalse(canceller.isRotationOnly(t1, v1, p1), "a lone no-op rotation batch");
        // A lone no-op registry.setGuardian is not protected either.
        bytes memory noop = abi.encodeCall(IMHCircleRegistry.setGuardian, (guardian));
        salt = _nextSalt();
        id = _schedule(address(registry), 0, noop, salt);
        vm.prank(guardian);
        canceller.cancel(address(registry), 0, noop, bytes32(0), salt);
        assertFalse(timelock.isOperation(id));
    }

    /// @dev Kills mutant G06 (R2-14 pairing removed) and the audit 2 R1-28 malformed-sentinel case: a rotation that
    ///      adds some other account as a sentinel, or carries dirty address bits or a bool word above 1, is not a
    ///      rotation.
    function test_A2R1_12_G06_and_R1_28_sentinelWordsChecked() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _batch(2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        t[1] = address(wrapper);
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (attacker, true));
        assertFalse(canceller.isRotationOnly(t, v, p), "foreign sentinel is not a rotation");
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (newGuardian, true));
        assertTrue(canceller.isRotationOnly(t, v, p), "the new Guardian as sentinel is");
        p[1] = abi.encodePacked(IVaultV2.setIsSentinel.selector, uint256(uint160(newGuardian)), uint256(2));
        assertFalse(canceller.isRotationOnly(t, v, p), "bool word above 1");
        p[1] = abi.encodePacked(
            IVaultV2.setIsSentinel.selector, uint256(uint160(newGuardian)) | (uint256(1) << 200), uint256(1)
        );
        assertFalse(canceller.isRotationOnly(t, v, p), "dirty address bits");
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (newGuardian, true));
        p[0] = abi.encodePacked(
            IMHCircleRegistry.setGuardian.selector, uint256(uint160(newGuardian)) | (1 << 255)
        );
        assertFalse(canceller.isRotationOnly(t, v, p), "dirty bits in setGuardian");
    }

    // ================================================================ R1-17: only factory clones initialize

    /// @dev R1-17: a third-party clone of an audited implementation used to initialize and then trap funds (every
    ///      strike path reverts `NotReporter`). `initialize` now requires the clone to be a registered reporter,
    ///      which only the factory does (before `initialize`).
    function test_A2R1_17_nonFactoryClone_cannotInitialize() public {
        address rot = Clones.clone(factory.ROTATING_IMPL());
        RotatingParams memory rp = _rotParams(keccak256("rogue rotating"), 3);
        vm.expectRevert(IMHCircle.BadConfig.selector);
        MHRotatingCircle(rot).initialize(rp);

        address acc = Clones.clone(factory.ACCUMULATION_IMPL());
        AccumulationParams memory ap = _accParams(keccak256("rogue accumulation"), 3);
        vm.expectRevert(IMHCircle.BadConfig.selector);
        MHAccumulationCircle(acc).initialize(ap);

        // The factory path still works.
        vm.prank(operator);
        factory.createRotating(rp);
        vm.prank(operator);
        factory.createAccumulation(ap);
    }

    // ================================================================ R1-10 / R1-12 G15 / R1-28: the adapter walk

    function _allow(MockVaultV2 v) internal {
        vm.prank(address(timelock));
        registry.allowVault(address(v));
    }

    /// @dev R1-10: `vaultSafe` now walks the adapters: an adapter whose `burnShares` timelock drops below 3 days (the
    ///      adapter set unchanged) makes the vault unsafe at once, before anyone calls `revalidateVault`. Kills G15
    ///      too (`revalidateVault` must walk them and delist).
    function test_A2R1_10_vaultSafeWalksAdapters_andRevalidateDelists() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        MockAdapterV2 a = new MockAdapterV2();
        v.mockAddAdapter(address(a));
        _allow(v);
        assertTrue(registry.vaultSafe(address(v)));
        a.mockSetTimelock(IMorphoMarketV1AdapterV2.burnShares.selector, 1 days);
        assertFalse(registry.vaultSafe(address(v)), "live check sees the adapter");
        assertTrue(registry.revalidateVault(address(v)), "weakened adapter delists");
        assertFalse(registry.isAllowedVault(address(v)));
    }

    /// @dev Kills mutant G16 (the gas guard removed): no gas limit lets anyone delist an honest vault through
    ///      `revalidateVault`; `vaultSafe` either answers true or reverts `InsufficientGas`.
    function test_A2R1_12_G16_gasLimitedCallsNeverDelistAnHonestVault() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        for (uint256 i; i < 4; ++i) {
            v.mockAddAdapter(address(new MockAdapterV2()));
        }
        _allow(v);
        for (uint256 g = 30_000; g < 600_000; g += 997) {
            (bool ok, bytes memory ret) =
                address(registry).call{ gas: g }(abi.encodeCall(registry.revalidateVault, (address(v))));
            if (ok) {
                assertFalse(abi.decode(ret, (bool)), "an honest vault was delisted by a gas-limited call");
            }
            assertTrue(registry.isAllowedVault(address(v)), "still allowed");
            (ok, ret) = address(registry).call{ gas: g }(abi.encodeCall(registry.vaultSafe, (address(v))));
            if (ok) assertTrue(abi.decode(ret, (bool)), "vaultSafe answered false for an honest vault");
        }
    }

    /// @dev R1-28: the bounded read fails closed on a short return and on a malformed `abdicated` word, with the
    ///      exact check (kills G03/G04).
    function test_A2R1_28_adapterReadsFailClosed() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        v.mockAddAdapter(address(new ShortReturnAdapter()));
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMHCircleRegistry.VaultCheckFailed.selector, IMorphoMarketV1AdapterV2.burnShares.selector
            )
        );
        registry.allowVault(address(v));

        v = new MockVaultV2(address(usdc), address(this));
        v.mockAddAdapter(address(new MalformedAbdicatedAdapter()));
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMHCircleRegistry.VaultCheckFailed.selector, IMorphoMarketV1AdapterV2.burnShares.selector
            )
        );
        registry.allowVault(address(v));
    }
}
