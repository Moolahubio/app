// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BuildBaseBatch } from "../../script/BuildBaseBatch.s.sol";
import { VerifyBase } from "../../script/VerifyBase.s.sol";
import { CheckVaultPending } from "../../script/CheckVaultPending.s.sol";
import { MHVaultPending } from "../../script/ceremony/MHVaultPending.sol";
import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import {
    ISafe,
    ISafeProxyFactory,
    ICreateX,
    IMultiSendCallOnly
} from "../../script/ceremony/DeployInterfaces.sol";
import {
    MHDeployPlan,
    DeployConfig,
    SafeSpec,
    Plan,
    Call,
    Deployment
} from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "../../script/ceremony/MHManifestCheck.sol";

import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleRegistry } from "../../src/circles/MHCircleRegistry.sol";
import { MHCircleFactory } from "../../src/circles/MHCircleFactory.sol";
import { MHGuardianCanceller } from "../../src/circles/MHGuardianCanceller.sol";
import { IMHCircleFactory } from "../../src/circles/interfaces/IMHCircleFactory.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import {
    CircleStatus,
    RotatingConfig,
    RotatingParams,
    AccumulationConfig,
    AccumulationParams
} from "../../src/circles/MHCircleTypes.sol";

import { MockUSDC } from "../mocks/MockUSDC.sol";
import { MockVaultV2 } from "../mocks/MockVaultV2.sol";

/// @dev Vault V2 `curator()` (VaultV2.sol @ abaae813).
interface IVaultCurator {
    function curator() external view returns (address);
}

/// @notice Spec §5 deployment rehearsal on a Base mainnet fork. Skipped unless `BASE_RPC_URL` is set (pinned block
///         `BASE_FORK_BLOCK`, default 52,933,005; the RPC must serve that state).
///         - Deploys three real Safes (SafeL2 v1.4.1 through the canonical SafeProxyFactory) with test owners:
///           Gov 3-of-5, Guardian 2-of-4, Treasury 2-of-3.
///         - Runs `BuildBaseBatch` (validation, plan, simulation, files), reads the Transaction Builder files back,
///           and executes both batches through the real Gov Safe with pranked `approveHash` signatures, exactly
///           as the files say (MultiSendCallOnly DELEGATECALL, CreateX `deployCreate3`).
///         - Runs every `VerifyBase` assertion, then a smoke test: the allowVault proposal files through the
///           Timelock, Guardian pause and cancel (and its rotation it cannot cancel), a rotating circle to
///           completion on real USDC, and an accumulation circle deposited into Gauntlet.
///         - Every `BuildBaseBatch` refusal and the main `VerifyBase` tamper cases.
///         Tests never write the environment except `test_env_*`, so they stay independent when run in parallel.
contract SafeDeployRehearsalTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 52_933_005;
    address internal constant USDC = BaseChain.USDC_BASE;
    address internal constant GAUNTLET = 0x050cE30b927Da55177A4914EC73480238BAD56f0;
    address internal constant GAUNTLET_LIQUIDITY_ADAPTER = 0x2fEcd40f436CA170D2478a58Da898FcE93988eef;
    address internal constant STEAKHOUSE = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9;
    string internal constant COMMIT = "0123456789abcdef0123456789abcdef01234567";
    string internal constant OUT = "deployments/rehearsal/";

    BuildBaseBatch internal builder;
    VerifyBase internal verifier;

    address[] internal govOwners;
    address[] internal guardianOwners;
    address[] internal treasuryOwners;
    ISafe internal gov;
    ISafe internal guardian;
    ISafe internal treasury;
    address internal operator = makeAddr("operator");
    /// @dev The EOA that submits every Safe transaction: a "deployment EOA" for VerifyBase.
    address internal executor = makeAddr("safeExecutor");
    uint256 internal saltNonce;

    // Set by `_deployAll`.
    Plan internal plan;
    VerifyBase.RoleEvent[] internal roleEvents;
    uint256 internal gasBatch1a;
    uint256 internal gasBatch1b;
    uint256 internal gasBatch2;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL not set");
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("BASE_FORK_BLOCK", DEFAULT_FORK_BLOCK));
        builder = new BuildBaseBatch();
        verifier = new VerifyBase();
        govOwners = _owners("gov", 5);
        guardianOwners = _owners("guardian", 4);
        treasuryOwners = _owners("treasury", 3);
        gov = _newSafe(govOwners, 3);
        guardian = _newSafe(guardianOwners, 2);
        treasury = _newSafe(treasuryOwners, 2);
    }

    // ================================================================ Appendix A

    /// @dev Every Appendix A address has code on the fork and matches its pinned codehash; a fresh proxy from the
    ///      canonical factory has the pinned SafeProxy codehash; the local CREATE3 formula agrees with CreateX.
    function test_appendixA_codeAndCodehashes() public view {
        address[9] memory a = [
            USDC,
            GAUNTLET,
            GAUNTLET_LIQUIDITY_ADAPTER,
            STEAKHOUSE,
            BaseChain.SAFE_L2,
            BaseChain.SAFE_PROXY_FACTORY,
            BaseChain.MULTISEND_CALL_ONLY,
            BaseChain.FALLBACK_HANDLER,
            BaseChain.CREATEX
        ];
        for (uint256 i; i < a.length; ++i) {
            assertGt(a[i].code.length, 0, "Appendix A address without code");
        }
        assertEq(USDC.codehash, BaseChain.USDC_BASE_CODEHASH, "USDC proxy");
        assertEq(BaseChain.SAFE_L2.codehash, BaseChain.SAFE_L2_CODEHASH, "SafeL2");
        assertEq(BaseChain.SAFE_PROXY_FACTORY.codehash, BaseChain.SAFE_PROXY_FACTORY_CODEHASH, "factory");
        assertEq(BaseChain.MULTISEND_CALL_ONLY.codehash, BaseChain.MULTISEND_CALL_ONLY_CODEHASH, "MultiSend");
        assertEq(BaseChain.FALLBACK_HANDLER.codehash, BaseChain.FALLBACK_HANDLER_CODEHASH, "fallback");
        assertEq(BaseChain.CREATEX.codehash, BaseChain.CREATEX_CODEHASH, "CreateX");
        assertEq(address(gov).codehash, BaseChain.SAFE_PROXY_CODEHASH, "SafeProxy");
        assertEq(gov.VERSION(), "1.4.1");
        for (uint256 i; i < 8; ++i) {
            (, bytes32 guarded) = MHDeployPlan.guardedSalt(address(gov), block.chainid, bytes32(i + 1), "x");
            assertEq(
                MHDeployPlan.create3Address(guarded),
                ICreateX(BaseChain.CREATEX).computeCreate3Address(guarded, BaseChain.CREATEX),
                "CREATE3 formula"
            );
        }
    }

    // ================================================================ Full ceremony

    function test_rehearsal_fullCeremony() public {
        uint256 t0 = block.timestamp;
        _deployAll("ceremony");
        // The build's simulation (which warps through the allowVault delay) left no trace.
        assertEq(t0, block.timestamp, "simulation reverted the clock");

        // The build simulates with every touched account cold, so it is an upper bound on the executed gas (here
        // some accounts are already warm) and within 1% of it; both within the 10M budget.
        assertLe(gasBatch1a, plan.batch1a.txGas, "batch 1a: simulation is conservative");
        assertLe(gasBatch1b, plan.batch1b.txGas, "batch 1b: simulation is conservative");
        assertLe(gasBatch2, plan.batch2.txGas, "batch 2: simulation is conservative");
        assertApproxEqRel(gasBatch1a, plan.batch1a.txGas, 0.01e18, "batch 1a gas matches simulation");
        assertApproxEqRel(gasBatch1b, plan.batch1b.txGas, 0.01e18, "batch 1b gas matches simulation");
        assertApproxEqRel(gasBatch2, plan.batch2.txGas, 0.01e18, "batch 2 gas matches simulation");
        assertLe(gasBatch1a, BaseChain.MAX_BATCH_GAS, "batch 1a <= 10M");
        assertLe(gasBatch1b, BaseChain.MAX_BATCH_GAS, "batch 1b <= 10M");
        assertLe(gasBatch2, BaseChain.MAX_BATCH_GAS, "batch 2 <= 10M");
        emit log_named_uint("batch 1a tx gas", gasBatch1a);
        emit log_named_uint("batch 1b tx gas", gasBatch1b);
        emit log_named_uint("batch 2 tx gas", gasBatch2);

        // Runtime and initcode within the EIP-170 / EIP-3860 limits (forge test does not enforce them).
        for (uint256 i; i < plan.deployments.length; ++i) {
            assertLe(plan.deployments[i].addr.code.length, 24_576, "runtime size");
            assertLe(plan.deployments[i].initCode.length, 49_152, "initcode size");
            assertEq(plan.deployments[i].addr.codehash, plan.deployments[i].runtimeCodeHash, "codehash");
        }

        // Every VerifyBase assertion, with the Safe-tx executor and this test (standing in for the script
        // sender) as deployment EOAs.
        verifier.verify(_manifest("ceremony"), _deployEoas(), roleEvents);
        assertEq(gov.nonce(), 3, "three Gov Safe transactions");
    }

    /// @dev The manifest and every batch file are byte-identical across two independent builds.
    function test_rehearsal_reproducibleManifest() public {
        builder.build(_cfg(), string.concat(OUT, "repro-a"));
        builder.build(_cfg(), string.concat(OUT, "repro-b"));
        string[6] memory files = [
            "manifest.json",
            "batch1a-rotating-implementation.safe.json",
            "batch1b-accumulation-implementation.safe.json",
            "batch2-governance.safe.json",
            "proposal-allow-vault.schedule.safe.json",
            "proposal-allow-vault.execute.safe.json"
        ];
        for (uint256 i; i < files.length; ++i) {
            string memory a = vm.readFile(string.concat(OUT, "repro-a/", files[i]));
            string memory b = vm.readFile(string.concat(OUT, "repro-b/", files[i]));
            assertGt(bytes(a).length, 0);
            assertEq(keccak256(bytes(a)), keccak256(bytes(b)), files[i]);
        }
    }

    /// @dev The manifest records what the plan computed, and the batch files carry exactly the planned calls.
    function test_rehearsal_manifestAndFilesMatchPlan() public {
        Plan memory p = builder.build(_cfg(), string.concat(OUT, "match"));
        string memory dir = string.concat(OUT, "match/");
        string memory m = vm.readFile(string.concat(dir, "manifest.json"));
        assertEq(vm.parseJsonUint(m, ".chainId"), 8453);
        assertEq(vm.parseJsonString(m, ".network"), "base-mainnet");
        assertEq(vm.parseJsonString(m, ".commit"), COMMIT);
        assertEq(
            vm.parseJsonAddress(m, ".contracts.factory.address"), MHDeployPlan.at(p, MHDeployPlan.FACTORY)
        );
        assertEq(vm.parseJsonBytes32(m, ".batches.batch1a.safeTxHash"), p.batch1a.safeTxHash);
        assertEq(vm.parseJsonBytes32(m, ".batches.batch1b.safeTxHash"), p.batch1b.safeTxHash);
        assertEq(vm.parseJsonBytes32(m, ".batches.batch2.safeTxHash"), p.batch2.safeTxHash);
        assertEq(vm.parseJsonUint(m, ".batches.batch1b.nonce"), 1);
        assertEq(vm.parseJsonUint(m, ".batches.batch2.nonce"), 2);
        assertEq(vm.parseJsonAddress(m, ".batches.batch1a.to"), BaseChain.CREATEX);
        assertEq(vm.parseJsonUint(m, ".batches.batch1a.operation"), 0);
        assertEq(vm.parseJsonAddress(m, ".batches.batch2.to"), BaseChain.MULTISEND_CALL_ONLY);
        assertEq(vm.parseJsonUint(m, ".batches.batch2.operation"), 1);
        assertEq(vm.parseJsonBytes32(m, ".allowVaultProposal.operationId"), p.allowVault.operationId);
        for (uint256 i; i < p.deployments.length; ++i) {
            string memory k = string.concat(".contracts.", p.deployments[i].key);
            bytes32 salt = vm.parseJsonBytes32(m, string.concat(k, ".salt"));
            // Guarded salt layout: GovSafe ‖ 0x01 ‖ 11 bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(address(bytes20(salt)), address(gov), "salt sender bytes");
            assertEq(uint8(salt[20]), 1, "salt redeploy-protection byte");
            assertEq(
                vm.parseJsonBytes32(m, string.concat(k, ".initCodeHash")),
                keccak256(p.deployments[i].initCode)
            );
            assertEq(
                vm.parseJsonBytes32(m, string.concat(k, ".runtimeCodeHash")), p.deployments[i].runtimeCodeHash
            );
        }
        // Batch files → MultiSend payload → the manifest's safeTxHash, independently of the builder.
        (Call[] memory c1a,) = _readBatchFile(string.concat(dir, "batch1a-rotating-implementation.safe.json"));
        (Call[] memory c1b,) =
            _readBatchFile(string.concat(dir, "batch1b-accumulation-implementation.safe.json"));
        (Call[] memory c2,) = _readBatchFile(string.concat(dir, "batch2-governance.safe.json"));
        assertEq(c1a.length, 1);
        assertEq(c1b.length, 1);
        assertEq(c2.length, 7);
        // A one-call file is sent by Safe{Wallet} as a plain CALL; the manifest's hash is that transaction's.
        assertEq(
            gov.getTransactionHash(c1a[0].to, 0, c1a[0].data, 0, 0, 0, 0, address(0), address(0), 0),
            p.batch1a.safeTxHash
        );
        assertEq(
            gov.getTransactionHash(c1b[0].to, 0, c1b[0].data, 0, 0, 0, 0, address(0), address(0), 1),
            p.batch1b.safeTxHash
        );
        assertEq(
            gov.getTransactionHash(
                BaseChain.MULTISEND_CALL_ONLY, 0, _multiSend(c2), 1, 0, 0, 0, address(0), address(0), 2
            ),
            p.batch2.safeTxHash
        );
        // Every inner call targets CreateX or the (predicted) Timelock, with no value.
        for (uint256 i; i < c2.length; ++i) {
            assertEq(c2[i].value, 0);
            assertTrue(c2[i].to == BaseChain.CREATEX || c2[i].to == MHDeployPlan.at(p, MHDeployPlan.TIMELOCK));
        }
        // The files' Transaction Builder checksum is what tx-builder's `validateChecksum` recomputes (see
        // TxBuilderChecksum.t.sol for the serializer against a reference vector).
        string memory f = vm.readFile(string.concat(dir, "batch1a-rotating-implementation.safe.json"));
        assertEq(vm.parseJsonString(f, ".chainId"), "8453");
        assertEq(vm.parseJsonUint(f, ".createdAt"), 0);
        assertEq(vm.parseJsonAddress(f, ".meta.createdFromSafeAddress"), address(gov));
    }

    // ================================================================ Smoke after deployment

    function test_rehearsal_smoke_allowVaultProposalAndGuardian() public {
        _deployAll("smoke-gov");
        TimelockController tl = _timelock();
        MHCircleRegistry registry = _registry();
        MHGuardianCanceller canceller = MHGuardianCanceller(MHDeployPlan.at(plan, MHDeployPlan.CANCELLER));

        // allowVault through the Timelock, from the generated proposal files.
        string memory dir = string.concat(OUT, "smoke-gov/");
        _execFile(gov, string.concat(dir, "proposal-allow-vault.schedule.safe.json"));
        assertTrue(tl.isOperationPending(plan.allowVault.operationId));
        vm.warp(block.timestamp + plan.allowVault.delay - 1);
        vm.expectRevert();
        this.execFileExternal(gov, string.concat(dir, "proposal-allow-vault.execute.safe.json"));
        vm.warp(block.timestamp + 1);
        _execFile(gov, string.concat(dir, "proposal-allow-vault.execute.safe.json"));
        assertTrue(registry.isAllowedVault(GAUNTLET), "Gauntlet allowlisted via the Timelock");

        // Gov schedules a treasury change; the Guardian vetoes it through the canceller.
        address newTreasury = makeAddr("newTreasury");
        bytes memory setTreasury = abi.encodeCall(registry.setTreasury, (newTreasury));
        _execSafe(
            gov,
            address(tl),
            abi.encodeCall(tl.schedule, (address(registry), 0, setTreasury, 0, "t", 2 days)),
            0
        );
        bytes32 id = tl.hashOperation(address(registry), 0, setTreasury, 0, "t");
        assertTrue(tl.isOperationPending(id));
        _execSafe(
            guardian,
            address(canceller),
            abi.encodeCall(canceller.cancel, (address(registry), 0, setTreasury, 0, "t")),
            0
        );
        assertFalse(tl.isOperation(id), "Guardian cancelled the treasury change");

        // Gov rotates the Guardian: the Guardian cannot cancel that.
        address newGuardian = makeAddr("newGuardian");
        bytes memory rotate = abi.encodeCall(registry.setGuardian, (newGuardian));
        _execSafe(
            gov, address(tl), abi.encodeCall(tl.schedule, (address(registry), 0, rotate, 0, "r", 2 days)), 0
        );
        vm.expectRevert(); // MHGuardianCanceller.RotationOnly bubbles as Safe GS013
        this.execSafeExternal(
            guardian,
            address(canceller),
            abi.encodeCall(canceller.cancel, (address(registry), 0, rotate, 0, "r"))
        );
        assertTrue(tl.isOperationPending(tl.hashOperation(address(registry), 0, rotate, 0, "r")));

        // Guardian pauses creation instantly; only the Timelock can unpause.
        _execSafe(guardian, address(registry), abi.encodeCall(registry.pauseCreation, ()), 0);
        RotatingParams memory rp = _rotatingParams(keccak256("paused"), _members(3, "p"));
        vm.prank(operator);
        vm.expectRevert(IMHCircleFactory.CreationPaused.selector);
        _factory().createRotating(rp);
        vm.prank(address(guardian));
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(guardian))
        );
        registry.unpauseCreation();
    }

    function test_rehearsal_smoke_rotatingLifecycle() public {
        _deployAll("smoke-rot");
        MHCircleFactory factory = _factory();
        address[] memory m = _members(3, "rot");
        vm.prank(operator);
        MHRotatingCircle c =
            MHRotatingCircle(factory.createRotating(_rotatingParams(keccak256("smoke-rot"), m)));
        assertTrue(factory.isCircle(address(c)));
        assertEq(address(c), factory.predictAddress(keccak256("smoke-rot"), c.circleMode()));
        for (uint256 i; i < 3; ++i) {
            bytes32 terms = c.termsHash();
            vm.prank(m[i]);
            c.join(terms, 0);
        }
        vm.warp(c.startTime());
        for (uint256 r = 1; r <= 3; ++r) {
            uint256 open = c.startTime() + (r - 1) * c.roundDuration();
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < open) vm.warp(open);
            for (uint256 i; i < 3; ++i) {
                uint256 due = c.amountDue(m[i], r);
                if (due == 0) continue;
                _fund(m[i], address(c), due);
                vm.prank(m[i]);
                c.contribute(r, due);
            }
            c.settleRound();
        }
        assertEq(uint8(c.status()), uint8(CircleStatus.Completed));
        for (uint256 i; i < 3; ++i) {
            uint256 sec = c.memberState(m[i]).sec;
            if (sec != 0) {
                vm.prank(m[i]);
                c.withdrawSecurity(sec);
            }
        }
        // Fee 0 at launch: every member gets back exactly what it paid in; the circle ends empty.
        for (uint256 i; i < 3; ++i) {
            assertEq(IUSDC(USDC).balanceOf(m[i]), c.memberState(m[i]).cashIn, "member whole");
        }
        assertEq(IUSDC(USDC).balanceOf(address(c)), 0);
    }

    function test_rehearsal_smoke_accumulationOnGauntlet() public {
        _deployAll("smoke-acc");
        string memory dir = string.concat(OUT, "smoke-acc/");
        _execFile(gov, string.concat(dir, "proposal-allow-vault.schedule.safe.json"));
        vm.warp(block.timestamp + plan.allowVault.delay);
        _execFile(gov, string.concat(dir, "proposal-allow-vault.execute.safe.json"));

        address[] memory m = _members(2, "acc");
        AccumulationParams memory ap;
        ap.config = AccumulationConfig({
            circleId: keccak256("smoke-acc"),
            contribution: 100e6,
            feeBps: 0,
            roundDuration: 30 days,
            grace: 48 hours,
            cure: 72 hours,
            joinDeadline: uint64(block.timestamp + 7 days),
            plannedStart: uint64(block.timestamp + 7 days),
            totalRounds: 2,
            vault: GAUNTLET,
            lockUntilMaturity: false
        });
        ap.members = m;
        vm.prank(operator);
        MHAccumulationCircle c = MHAccumulationCircle(_factory().createAccumulation(ap));
        for (uint256 i; i < 2; ++i) {
            bytes32 terms = c.termsHash();
            vm.prank(m[i]);
            c.join(terms, 0);
        }
        vm.warp(c.startTime());
        for (uint256 i; i < 2; ++i) {
            uint256 due = c.amountDue(m[i], 1);
            _fund(m[i], address(c), due);
            vm.prank(m[i]);
            c.contribute(1, due);
        }
        c.deployIdle();
        assertGt(c.vaultShares(), 0, "deposited into Gauntlet");
        assertEq(IVaultV2(GAUNTLET).balanceOf(address(c)), c.vaultShares());
    }

    // ================================================================ VerifyBase tamper cases

    /// @dev Audit 2 R1-14 (b): both branches. A tampered manifest value (`factory manifest runtime codehash`) and,
    ///      separately, other code substituted at the factory's address with the honest manifest (`factory runtime
    ///      codehash`, the R2-04 on-chain comparison this test used to miss).
    function test_verify_rejectsWrongCodehash() public {
        _deployAll("v-codehash");
        VerifyBase.Manifest memory m = _manifest("v-codehash");
        m.runtimeCodeHash[MHDeployPlan.FACTORY] = keccak256("other");
        vm.expectRevert(
            abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "factory manifest runtime codehash")
        );
        verifier.verify(m, _deployEoas(), roleEvents);

        m = _manifest("v-codehash");
        vm.etch(m.factory, m.registry.code);
        vm.expectRevert(abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "factory runtime codehash"));
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    function test_verify_rejectsDeployEoaWithRole() public {
        _deployAll("v-eoa");
        VerifyBase.Manifest memory m = _manifest("v-eoa");
        address[] memory eoas = new address[](2);
        eoas[0] = executor;
        eoas[1] = operator;
        vm.expectRevert(
            abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "deploy EOA holds a registry role")
        );
        verifier.verify(m, eoas, roleEvents);
    }

    function test_verify_rejectsExtraTimelockRole() public {
        _deployAll("v-role");
        VerifyBase.Manifest memory m = _manifest("v-role");
        TimelockController tl = _timelock();
        address attacker = makeAddr("attacker");
        bytes memory grant = abi.encodeCall(tl.grantRole, (tl.PROPOSER_ROLE(), attacker));
        vm.recordLogs();
        _govTimelock(address(tl), grant);
        VerifyBase.RoleEvent[] memory events = _append(roleEvents, _roleEventsFromLogs(vm.getRecordedLogs()));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "Timelock: unexpected role holder in logs"
            )
        );
        verifier.verify(m, _deployEoas(), events);
        // Without the logs, the hasRole matrix still catches a grant to a known address.
        bytes memory grantOperator = abi.encodeCall(tl.grantRole, (tl.EXECUTOR_ROLE(), operator));
        _govTimelock(address(tl), grantOperator);
        vm.expectRevert(abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "Timelock role matrix"));
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    function test_verify_rejectsPendingOwner() public {
        _deployAll("v-owner");
        VerifyBase.Manifest memory m = _manifest("v-owner");
        _govTimelock(address(_registry()), abi.encodeCall(Ownable.transferOwnership, (makeAddr("next"))));
        vm.expectRevert(
            abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "registry pendingOwner == 0")
        );
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    function test_verify_rejectsSafeModule() public {
        _deployAll("v-module");
        VerifyBase.Manifest memory m = _manifest("v-module");
        vm.prank(address(guardian));
        guardian.enableModule(makeAddr("module"));
        vm.expectRevert(abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "guardian Safe: no modules"));
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    function test_verify_rejectsMissingRoleLogs() public {
        _deployAll("v-logs");
        VerifyBase.Manifest memory m = _manifest("v-logs");
        VerifyBase.RoleEvent[] memory none;
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "Timelock role logs found (check BATCH2_BLOCK)"
            )
        );
        verifier.verify(m, _deployEoas(), none);
    }

    /// @dev An implementation whose initializers were never disabled fails both implementation checks.
    function test_verify_rejectsInitializableImplementation() public {
        _deployAll("v-init");
        VerifyBase.Manifest memory m = _manifest("v-init");
        address impl = plan.deployments[MHDeployPlan.ROTATING_IMPL].addr;
        // Clear the Initializable slot: `initialize` would then be callable on the implementation.
        vm.store(impl, 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "rotating implementation initializers disabled"
            )
        );
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    // ================================================================ BuildBaseBatch refusals

    function test_build_rejectsUnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.UnsupportedChain.selector, 1));
        builder.validate(_cfg());
    }

    function test_build_rejectsWrongUsdc() public {
        DeployConfig memory c = _cfg();
        c.usdc = BaseChain.USDC_BASE_SEPOLIA;
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.WrongUsdc.selector, USDC, c.usdc));
        builder.validate(c);
    }

    function test_build_rejectsTamperedExternalCode() public {
        vm.etch(BaseChain.CREATEX, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                BuildBaseBatch.CodehashMismatch.selector,
                "CreateX",
                BaseChain.CREATEX,
                BaseChain.CREATEX_CODEHASH,
                keccak256(hex"00")
            )
        );
        builder.validate(_cfg());
    }

    function test_build_rejectsZeroRoles() public {
        DeployConfig memory c = _cfg();
        c.operator = address(0);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.ZeroRole.selector, "OPERATOR"));
        builder.validate(c);
        c = _cfg();
        c.treasury.safe = address(0);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.ZeroRole.selector, "TREASURY_SAFE"));
        builder.validate(c);
    }

    function test_build_rejectsDuplicateRoles() public {
        DeployConfig memory c = _cfg();
        c.treasury = c.guardian;
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.DuplicateRole.selector, "GUARDIAN_SAFE", "TREASURY_SAFE")
        );
        builder.validate(c);
        c = _cfg();
        c.earnWrapper = c.circleVault;
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.DuplicateRole.selector, "CIRCLE_VAULT", "EARN_WRAPPER")
        );
        builder.validate(c);
    }

    function test_build_rejectsRoleEqualToSender() public {
        DeployConfig memory c = _cfg();
        c.operator = address(this); // the builder's msg.sender
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.RoleIsSender.selector, "OPERATOR", address(this))
        );
        builder.validate(c);
    }

    function test_build_rejectsSafeNotAContract() public {
        DeployConfig memory c = _cfg();
        c.treasury.safe = makeAddr("eoaTreasury");
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.NotAContract.selector, "treasury", c.treasury.safe)
        );
        builder.validate(c);
    }

    function test_build_rejectsSafeOwnerMismatch() public {
        DeployConfig memory c = _cfg();
        c.gov.owners[2] = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeOwnersMismatch.selector, "gov"));
        builder.validate(c);
        c = _cfg();
        address[] memory four = new address[](4);
        for (uint256 i; i < 4; ++i) {
            four[i] = govOwners[i];
        }
        c.gov.owners = four;
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeOwnersMismatch.selector, "gov"));
        builder.validate(c);
        c = _cfg();
        c.gov.owners[1] = c.gov.owners[0];
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.SafeOwnerInvalid.selector, "gov", c.gov.owners[0])
        );
        builder.validate(c);
    }

    function test_build_rejectsSafeThresholdMismatch() public {
        DeployConfig memory c = _cfg();
        c.gov.threshold = 2;
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeThresholdMismatch.selector, "gov", 2, 3));
        builder.validate(c);
    }

    function test_build_rejectsSafeThresholdPolicy() public {
        DeployConfig memory c = _cfg();
        c.treasury = _spec(_newSafe(treasuryOwners, 1), treasuryOwners, 1);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeThresholdPolicy.selector, "treasury", 1, 3));
        builder.validate(c);
        c.treasury = _spec(_newSafe(treasuryOwners, 3), treasuryOwners, 3);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeThresholdPolicy.selector, "treasury", 3, 3));
        builder.validate(c);
    }

    function test_build_rejectsSafeModule() public {
        vm.prank(address(gov));
        gov.enableModule(makeAddr("module"));
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeHasModules.selector, "gov"));
        builder.validate(_cfg());
    }

    function test_build_rejectsSafeGuard() public {
        address guard = makeAddr("guard");
        vm.store(address(guardian), BaseChain.SAFE_GUARD_SLOT, bytes32(uint256(uint160(guard))));
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeHasGuard.selector, "guardian", guard));
        builder.validate(_cfg());
    }

    function test_build_rejectsSafeSingletonAndHandler() public {
        address other = makeAddr("singleton");
        vm.store(address(treasury), BaseChain.SAFE_SINGLETON_SLOT, bytes32(uint256(uint160(other))));
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.SafeSingletonMismatch.selector, "treasury", other)
        );
        builder.validate(_cfg());
        vm.store(
            address(treasury), BaseChain.SAFE_SINGLETON_SLOT, bytes32(uint256(uint160(BaseChain.SAFE_L2)))
        );
        vm.store(address(treasury), BaseChain.SAFE_FALLBACK_HANDLER_SLOT, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                BuildBaseBatch.SafeFallbackHandlerMismatch.selector, "treasury", address(0)
            )
        );
        builder.validate(_cfg());
    }

    function test_build_rejectsSharedKeysAndOperatorOwner() public {
        address[] memory mixed = _owners("guardianMixed", 4);
        mixed[3] = govOwners[0];
        DeployConfig memory c = _cfg();
        c.guardian = _spec(_newSafe(mixed, 2), mixed, 2);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.SafeKeysShared.selector, govOwners[0]));
        builder.validate(c);
        c = _cfg();
        c.operator = treasuryOwners[1];
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.OperatorIsSafeOwner.selector, treasuryOwners[1])
        );
        builder.validate(c);
    }

    function test_build_rejectsBadVaultAndWrapper() public {
        MockUSDC other = new MockUSDC();
        MockVaultV2 notUsdc = new MockVaultV2(address(other), address(this));
        DeployConfig memory c = _cfg();
        c.circleVault = address(notUsdc);
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.VaultNotUsdc.selector, address(notUsdc), address(other))
        );
        builder.validate(c);
        c = _cfg();
        c.circleVault = STEAKHOUSE; // allocator timelock 0 at the pinned block
        vm.expectRevert(
            abi.encodeWithSelector(
                BuildBaseBatch.VaultCheckFailed.selector, STEAKHOUSE, IVaultV2.setIsAllocator.selector
            )
        );
        builder.validate(c);
        c = _cfg();
        c.earnWrapper = address(notUsdc);
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.WrapperNotUsdc.selector, address(notUsdc), address(other))
        );
        builder.validate(c);
        c = _cfg();
        c.circleVault = makeAddr("noCode");
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.NotAContract.selector, "CIRCLE_VAULT", c.circleVault)
        );
        builder.validate(c);
    }

    function test_build_rejectsFeesAboveCaps() public {
        DeployConfig memory c = _cfg();
        c.rotatingFeeBps = 201;
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.FeeAboveCap.selector, "ROTATING_FEE_BPS", 201, 200)
        );
        builder.validate(c);
        c = _cfg();
        c.accumulationFeeBps = 1_501;
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.FeeAboveCap.selector, "ACCUMULATION_FEE_BPS", 1_501, 1_500)
        );
        builder.validate(c);
        c.accumulationFeeBps = 1_500;
        c.rotatingFeeBps = 200;
        builder.validate(c); // at the caps is fine
    }

    function test_build_rejectsDelaySeedCommitAndNonce() public {
        DeployConfig memory c = _cfg();
        c.timelockDelay = 48 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.DelayOutOfRange.selector, 48 hours - 1));
        builder.validate(c);
        c.timelockDelay = 7 days + 1;
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.DelayOutOfRange.selector, 7 days + 1));
        builder.validate(c);
        c = _cfg();
        c.saltSeed = 0;
        vm.expectRevert(BuildBaseBatch.ZeroSaltSeed.selector);
        builder.validate(c);
        c = _cfg();
        c.commit = "0123456789ABCDEF0123456789abcdef01234567";
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.BadCommit.selector, c.commit));
        builder.validate(c);
        c = _cfg();
        vm.store(address(gov), BaseChain.SAFE_NONCE_SLOT, bytes32(uint256(4)));
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.NonceAlreadyUsed.selector, 4, 0));
        builder.validate(c);
    }

    /// @dev After batch 1a runs, a rebuild with the same seed refuses: the implementation address is taken.
    function test_build_rejectsUsedSalts() public {
        Plan memory p = builder.build(_cfg(), string.concat(OUT, "used"));
        _execFile(gov, string.concat(OUT, "used/batch1a-rotating-implementation.safe.json"));
        DeployConfig memory c = _cfg();
        c.govNonce = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                BuildBaseBatch.AddressInUse.selector,
                "rotatingImpl",
                MHDeployPlan.at(p, MHDeployPlan.ROTATING_IMPL)
            )
        );
        builder.build(c, string.concat(OUT, "used-again"));
    }

    /// @dev A pending nonce gap is allowed (the simulation sets the nonce), and the hashes follow the nonce.
    function test_build_futureNonce() public {
        DeployConfig memory c = _cfg();
        c.govNonce = 7;
        Plan memory p = builder.build(c, string.concat(OUT, "nonce7"));
        assertEq(p.batch1a.nonce, 7);
        assertEq(p.batch1b.nonce, 8);
        assertEq(p.batch2.nonce, 9);
        assertEq(gov.nonce(), 0, "simulation left the Safe untouched");
    }

    /// @dev Without a circle vault there is no proposal (no-yield circles first); the wrapper may be set.
    function test_build_noVaultWithWrapper() public {
        DeployConfig memory c = _cfg();
        c.circleVault = address(0);
        c.earnWrapper = GAUNTLET;
        Plan memory p = builder.build(c, string.concat(OUT, "novault"));
        assertFalse(p.hasProposal);
        string memory m = vm.readFile(string.concat(OUT, "novault/manifest.json"));
        assertEq(vm.parseJsonAddress(m, ".roles.earnWrapper"), GAUNTLET);
        assertEq(vm.parseJsonAddress(m, ".roles.circleVault"), address(0));
        assertFalse(vm.exists(string.concat(OUT, "novault/proposal-allow-vault.schedule.safe.json")));
        assertEq(MHDeployPlan.at(p, MHDeployPlan.CANCELLER).code.length, 0, "simulation reverted");
    }

    // ================================================================ Environment (the only env-writing test)

    /// @dev Audit 2 R1-13 / R1-14 (a): `run()` end to end. The pending-submission scan and its inputs come before
    ///      anything is written, so a missing `CIRCLE_VAULT_FROM_BLOCK` or a scan that aborts leaves no ceremony
    ///      files (the PoC found all five on disk, passing the signer-side check); `SKIP_VAULT_SCAN` is honoured inside
    ///      `forge test` only, and with it the run succeeds and writes every file. Run alone (it writes the process
    ///      environment).
    function test_env_loadConfigAndRun() public {
        DeployConfig memory c = _cfg();
        _setEnv(c);
        string memory dir = string.concat(OUT, "env");
        vm.setEnv("DEPLOY_OUT_DIR", dir);
        DeployConfig memory l = builder.loadConfig();
        assertEq(keccak256(abi.encode(l)), keccak256(abi.encode(c)), "env round-trip");

        _cleanCeremony(dir);
        vm.setEnv("SKIP_VAULT_SCAN", "false");
        assertFalse(vm.envExists("CIRCLE_VAULT_FROM_BLOCK"), "run this test alone");
        vm.expectRevert(BuildBaseBatch.VaultScanInputMissing.selector);
        builder.run();
        _assertNoCeremony(dir);

        // A real scan abort (the vault was not created in blocks 16-25): still nothing on disk. On a rate-limited
        // public RPC the scan can abort with the `eth_getLogs` cheatcode error instead; both come before any write.
        vm.setEnv("CIRCLE_VAULT_FROM_BLOCK", "16");
        vm.setEnv("LOG_CHUNK", "10");
        bytes memory notFound = abi.encodeWithSelector(
            MHVaultPending.VaultCreationNotFound.selector,
            GAUNTLET,
            BaseChain.VAULT_V2_FACTORY_BASE,
            uint256(16),
            uint256(25)
        );
        try builder.run() {
            fail();
        } catch (bytes memory err) {
            assertTrue(
                keccak256(err) == keccak256(notFound)
                    || vm.indexOf(string(err), "eth_getLogs") != type(uint256).max,
                "the scan aborted"
            );
        }
        _assertNoCeremony(dir);

        vm.setEnv("SKIP_VAULT_SCAN", "true");
        builder.run();
        assertGt(bytes(vm.readFile(string.concat(dir, "/manifest.json"))).length, 0);
        assertTrue(vm.exists(string.concat(dir, "/batch1a-rotating-implementation.safe.json")));
        assertTrue(vm.exists(string.concat(dir, "/proposal-allow-vault.execute.safe.json")));
        this.checkManifestExternal(dir);
        vm.setEnv("SKIP_VAULT_SCAN", "false");
        // No defaults: an unset/empty variable makes the script revert.
        vm.setEnv("TIMELOCK_DELAY", "");
        vm.expectRevert();
        builder.loadConfig();
    }

    function _ceremonyFiles() internal pure returns (string[6] memory) {
        return [
            "/manifest.json",
            "/batch1a-rotating-implementation.safe.json",
            "/batch1b-accumulation-implementation.safe.json",
            "/batch2-governance.safe.json",
            "/proposal-allow-vault.schedule.safe.json",
            "/proposal-allow-vault.execute.safe.json"
        ];
    }

    function _cleanCeremony(string memory dir) internal {
        string[6] memory f = _ceremonyFiles();
        for (uint256 i; i < f.length; ++i) {
            if (vm.exists(string.concat(dir, f[i]))) vm.removeFile(string.concat(dir, f[i]));
        }
    }

    function _assertNoCeremony(string memory dir) internal {
        string[6] memory f = _ceremonyFiles();
        for (uint256 i; i < f.length; ++i) {
            assertFalse(vm.exists(string.concat(dir, f[i])), f[i]);
        }
    }

    // ================================================================ Audit 2, round 1

    /// @dev Audit 2 R1-14: `VerifyBase` end to end (`verifyAll`: the offline re-derivation, every on-chain assertion
    ///      and the governance queue) on a real three-batch deployment, with the logs recorded here (`run` reads the
    ///      same from an RPC, which a fork test cannot serve for locally executed transactions; the anvil runbook
    ///      covers `run` itself).
    function test_A2R1_14_verifyAll_endToEnd() public {
        _deployAll("v-all");
        verifier.verifyAll(
            string.concat(OUT, "v-all/manifest.json"),
            _deployEoas(),
            roleEvents,
            new bytes32[](0),
            new address[](0)
        );
        // A queued takeover fails the same call.
        TimelockController tl = _timelock();
        bytes memory grant = abi.encodeCall(IAccessControl.grantRole, (bytes32(0), makeAddr("attacker")));
        vm.recordLogs();
        _execSafe(
            gov,
            address(tl),
            abi.encodeCall(tl.schedule, (address(tl), 0, grant, 0, keccak256(grant), tl.getMinDelay())),
            0
        );
        bytes32[] memory ids = _scheduledIds(vm.getRecordedLogs(), address(tl));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "Timelock: an unexpected operation is pending"
            )
        );
        verifier.verifyAll(
            string.concat(OUT, "v-all/manifest.json"), _deployEoas(), roleEvents, ids, new address[](0)
        );
    }

    /// @dev Audit 2 R1-26: an operator with code (Multicall3, which makes itself `msg.sender` for anyone) is refused
    ///      by the build, offline by `CheckManifest`, and on chain by `VerifyBase`.
    function test_A2R1_26_operatorMustBeAnEoa() public {
        DeployConfig memory c = _cfg();
        c.operator = BaseChain.MULTICALL3;
        assertGt(BaseChain.MULTICALL3.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(BuildBaseBatch.OperatorNotEoa.selector, BaseChain.MULTICALL3));
        builder.validate(c);
        vm.expectRevert(
            abi.encodeWithSelector(
                MHManifestCheck.PolicyViolation.selector, "operator is not a known contract"
            )
        );
        this.policyExternal(c);

        _deployAll("v-r126");
        VerifyBase.Manifest memory m = _manifest("v-r126");
        vm.etch(m.operator, hex"00"); // the operator gained code (or an EIP-7702 delegation) after the build
        vm.expectRevert(abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "operator is an EOA"));
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    /// @notice `MHManifestCheck.policy` (external, so `expectRevert` can observe it).
    function policyExternal(DeployConfig memory c) external pure {
        MHManifestCheck.policy(c, 8453);
    }

    /// @dev Audit 2 R1-23: the mandatory per-proposal check pins provenance and the adapter registry for every vault,
    ///      and surfaces the instant powers for sign-off: on Gauntlet USDC Prime the curator is an allocator.
    function test_A2R1_23_checkVaultPending_provenanceAndRoleReview() public {
        CheckVaultPending check = new CheckVaultPending();
        check.checkProvenance(GAUNTLET);
        MockVaultV2 foreign = new MockVaultV2(USDC, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(CheckVaultPending.VaultNotFromFactory.selector, address(foreign))
        );
        check.checkProvenance(address(foreign));

        address curator = IVaultCurator(GAUNTLET).curator();
        bytes32[] memory accounts = new bytes32[](2);
        accounts[0] = bytes32(uint256(uint160(curator)));
        accounts[1] = bytes32(uint256(uint160(makeAddr("never an allocator"))));
        (address[] memory allocators, bool curatorIsAllocator) =
            check.review(GAUNTLET, accounts, new bytes32[](0));
        assertEq(allocators.length, 1);
        assertEq(allocators[0], curator);
        assertTrue(curatorIsAllocator, "flagged for sign-off (audit 2 R1-01)");
    }

    // ================================================================ Audit round 1 (R1-05, R1-17, R1-23)

    /// @dev R1-05 on real build output: the honest ceremony re-derives byte for byte; the verifiers' tamper B
    ///      (implementation substitution, which passed the old offline check and VerifyBase) is rejected.
    function test_R1_05_manifestCheck_realBuild_honestPasses_tamperRejected() public {
        Plan memory p = builder.build(_cfg(), string.concat(OUT, "r105-honest"));
        this.checkManifestExternal(string.concat(OUT, "r105-honest"));

        address evil = makeAddr("preDeployedEvilImpl");
        p.deployments[MHDeployPlan.ROTATING_IMPL].addr = evil;
        Deployment memory f = p.deployments[MHDeployPlan.FACTORY];
        f.constructorArgs = abi.encode(
            MHDeployPlan.at(p, MHDeployPlan.REGISTRY),
            MHDeployPlan.at(p, MHDeployPlan.REPUTATION),
            evil,
            MHDeployPlan.at(p, MHDeployPlan.ACCUMULATION_IMPL)
        );
        f.initCode = abi.encodePacked(f.creationCode, f.constructorArgs);
        p.batch2.calls[5].data = abi.encodeCall(ICreateX.deployCreate3, (f.salt, f.initCode));
        p.batch2.txData =
            abi.encodeCall(IMultiSendCallOnly.multiSend, (MHDeployPlan.encodeMultiSend(p.batch2.calls)));
        (p.batch2.domainSeparator, p.batch2.messageHash, p.batch2.safeTxHash) = MHDeployPlan.safeTxHash(
            address(gov), block.chainid, BaseChain.MULTISEND_CALL_ONLY, 0, p.batch2.txData, 1, 2
        );
        string memory dir = string.concat(OUT, "r105-tampered/");
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "manifest.json"), MHDeployJson.manifest(p));
        vm.writeFile(string.concat(dir, p.batch1a.fileName), MHDeployJson.batchFile(p, p.batch1a));
        vm.writeFile(string.concat(dir, p.batch1b.fileName), MHDeployJson.batchFile(p, p.batch1b));
        vm.writeFile(string.concat(dir, p.batch2.fileName), MHDeployJson.batchFile(p, p.batch2));
        vm.writeFile(
            string.concat(dir, "proposal-allow-vault.schedule.safe.json"),
            MHDeployJson.proposalFile(p, p.allowVault.schedule, "schedule")
        );
        vm.writeFile(
            string.concat(dir, "proposal-allow-vault.execute.safe.json"),
            MHDeployJson.proposalFile(p, p.allowVault.execute, "execute")
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MHManifestCheck.ManifestMismatch.selector,
                "manifest.json != the plan re-derived from its inputs"
            )
        );
        this.checkManifestExternal(dir);
    }

    /// @dev PoC R1-17 (`test_R117_nestedGovSafeOwner_fullPath`, `test_R117_variants_helperSafes`): a Guardian
    ///      Safe owned by the Gov Safe, or by helper Safes controlled by a Gov key or the operator, used to pass
    ///      `validate`. Every owner must now be an EOA and no owner may be a role.
    function test_R1_17_build_rejectsNestedSafeAndContractOwners() public {
        address[] memory mixed = new address[](4);
        mixed[0] = address(gov);
        mixed[1] = guardianOwners[0];
        mixed[2] = guardianOwners[1];
        mixed[3] = guardianOwners[2];
        DeployConfig memory c = _cfg();
        c.guardian = _spec(_newSafe(mixed, 2), mixed, 2);
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.SafeOwnerIsRole.selector, "guardian", address(gov))
        );
        builder.validate(c);

        address[] memory one = new address[](1);
        one[0] = govOwners[0];
        ISafe helperGov = _newSafe(one, 1);
        address[] memory viaHelper = _owners("guardianHelper", 4);
        viaHelper[0] = address(helperGov);
        c = _cfg();
        c.guardian = _spec(_newSafe(viaHelper, 2), viaHelper, 2);
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.SafeOwnerNotEoa.selector, "guardian", address(helperGov))
        );
        builder.validate(c);
    }

    /// @dev Closeout A-R2-16: an owner with an EIP-7702 delegation designator (`0xef0100 ‖ delegate`) counts as code:
    ///      its delegate can act for it under any authority it implements and Safe accepts EIP-1271 signatures from
    ///      owners, so address disjointness would no longer prove the Gov and Guardian keys separate. Refused by the
    ///      build and, on the live Safes, by VerifyBase.
    function test_A1R2_16_eip7702DelegatedOwner_isNotAKey() public {
        DeployConfig memory c = _cfg();
        address delegated = guardianOwners[0];
        bytes memory designator = abi.encodePacked(hex"ef0100", makeAddr("delegate"));
        vm.etch(delegated, designator);
        vm.expectRevert(
            abi.encodeWithSelector(BuildBaseBatch.SafeOwnerNotEoa.selector, "guardian", delegated)
        );
        builder.validate(c);
        vm.etch(delegated, "");

        _deployAll("v-a1r2-16");
        VerifyBase.Manifest memory m = _manifest("v-a1r2-16");
        vm.etch(delegated, designator); // delegated after the build
        vm.expectRevert(
            abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "guardian Safe: every owner is an EOA")
        );
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    /// @dev R1-17 in VerifyBase: a Safe that gained a contract owner after the build fails the live policy check.
    ///      Audit 2 R1-14 (c): the Gov Safe replaces one Guardian owner, so the Safe stays 2-of-4 (policy-compliant)
    ///      and the EOA check is what rejects it (adding a fifth owner at 2-of-5 hit the threshold policy first).
    function test_R1_17_verify_rejectsContractOwnerAddedLater() public {
        _deployAll("v-r117");
        VerifyBase.Manifest memory m = _manifest("v-r117");
        address[] memory live = guardian.getOwners();
        _execSafe(
            guardian,
            address(guardian),
            abi.encodeWithSignature(
                "swapOwner(address,address,address)", BaseChain.SAFE_SENTINEL, live[0], address(gov)
            ),
            0
        );
        address[] memory owners = new address[](m.guardianOwners.length);
        for (uint256 i; i < m.guardianOwners.length; ++i) {
            owners[i] = m.guardianOwners[i] == live[0] ? address(gov) : m.guardianOwners[i];
        }
        m.guardianOwners = owners;
        assertEq(guardian.getThreshold(), 2);
        vm.expectRevert(
            abi.encodeWithSelector(VerifyBase.VerifyFailed.selector, "guardian Safe: every owner is an EOA")
        );
        verifier.verify(m, _deployEoas(), roleEvents);
    }

    /// @dev R1-23: a takeover operation queued on the Timelock used to pass VerifyBase until it executed. The
    ///      manifest's own allowVault proposal may be pending; anything else may not, and no vault other than the
    ///      manifest's may be allowlisted.
    function test_R1_23_verify_rejectsPendingOperationAndForeignVault() public {
        _deployAll("v-r123");
        VerifyBase.Manifest memory m = _manifest("v-r123");
        TimelockController tl = _timelock();
        uint256 delay = tl.getMinDelay();
        vm.recordLogs();
        // The manifest's allowVault proposal: pending is fine.
        (Call[] memory sched,) =
            _readBatchFile(string.concat(OUT, "v-r123/proposal-allow-vault.schedule.safe.json"));
        _execSafe(gov, sched[0].to, sched[0].data, 0);
        bytes32[] memory ids = _scheduledIds(vm.getRecordedLogs(), address(tl));
        verifier.verifyGovernanceQueue(m, ids, new address[](0));

        // A queued takeover: grantRole(DEFAULT_ADMIN_ROLE, attacker).
        bytes memory grant = abi.encodeCall(IAccessControl.grantRole, (bytes32(0), makeAddr("attacker")));
        vm.recordLogs();
        _execSafe(
            gov,
            address(tl),
            abi.encodeCall(tl.schedule, (address(tl), 0, grant, 0, keccak256(grant), delay)),
            0
        );
        bytes32[] memory more = _scheduledIds(vm.getRecordedLogs(), address(tl));
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "Timelock: an unexpected operation is pending"
            )
        );
        verifier.verifyGovernanceQueue(m, more, new address[](0));
        // Once cancelled by Gov it is fine again.
        _execSafe(
            gov,
            address(tl),
            abi.encodeCall(tl.cancel, (tl.hashOperation(address(tl), 0, grant, 0, keccak256(grant)))),
            0
        );
        verifier.verifyGovernanceQueue(m, more, new address[](0));

        // A foreign vault allowlisted (a mock that passes every check).
        MockVaultV2 foreign = new MockVaultV2(USDC, address(this));
        _govTimelock(address(_registry()), abi.encodeCall(_registry().allowVault, (address(foreign))));
        address[] memory allowed = new address[](1);
        allowed[0] = address(foreign);
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyBase.VerifyFailed.selector, "registry: a vault other than the manifest's is allowlisted"
            )
        );
        verifier.verifyGovernanceQueue(m, new bytes32[](0), allowed);
    }

    function _scheduledIds(Vm.Log[] memory logs, address tl) internal pure returns (bytes32[] memory ids) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == tl && logs[i].topics[0] == TimelockController.CallScheduled.selector) ++n;
        }
        ids = new bytes32[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == tl && logs[i].topics[0] == TimelockController.CallScheduled.selector) {
                ids[n++] = logs[i].topics[1];
            }
        }
    }

    // ================================================================ External wrappers (for expectRevert)

    /// @notice `MHManifestCheck.check` (external, so `expectRevert` can observe it).
    function checkManifestExternal(string memory dir) external {
        MHManifestCheck.check(dir);
    }

    /// @notice Executes a Transaction Builder file through `safe` (external, so `expectRevert` can observe it).
    function execFileExternal(ISafe safe, string memory path) external {
        _execFile(safe, path);
    }

    /// @notice Executes one CALL through `safe` (external, so `expectRevert` can observe it).
    function execSafeExternal(ISafe safe, address to, bytes memory data) external {
        _execSafe(safe, to, data, 0);
    }

    // ================================================================ Helpers: deployment

    function _cfg() internal view returns (DeployConfig memory c) {
        c.usdc = USDC;
        c.gov = _spec(gov, govOwners, 3);
        c.guardian = _spec(guardian, guardianOwners, 2);
        c.treasury = _spec(treasury, treasuryOwners, 2);
        c.operator = operator;
        c.circleVault = GAUNTLET;
        c.earnWrapper = address(0);
        c.timelockDelay = 48 hours;
        c.rotatingFeeBps = 0;
        c.accumulationFeeBps = 0;
        c.saltSeed = keccak256("moolahub rehearsal seed");
        c.govNonce = 0;
        c.commit = COMMIT;
    }

    function _spec(ISafe safe, address[] memory owners, uint256 threshold)
        internal
        pure
        returns (SafeSpec memory s)
    {
        s.safe = address(safe);
        s.owners = new address[](owners.length);
        for (uint256 i; i < owners.length; ++i) {
            s.owners[i] = owners[i];
        }
        s.threshold = threshold;
    }

    /// @dev Builds the files, then executes batches 1a, 1b and 2 from the files through the Gov Safe.
    function _deployAll(string memory tag) internal {
        Plan memory p = builder.build(_cfg(), string.concat(OUT, tag));
        _storePlan(p);
        string memory dir = string.concat(OUT, tag, "/");
        gasBatch1a = _execFile(gov, string.concat(dir, "batch1a-rotating-implementation.safe.json"));
        gasBatch1b = _execFile(gov, string.concat(dir, "batch1b-accumulation-implementation.safe.json"));
        vm.recordLogs();
        gasBatch2 = _execFile(gov, string.concat(dir, "batch2-governance.safe.json"));
        VerifyBase.RoleEvent[] memory ev = _roleEventsFromLogs(vm.getRecordedLogs());
        for (uint256 i; i < ev.length; ++i) {
            roleEvents.push(ev[i]);
        }
    }

    function _storePlan(Plan memory p) internal {
        // Copy only what the tests read back (dynamic struct arrays cannot be assigned to storage wholesale).
        delete plan.deployments;
        for (uint256 i; i < p.deployments.length; ++i) {
            plan.deployments.push(p.deployments[i]);
        }
        plan.batch1a.txGas = p.batch1a.txGas;
        plan.batch1b.txGas = p.batch1b.txGas;
        plan.batch2.txGas = p.batch2.txGas;
        plan.allowVault.operationId = p.allowVault.operationId;
        plan.allowVault.delay = p.allowVault.delay;
    }

    function _manifest(string memory tag) internal view returns (VerifyBase.Manifest memory) {
        return verifier.load(string.concat(OUT, tag, "/manifest.json"));
    }

    function _deployEoas() internal view returns (address[] memory e) {
        e = new address[](2);
        e[0] = executor;
        e[1] = address(this);
    }

    function _timelock() internal view returns (TimelockController) {
        return TimelockController(payable(plan.deployments[MHDeployPlan.TIMELOCK].addr));
    }

    function _registry() internal view returns (MHCircleRegistry) {
        return MHCircleRegistry(plan.deployments[MHDeployPlan.REGISTRY].addr);
    }

    function _factory() internal view returns (MHCircleFactory) {
        return MHCircleFactory(plan.deployments[MHDeployPlan.FACTORY].addr);
    }

    /// @dev Gov schedules `target.data` on the Timelock, waits the delay, executes (each through the Gov Safe).
    function _govTimelock(address target, bytes memory data) internal {
        TimelockController tl = _timelock();
        uint256 delay = tl.getMinDelay();
        _execSafe(
            gov, address(tl), abi.encodeCall(tl.schedule, (target, 0, data, 0, keccak256(data), delay)), 0
        );
        vm.warp(block.timestamp + delay);
        _execSafe(gov, address(tl), abi.encodeCall(tl.execute, (target, 0, data, 0, keccak256(data))), 0);
    }

    // ================================================================ Helpers: Safes

    function _owners(string memory tag, uint256 n) internal returns (address[] memory o) {
        o = new address[](n);
        for (uint256 i; i < n; ++i) {
            o[i] = makeAddr(string.concat(tag, vm.toString(i)));
        }
    }

    function _newSafe(address[] memory owners, uint256 threshold) internal returns (ISafe) {
        bytes memory init = abi.encodeCall(
            ISafe.setup,
            (owners, threshold, address(0), "", BaseChain.FALLBACK_HANDLER, address(0), 0, payable(0))
        );
        return ISafe(
            ISafeProxyFactory(BaseChain.SAFE_PROXY_FACTORY)
                .createProxyWithNonce(BaseChain.SAFE_L2, init, ++saltNonce)
        );
    }

    /// @dev Reads a Transaction Builder file and executes it as Safe{Wallet} would: one call directly, several
    ///      calls as a MultiSendCallOnly DELEGATECALL. Returns the transaction gas.
    function _execFile(ISafe safe, string memory path) internal returns (uint256) {
        (Call[] memory calls, address createdFrom) = _readBatchFile(path);
        assertEq(createdFrom, address(safe), "file is for this Safe");
        if (calls.length == 1) return _execSafe(safe, calls[0].to, calls[0].data, 0);
        return _execSafe(safe, BaseChain.MULTISEND_CALL_ONLY, _multiSend(calls), 1);
    }

    /// @dev `threshold` owners approve the hash on chain (pranked), then `executor` submits with type-1
    ///      signatures sorted by owner. Returns the transaction gas (execution + intrinsic, EIP-7623 floor).
    function _execSafe(ISafe safe, address to, bytes memory data, uint8 op) internal returns (uint256) {
        uint256 nonce = safe.nonce();
        bytes32 h = safe.getTransactionHash(to, 0, data, op, 0, 0, 0, address(0), address(0), nonce);
        bytes memory sigs = builder.approveAndSign(safe, h);
        bytes memory callData = abi.encodeCall(
            ISafe.execTransaction, (to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), sigs)
        );
        vm.prank(executor, executor);
        bool ok = safe.execTransaction(to, 0, data, op, 0, 0, 0, address(0), payable(address(0)), sigs);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        assertTrue(ok);
        assertEq(safe.nonce(), nonce + 1);
        return builder.txGas(used, callData);
    }

    function _readBatchFile(string memory path)
        internal
        view
        returns (Call[] memory calls, address createdFrom)
    {
        string memory j = vm.readFile(path);
        createdFrom = vm.parseJsonAddress(j, ".meta.createdFromSafeAddress");
        uint256 n;
        while (vm.keyExistsJson(j, string.concat(".transactions[", vm.toString(n), "]"))) {
            ++n;
        }
        calls = new Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            calls[i].to = vm.parseJsonAddress(j, string.concat(k, ".to"));
            calls[i].value = vm.parseUint(vm.parseJsonString(j, string.concat(k, ".value")));
            calls[i].data = vm.parseJsonBytes(j, string.concat(k, ".data"));
        }
    }

    function _multiSend(Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encodeCall(IMultiSendCallOnly.multiSend, (MHDeployPlan.encodeMultiSend(calls)));
    }

    function _roleEventsFromLogs(Vm.Log[] memory logs)
        internal
        view
        returns (VerifyBase.RoleEvent[] memory ev)
    {
        address tl = plan.deployments.length == 0 ? address(0) : plan.deployments[MHDeployPlan.TIMELOCK].addr;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (_isRoleLog(logs[i], tl)) ++n;
        }
        ev = new VerifyBase.RoleEvent[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (!_isRoleLog(logs[i], tl)) continue;
            ev[n++] = VerifyBase.RoleEvent({
                role: logs[i].topics[1],
                account: address(uint160(uint256(logs[i].topics[2]))),
                granted: logs[i].topics[0] == IAccessControl.RoleGranted.selector
            });
        }
    }

    function _isRoleLog(Vm.Log memory l, address tl) internal pure returns (bool) {
        return l.emitter == tl
            && (l.topics[0] == IAccessControl.RoleGranted.selector
                || l.topics[0] == IAccessControl.RoleRevoked.selector);
    }

    function _append(VerifyBase.RoleEvent[] memory a, VerifyBase.RoleEvent[] memory b)
        internal
        pure
        returns (VerifyBase.RoleEvent[] memory c)
    {
        c = new VerifyBase.RoleEvent[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            c[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            c[a.length + i] = b[i];
        }
    }

    function _setEnv(DeployConfig memory c) internal {
        vm.setEnv("USDC", vm.toString(c.usdc));
        _setSafeEnv("GOV", c.gov);
        _setSafeEnv("GUARDIAN", c.guardian);
        _setSafeEnv("TREASURY", c.treasury);
        vm.setEnv("OPERATOR", vm.toString(c.operator));
        vm.setEnv("CIRCLE_VAULT", vm.toString(c.circleVault));
        vm.setEnv("EARN_WRAPPER", vm.toString(c.earnWrapper));
        vm.setEnv("TIMELOCK_DELAY", vm.toString(c.timelockDelay));
        vm.setEnv("ROTATING_FEE_BPS", vm.toString(c.rotatingFeeBps));
        vm.setEnv("ACCUMULATION_FEE_BPS", vm.toString(c.accumulationFeeBps));
        vm.setEnv("CREATE3_SALT_SEED", vm.toString(c.saltSeed));
        vm.setEnv("GOV_SAFE_NONCE", vm.toString(c.govNonce));
        vm.setEnv("AUDITED_COMMIT", c.commit);
    }

    function _setSafeEnv(string memory prefix, SafeSpec memory s) internal {
        vm.setEnv(string.concat(prefix, "_SAFE"), vm.toString(s.safe));
        string memory owners;
        for (uint256 i; i < s.owners.length; ++i) {
            owners = string.concat(owners, i == 0 ? "" : ",", vm.toString(s.owners[i]));
        }
        vm.setEnv(string.concat(prefix, "_SAFE_OWNERS"), owners);
        vm.setEnv(string.concat(prefix, "_SAFE_THRESHOLD"), vm.toString(s.threshold));
    }

    // ================================================================ Helpers: circles

    function _members(uint256 n, string memory tag) internal returns (address[] memory m) {
        m = new address[](n);
        for (uint256 i; i < n; ++i) {
            m[i] = makeAddr(string.concat(tag, vm.toString(i)));
        }
    }

    function _rotatingParams(bytes32 id, address[] memory members)
        internal
        view
        returns (RotatingParams memory p)
    {
        p.config = RotatingConfig({
            circleId: id,
            contribution: 100e6,
            feeBps: 0,
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
    }

    function _fund(address who, address spender, uint256 amount) internal {
        deal(USDC, who, IUSDC(USDC).balanceOf(who) + amount);
        vm.prank(who);
        IUSDC(USDC).approve(spender, amount);
    }
}
