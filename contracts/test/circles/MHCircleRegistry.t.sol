// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { CircleFixture } from "./CircleFixture.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { MockVaultV2 } from "../mocks/MockVaultV2.sol";

contract MHCircleRegistryTest is CircleFixture {
    MockVaultV2 internal vault;

    function setUp() public override {
        super.setUp();
        vault = new MockVaultV2(address(usdc), makeAddr("vaultOwner"));
    }

    // ---------------------------------------------------------------- Construction

    function test_constructor_setsEverything() public view {
        assertEq(registry.owner(), address(timelock));
        assertEq(registry.pendingOwner(), address(0));
        assertEq(address(registry.USDC()), address(usdc));
        assertEq(registry.operator(), operator);
        assertEq(registry.guardian(), guardian);
        assertEq(registry.treasury(), treasury);
        assertFalse(registry.creationPaused());
    }

    function test_constructor_emitsRoleEvents() public {
        vm.expectEmit(true, true, false, false);
        emit IMHCircleRegistry.OperatorSet(address(0), operator);
        vm.expectEmit(true, true, false, false);
        emit IMHCircleRegistry.GuardianSet(address(0), guardian);
        vm.expectEmit(true, true, false, false);
        emit IMHCircleRegistry.TreasurySet(address(0), treasury);
        new MHCircleRegistry(address(timelock), IUSDC(address(usdc)), operator, guardian, treasury);
    }

    function test_constructor_revertsOnZero() public {
        IUSDC u = IUSDC(address(usdc));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MHCircleRegistry(address(0), u, operator, guardian, treasury);
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        new MHCircleRegistry(address(timelock), IUSDC(address(0)), operator, guardian, treasury);
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        new MHCircleRegistry(address(timelock), u, address(0), guardian, treasury);
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        new MHCircleRegistry(address(timelock), u, operator, address(0), treasury);
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        new MHCircleRegistry(address(timelock), u, operator, guardian, address(0));
    }

    function test_constructor_revertsOnRoleCollision() public {
        IUSDC u = IUSDC(address(usdc));
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        new MHCircleRegistry(address(timelock), u, operator, operator, treasury);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        new MHCircleRegistry(address(timelock), u, operator, guardian, operator);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        new MHCircleRegistry(address(timelock), u, operator, guardian, guardian);
    }

    // ---------------------------------------------------------------- R5: two-step ownership, no setOwner

    function test_R5_noOneStepSetOwner() public {
        vm.prank(address(timelock));
        (bool ok,) = address(registry).call(abi.encodeWithSignature("setOwner(address)", attacker));
        assertFalse(ok, "setOwner must not exist");
        assertEq(registry.owner(), address(timelock));
    }

    function test_R5_transferOwnershipIsTwoStep() public {
        address newOwner = makeAddr("newTimelock");
        _govExec(address(registry), abi.encodeCall(Ownable.transferOwnership, (newOwner)));
        // Nothing changes until the new owner accepts.
        assertEq(registry.owner(), address(timelock));
        assertEq(registry.pendingOwner(), newOwner);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.acceptOwnership();

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_R5_mistypedOwnerNeverTakesEffect() public {
        address typo = address(0xdead);
        _govExec(address(registry), abi.encodeCall(Ownable.transferOwnership, (typo)));
        assertEq(registry.owner(), address(timelock), "owner unchanged without acceptance");
        // The Timelock can still correct it.
        _govExec(address(registry), abi.encodeCall(Ownable.transferOwnership, (address(timelock))));
        assertEq(registry.pendingOwner(), address(timelock));
    }

    function test_R5_transferOwnershipOnlyOwner() public {
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, gov));
        registry.transferOwnership(gov);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(address(timelock));
        vm.expectRevert(IMHCircleRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), address(timelock));
    }

    // ---------------------------------------------------------------- Owner setters

    function test_setOperator_byTimelock() public {
        address next = makeAddr("operator2");
        vm.expectEmit(true, true, false, false, address(registry));
        emit IMHCircleRegistry.OperatorSet(operator, next);
        vm.prank(address(timelock));
        registry.setOperator(next);
        assertEq(registry.operator(), next);
    }

    function test_setGuardian_byTimelock() public {
        address next = makeAddr("guardian2");
        vm.expectEmit(true, true, false, false, address(registry));
        emit IMHCircleRegistry.GuardianSet(guardian, next);
        vm.prank(address(timelock));
        registry.setGuardian(next);
        assertEq(registry.guardian(), next);

        // The old Guardian loses its powers immediately.
        vm.prank(guardian);
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.pauseCreation();
        vm.prank(next);
        registry.pauseCreation();
    }

    function test_setTreasury_byTimelock() public {
        address next = makeAddr("treasury2");
        vm.expectEmit(true, true, false, false, address(registry));
        emit IMHCircleRegistry.TreasurySet(treasury, next);
        vm.prank(address(timelock));
        registry.setTreasury(next);
        assertEq(registry.treasury(), next);
    }

    function test_setters_throughRealTimelockDelay() public {
        address next = makeAddr("treasury2");
        bytes memory data = abi.encodeCall(IMHCircleRegistry.setTreasury, (next));
        bytes32 salt = _nextSalt();
        _schedule(address(registry), 0, data, salt);
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(gov);
        vm.expectRevert();
        timelock.execute(address(registry), 0, data, bytes32(0), salt);
        vm.warp(block.timestamp + 1);
        vm.prank(gov);
        timelock.execute(address(registry), 0, data, bytes32(0), salt);
        assertEq(registry.treasury(), next);
    }

    function test_setters_revertZeroAndCollision() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        registry.setOperator(address(0));
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        registry.setGuardian(address(0));
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        registry.setTreasury(address(0));
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setOperator(guardian);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setOperator(treasury);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setGuardian(operator);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setGuardian(treasury);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setTreasury(operator);
        vm.expectRevert(IMHCircleRegistry.RoleCollision.selector);
        registry.setTreasury(guardian);
        vm.stopPrank();
    }

    function testFuzz_ownerFunctions_onlyOwner(address caller) public {
        vm.assume(caller != address(timelock));
        address x = makeAddr("x");
        vm.startPrank(caller);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.expectRevert(err);
        registry.setOperator(x);
        vm.expectRevert(err);
        registry.setGuardian(x);
        vm.expectRevert(err);
        registry.setTreasury(x);
        vm.expectRevert(err);
        registry.allowVault(address(vault));
        vm.expectRevert(err);
        registry.unpauseCreation();
        vm.expectRevert(err);
        registry.transferOwnership(x);
        vm.stopPrank();
    }

    function test_roleHoldersCannotCallOwnerFunctions() public {
        address[4] memory callers = [gov, guardian, operator, treasury];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            registry.setGuardian(callers[i]);
        }
    }

    // ---------------------------------------------------------------- Pause (Guardian) / unpause (owner)

    function test_pauseCreation_onlyGuardian() public {
        vm.prank(address(timelock));
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.pauseCreation();
        vm.prank(operator);
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.pauseCreation();

        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.CreationPaused(guardian);
        vm.prank(guardian);
        registry.pauseCreation();
        assertTrue(registry.creationPaused());
    }

    function test_unpauseCreation_onlyOwner() public {
        vm.prank(guardian);
        registry.pauseCreation();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        registry.unpauseCreation();

        bytes memory data = abi.encodeCall(IMHCircleRegistry.unpauseCreation, ());
        bytes32 salt = _govScheduleAndWait(address(registry), data);
        vm.expectEmit(false, false, false, false, address(registry));
        emit IMHCircleRegistry.CreationUnpaused();
        _govExecute(address(registry), data, salt);
        assertFalse(registry.creationPaused());
    }

    // ---------------------------------------------------------------- allowVault (owner) / disallowVault (Guardian)

    function test_allowVault_gauntletShapePasses() public {
        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultAllowed(address(vault));
        vm.prank(address(timelock));
        registry.allowVault(address(vault));
        assertTrue(registry.isAllowedVault(address(vault)));
    }

    function test_allowVault_sendAssetsGateMayBeLive() public {
        // Gauntlet's sendAssetsGate is not abdicated (7-day timelock): it can block deposits, never exits.
        vault.mockSetSendAssetsGate(makeAddr("depositGate"));
        vm.prank(address(timelock));
        registry.allowVault(address(vault));
        assertTrue(registry.isAllowedVault(address(vault)));
    }

    function test_allowVault_rejectsWrongAsset() public {
        vault.mockSetAsset(makeAddr("notUsdc"));
        _expectVaultCheck(IVaultV2.asset.selector);
    }

    function test_allowVault_rejectsLiveExitGates() public {
        bytes4[3] memory setters = [
            IVaultV2.setReceiveAssetsGate.selector,
            IVaultV2.setReceiveSharesGate.selector,
            IVaultV2.setSendSharesGate.selector
        ];
        for (uint256 i; i < 3; ++i) {
            // Not abdicated (gate zero) → rejected.
            MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
            v.mockSetAbdicated(setters[i], false);
            _expectVaultCheckOn(v, setters[i]);

            // Abdicated but non-zero (a permanent third-party veto over exits) → rejected.
            v = new MockVaultV2(address(usdc), address(this));
            if (i == 0) v.mockSetReceiveAssetsGate(address(0xBEEF));
            if (i == 1) v.mockSetReceiveSharesGate(address(0xBEEF));
            if (i == 2) v.mockSetSendSharesGate(address(0xBEEF));
            _expectVaultCheckOn(v, setters[i]);
        }
    }

    function test_allowVault_rejectsShortTimelocks() public {
        bytes4[2] memory sels = [IVaultV2.setIsAllocator.selector, IVaultV2.addAdapter.selector];
        for (uint256 i; i < 2; ++i) {
            MockVaultV2 v = new MockVaultV2(address(usdc), address(this));
            v.mockSetTimelock(sels[i], 7 days - 1);
            _expectVaultCheckOn(v, sels[i]);

            v = new MockVaultV2(address(usdc), address(this));
            v.mockSetTimelock(sels[i], 0);
            _expectVaultCheckOn(v, sels[i]);
        }
    }

    function test_allowVault_abdicatedTimelockedFunctionPasses() public {
        // Abdicated is stronger than any timelock: the function can never run again.
        vault.mockSetTimelock(IVaultV2.addAdapter.selector, 0);
        vault.mockSetAbdicated(IVaultV2.addAdapter.selector, true);
        vault.mockSetTimelock(IVaultV2.setIsAllocator.selector, 0);
        vault.mockSetAbdicated(IVaultV2.setIsAllocator.selector, true);
        vm.prank(address(timelock));
        registry.allowVault(address(vault));
        assertTrue(registry.isAllowedVault(address(vault)));
    }

    function test_allowVault_longerTimelockPasses() public {
        vault.mockSetTimelock(IVaultV2.addAdapter.selector, 30 days);
        vm.prank(address(timelock));
        registry.allowVault(address(vault));
        assertTrue(registry.isAllowedVault(address(vault)));
    }

    function test_allowVault_rejectsZeroAndCodeless() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(IMHCircleRegistry.ZeroAddress.selector);
        registry.allowVault(address(0));
        vm.expectRevert();
        registry.allowVault(makeAddr("eoa"));
        vm.stopPrank();
    }

    function test_disallowVault_onlyGuardian() public {
        vm.prank(address(timelock));
        registry.allowVault(address(vault));

        vm.prank(address(timelock));
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.disallowVault(address(vault));
        vm.prank(attacker);
        vm.expectRevert(IMHCircleRegistry.NotGuardian.selector);
        registry.disallowVault(address(vault));

        vm.expectEmit(true, false, false, false, address(registry));
        emit IMHCircleRegistry.VaultDisallowed(address(vault));
        vm.prank(guardian);
        registry.disallowVault(address(vault));
        assertFalse(registry.isAllowedVault(address(vault)));
    }

    function test_guardianCannotAllowVault() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        registry.allowVault(address(vault));
    }

    // ---------------------------------------------------------------- Helpers

    function _expectVaultCheck(bytes4 check) internal {
        _expectVaultCheckOn(vault, check);
    }

    function _expectVaultCheckOn(MockVaultV2 v, bytes4 check) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMHCircleRegistry.VaultCheckFailed.selector, check));
        registry.allowVault(address(v));
        assertFalse(registry.isAllowedVault(address(v)));
    }
}
