// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHReputation } from "../../src/circles/MHReputation.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import {
    RotatingConfig,
    RotatingParams,
    AccumulationConfig,
    AccumulationParams
} from "../../src/circles/MHCircleTypes.sol";

import { IVaultV2Fork, IMorphoBlue, IFiatToken, MarketParams } from "./ForkInterfaces.sol";

/// @notice Base mainnet fork fixture (spec §4.7 "Base fork"). Skips every test unless `BASE_RPC_URL` is set. Forks a
///         pinned block (`BASE_FORK_BLOCK`, default 52,933,005, the Appendix A check block; the RPC must serve
///         historical state) and deploys the full circle stack in the spec §5 order against real USDC, with the
///         Gauntlet USDC Prime Vault V2 allowlisted through the Timelock by the real `allowVault` checks.
///         Run: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/fork/*'`.
abstract contract BaseForkFixture is Test {
    // ---------------------------------------------------------------- Appendix A (Base 8453)
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant GAUNTLET = 0x050cE30b927Da55177A4914EC73480238BAD56f0;
    address internal constant GAUNTLET_LIQUIDITY_ADAPTER = 0x2fEcd40f436CA170D2478a58Da898FcE93988eef;
    address internal constant STEAKHOUSE = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9;
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    // Not in Appendix A: Morpho Blue singleton on Base, read from the Gauntlet liquidity adapter's `morpho()`.
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    uint256 internal constant DEFAULT_FORK_BLOCK = 52_933_005;
    uint256 internal constant DELAY = 48 hours;

    bool internal forked;

    address internal gov = makeAddr("govSafe");
    address internal guardian = makeAddr("guardianSafe");
    address internal treasury = makeAddr("treasurySafe");
    address internal operator = makeAddr("operator");
    address internal attacker = makeAddr("attacker");

    IUSDC internal usdc = IUSDC(USDC);
    IVaultV2Fork internal vault = IVaultV2Fork(GAUNTLET);
    TimelockController internal timelock;
    MHGuardianCanceller internal canceller;
    MHCircleRegistry internal registry;
    MHReputation internal reputation;
    MHCircleFactory internal factory;

    uint256 private _saltNonce;

    function setUp() public virtual {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("BASE_FORK_BLOCK", DEFAULT_FORK_BLOCK));
        forked = true;
        _deployStack();
        _govExec(address(registry), abi.encodeCall(registry.allowVault, (GAUNTLET)));
        assertTrue(registry.isAllowedVault(GAUNTLET), "Gauntlet passes the real allowVault checks");
    }

    /// @dev Spec §5 order: implementations (inert), Timelock with Gov as temporary admin, canceller (no wrapper),
    ///      CANCELLER_ROLE, Registry, Reputation (predicted factory), Factory, Gov renounces admin. Addresses needed
    ///      early are predicted from CREATE nonces, standing in for CreateX `deployCreate3`.
    function _deployStack() internal {
        uint256 n = vm.getNonce(address(this));
        address pRegistry = vm.computeCreateAddress(address(this), n + 4);
        address pReputation = vm.computeCreateAddress(address(this), n + 5);
        address pFactory = vm.computeCreateAddress(address(this), n + 6);
        address rotImpl =
            address(new MHRotatingCircle(usdc, IMHCircleRegistry(pRegistry), IMHReputation(pReputation))); // n
        address accImpl = address(
            new MHAccumulationCircle(usdc, IMHCircleRegistry(pRegistry), IMHReputation(pReputation))
        ); // n+1
        address[] memory govList = new address[](1);
        govList[0] = gov;
        timelock = new TimelockController(DELAY, govList, govList, gov); // n+2
        canceller = new MHGuardianCanceller(address(timelock), pRegistry, address(0), guardian); // n+3
        vm.startPrank(gov);
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(canceller));
        vm.stopPrank();
        registry = new MHCircleRegistry(address(timelock), usdc, operator, guardian, treasury); // n+4
        reputation = new MHReputation(address(timelock), pFactory); // n+5
        factory = new MHCircleFactory(registry, reputation, rotImpl, accImpl); // n+6
        vm.startPrank(gov);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), gov);
        vm.stopPrank();
        assertEq(address(registry), pRegistry);
        assertEq(address(reputation), pReputation);
        assertEq(address(factory), pFactory);
    }

    function _govExec(address target, bytes memory data) internal {
        bytes32 salt = bytes32(++_saltNonce);
        vm.prank(gov);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    /// @dev Like `_govExec`, but returns whether the execution succeeded (the Timelock bubbles the target's revert).
    function _govTry(address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        bytes32 salt = bytes32(++_saltNonce);
        vm.prank(gov);
        timelock.schedule(target, 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(gov);
        (ok, ret) =
            address(timelock).call(abi.encodeCall(timelock.execute, (target, 0, data, bytes32(0), salt)));
    }

    // ---------------------------------------------------------------- USDC

    /// @dev Gives `who` real USDC (storage write through forge-std `deal`) and approves `spender` exactly.
    function _fund(address who, address spender, uint256 amount) internal {
        deal(USDC, who, usdc.balanceOf(who) + amount);
        vm.prank(who);
        usdc.approve(spender, amount);
    }

    function _fiat() internal pure returns (IFiatToken) {
        return IFiatToken(USDC);
    }

    // ---------------------------------------------------------------- Circles

    function _members(uint256 n, string memory tag) internal returns (address[] memory m) {
        m = new address[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = makeAddr(string.concat(tag, vm.toString(i)));
        }
    }

    function _accumulation(bytes32 id, address[] memory members, uint32 rounds, uint16 fee)
        internal
        returns (MHAccumulationCircle c)
    {
        AccumulationParams memory p;
        p.config = AccumulationConfig({
            circleId: id,
            contribution: 1_000e6,
            feeBps: fee,
            roundDuration: 30 days,
            grace: 48 hours,
            cure: 72 hours,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            totalRounds: rounds,
            vault: GAUNTLET,
            lockUntilMaturity: false
        });
        p.members = members;
        vm.prank(operator);
        c = MHAccumulationCircle(factory.createAccumulation(p));
        for (uint256 i; i < members.length; ++i) {
            bytes32 terms = c.termsHash();
            vm.prank(members[i]);
            c.join(terms, 0);
        }
        vm.warp(c.startTime());
    }

    function _rotating(bytes32 id, address[] memory members, uint16 fee)
        internal
        returns (MHRotatingCircle c)
    {
        RotatingParams memory p;
        p.config = RotatingConfig({
            circleId: id,
            contribution: 100e6,
            feeBps: fee,
            roundDuration: 30 days,
            grace: 48 hours,
            cure: 72 hours,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            // forge-lint: disable-next-line(unsafe-typecast)
            totalRounds: uint32(members.length)
        });
        p.members = members;
        p.securityBps = new uint16[](members.length);
        for (uint256 i; i < members.length; ++i) {
            p.securityBps[i] = 10_000;
        }
        vm.prank(operator);
        c = MHRotatingCircle(factory.createRotating(p));
        for (uint256 i; i < members.length; ++i) {
            bytes32 terms = c.termsHash();
            vm.prank(members[i]);
            c.join(terms, 0);
        }
        vm.warp(c.startTime());
    }

    /// @dev Every member pays round `round` of an accumulation circle (approve exact + contribute).
    function _payAcc(MHAccumulationCircle c, address[] memory members, uint256 round) internal {
        for (uint256 i; i < members.length; ++i) {
            uint256 due = c.amountDue(members[i], round);
            if (due == 0) continue;
            _fund(members[i], address(c), due);
            vm.prank(members[i]);
            c.contribute(round, due);
        }
    }

    // ---------------------------------------------------------------- Morpho Blue liquidity

    /// @dev The Gauntlet liquidity adapter's market (Vault V2 `liquidityData` is the abi-encoded MarketParams).
    function _liquidityMarket() internal view returns (MarketParams memory mp, bytes32 id) {
        bytes memory data = vault.liquidityData();
        mp = abi.decode(data, (MarketParams));
        id = keccak256(data);
    }
}
