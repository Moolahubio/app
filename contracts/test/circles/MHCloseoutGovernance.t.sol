// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { MHVaultPending } from "../../script/ceremony/MHVaultPending.sol";
import { MockVaultV2, MockAdapterV2 } from "../mocks/MockVaultV2.sol";
import { VaultV2 } from "../vendor/vaultv2/VaultV2.sol";

/// @notice Morpho's adapter registry answer ("made by the Morpho factory"), reduced to an allowlist.
contract AdapterRegistryModel {
    mapping(address adapter => bool) public isInRegistry;

    function add(address a) external {
        isInRegistry[a] = true;
    }
}

/// @notice Closeout of the internal audit, governance side: A-R2-01 (sleeper submissions on the REAL Vault V2 code,
///         `test/vendor/vaultv2`), A-R2-07 (revalidation fails closed and delists), and the B-R2-14 survivors G05
///         (the 16-adapter boundary) and C02 (the canceller's `on > 1` check).
contract MHCloseoutGovernanceTest is CircleFixture {
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal curator = makeAddr("vaultCurator");

    /// @notice `MHVaultPending.requireNone` (external, so `expectRevert` can observe it).
    function requireNoneExternal(MHVaultPending.Submission[] memory p) external pure {
        MHVaultPending.requireNone(p);
    }

    function _curator(VaultV2 v, bytes memory data, bool execute) internal {
        vm.prank(curator);
        v.submit(data);
        if (execute) {
            (bool ok, bytes memory ret) = address(v).call(data);
            require(ok, string(ret));
        }
    }

    // ================================================================ A-R2-01: sleeper submissions

    /// @dev A-R2-01: on the real Vault V2 code, data submitted while a timelock was still 0 stays executable by anyone
    ///      after the timelock is raised. Every duration `allowVault` reads then looks right and the vault is
    ///      allowlisted, which is why the pending-submission scan (`MHVaultPending`, run by `CheckVaultPending`,
    ///      `BuildBaseBatch` and `VerifyBase`) is a mandatory part of the check. The scan finds both sleepers and
    ///      refuses; once the curator revokes them, it passes.
    function test_A1R2_01_sleeperSubmissions_foundByTheScan() public {
        vm.recordLogs();
        VaultV2 v = new VaultV2(vaultOwner, address(usdc));
        vm.prank(vaultOwner);
        v.setCurator(curator);
        AdapterRegistryModel reg = new AdapterRegistryModel();
        MockAdapterV2 adapter = new MockAdapterV2(); // burnShares timelocked 3 days
        reg.add(address(adapter));
        _curator(v, abi.encodeCall(v.setAdapterRegistry, (address(reg))), true);
        _curator(v, abi.encodeCall(v.addAdapter, (address(adapter))), true);
        // Sleepers: submitted while every timelock is still 0, never executed.
        bytes memory sleeperAllocator = abi.encodeCall(v.setIsAllocator, (attacker, true));
        bytes memory sleeperTimelock =
            abi.encodeCall(v.decreaseTimelock, (IVaultV2.removeAdapter.selector, 0));
        _curator(v, sleeperAllocator, false);
        _curator(v, sleeperTimelock, false);
        // Hardened into exactly the shape the registry checks.
        _curator(v, abi.encodeCall(v.abdicate, (IVaultV2.setReceiveAssetsGate.selector)), true);
        _curator(v, abi.encodeCall(v.abdicate, (IVaultV2.setReceiveSharesGate.selector)), true);
        _curator(v, abi.encodeCall(v.abdicate, (IVaultV2.setSendSharesGate.selector)), true);
        _curator(v, abi.encodeCall(v.abdicate, (IVaultV2.setAdapterRegistry.selector)), true);
        bytes4[3] memory slow =
            [IVaultV2.setIsAllocator.selector, IVaultV2.addAdapter.selector, IVaultV2.removeAdapter.selector];
        for (uint256 i; i < 3; ++i) {
            _curator(v, abi.encodeCall(v.increaseTimelock, (slow[i], 7 days)), true);
        }
        bytes4[4] memory fast = [
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector
        ];
        for (uint256 i; i < 4; ++i) {
            _curator(v, abi.encodeCall(v.increaseTimelock, (fast[i], 3 days)), true);
        }

        // The on-chain check cannot see them: the vault is allowlisted.
        vm.prank(address(timelock));
        registry.allowVault(address(v));
        assertTrue(registry.vaultSafe(address(v)));

        // The scan does.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        MHVaultPending.Submission[] memory p =
            MHVaultPending.pending(MHVaultPending.fromRecorded(logs, MHVaultPending.targetsOf(address(v))));
        assertEq(p.length, 2, "both sleepers");
        assertEq(keccak256(p[0].data), keccak256(sleeperAllocator));
        assertEq(keccak256(p[1].data), keccak256(sleeperTimelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                MHVaultPending.PendingSubmission.selector,
                address(v),
                IVaultV2.setIsAllocator.selector,
                p[0].executableAt,
                sleeperAllocator
            )
        );
        this.requireNoneExternal(p);
        // What the scan protects against: anyone can execute a sleeper at once.
        vm.prank(attacker);
        (bool ok,) = address(v).call(sleeperTimelock);
        assertTrue(ok, "a sleeper executes immediately despite the 7-day timelock now in place");
        assertEq(v.timelock(IVaultV2.removeAdapter.selector), 0);

        // Revoked (the other one) and re-scanned: nothing pending.
        vm.prank(curator);
        v.revoke(sleeperAllocator);
        p = MHVaultPending.pending(MHVaultPending.fromRecorded(logs, MHVaultPending.targetsOf(address(v))));
        assertEq(p.length, 0);
        this.requireNoneExternal(p);
    }

    // ================================================================ A-R2-07: revalidation fails closed

    /// @dev A-R2-07: an allowlisted vault's adapter stops answering Morpho's timelock views (here it returns no data at
    ///      all). `revalidateVault` used to revert and leave the vault allowlisted; it now delists it, permissionlessly,
    ///      and `vaultSafe` answers false without reverting.
    function test_A1R2_07_adapterLosesItsViews_revalidateDelists() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        MockAdapterV2 a = new MockAdapterV2();
        v.mockAddAdapter(address(a));
        vm.prank(address(timelock));
        registry.allowVault(address(v));
        vm.etch(address(a), hex"00"); // same address (same adapter set), no views any more
        assertFalse(registry.vaultSafe(address(v)));
        vm.prank(attacker);
        assertTrue(registry.revalidateVault(address(v)));
        assertFalse(registry.isAllowedVault(address(v)));
    }

    // ================================================================ B-R2-14: G05 and C02

    /// @dev G05: exactly `MAX_VAULT_ADAPTERS` (16) adapters pass; 17 fail (the existing round-1 test).
    function test_A2R2_14_G05_sixteenAdaptersPass() public {
        MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
        for (uint256 i; i < 16; ++i) {
            v.mockAddAdapter(address(new MockAdapterV2()));
        }
        vm.prank(address(timelock));
        registry.allowVault(address(v));
        assertTrue(registry.vaultSafe(address(v)));
        v.mockAddAdapter(address(new MockAdapterV2()));
        assertFalse(registry.vaultSafe(address(v)), "the 17th");
    }

    /// @dev C02: a `setIsSentinel(currentGuardian, on)` word above 1 is not a rotation (it is cancellable). The audit 2
    ///      test used the new Guardian with `on = 2`, which the address pairing rejects anyway, so dropping the
    ///      `on > 1` check survived; with the sitting Guardian only that check rejects it.
    function test_A2R2_14_C02_sentinelWordAboveOne_isCancellable() public {
        address newGuardian = makeAddr("guardianSafe2");
        address[] memory t = new address[](2);
        uint256[] memory v = new uint256[](2);
        bytes[] memory p = new bytes[](2);
        t[0] = address(registry);
        p[0] = abi.encodeCall(IMHCircleRegistry.setGuardian, (newGuardian));
        t[1] = address(wrapper);
        p[1] = abi.encodeCall(IVaultV2.setIsSentinel, (guardian, false));
        assertTrue(canceller.isRotationOnly(t, v, p), "removing the sitting Guardian: a rotation");
        p[1] = abi.encodePacked(IVaultV2.setIsSentinel.selector, uint256(uint160(guardian)), uint256(2));
        assertFalse(canceller.isRotationOnly(t, v, p), "bool word 2 on the sitting Guardian");
    }
}
