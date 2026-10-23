// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import { ICreateX, IMultiSendCallOnly } from "../../script/ceremony/DeployInterfaces.sol";
import {
    MHDeployPlan,
    DeployConfig,
    SafeSpec,
    Plan,
    Deployment,
    SafeBatch
} from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "../../script/ceremony/MHManifestCheck.sol";

/// @notice Audit R1-05 / R1-17 regressions, offline (no fork): the verifiers' tampered ceremonies (scratchpad
///         `audit/r1-verify-R1-05-*/contracts/test/fork/VerifyR105.t.sol`, `r1-verify-R1-17-1`) are rebuilt with the
///         planner and written to `deployments/rehearsal/` (git-ignored). The old `check-manifest-bytecode.sh` printed
///         OK for all seven contracts on every one of them; the new check rejects each, and accepts the honest
///         ceremony.
contract MHManifestCheckTest is Test {
    string internal constant ROOT = "deployments/rehearsal/r1-05/";

    address internal gov = makeAddr("govSafe");
    address internal guardian = makeAddr("guardianSafe");
    address internal treasury = makeAddr("treasurySafe");
    address internal operator = makeAddr("operator");
    address internal vault = BaseChain.CIRCLE_VAULT_BASE; // the pinned vault (audit R2-03)
    address internal attacker = makeAddr("attacker");

    /// @notice `MHManifestCheck.check`, external so `expectRevert` can observe it (a test contract, so the size
    ///         check of `forge build --sizes` skips it).
    function checkExternal(string memory dir) external {
        MHManifestCheck.check(dir);
    }

    /// @notice The checker's third layer alone (`MHManifestCheck.independentOnly`).
    function independentExternal(string memory dir) external view {
        MHManifestCheck.independentOnly(dir);
    }

    function _owners(string memory tag, uint256 n) internal returns (address[] memory o) {
        o = new address[](n);
        for (uint256 i; i < n; ++i) {
            o[i] = makeAddr(string.concat(tag, vm.toString(i)));
        }
    }

    function _cfg() internal returns (DeployConfig memory c) {
        c.usdc = BaseChain.USDC_BASE;
        c.gov = SafeSpec({ safe: gov, owners: _owners("govKey", 5), threshold: 3 });
        c.guardian = SafeSpec({ safe: guardian, owners: _owners("guardianKey", 4), threshold: 2 });
        c.treasury = SafeSpec({ safe: treasury, owners: _owners("treasuryKey", 3), threshold: 2 });
        c.operator = operator;
        c.circleVault = vault;
        c.earnWrapper = address(0);
        c.timelockDelay = 48 hours;
        c.saltSeed = keccak256("r1-05 seed");
        c.govNonce = 7;
        c.commit = "0123456789abcdef0123456789abcdef01234567";
    }

    /// @dev Writes a ceremony directory exactly as `BuildBaseBatch` does (runtime codehashes derived from the local
    ///      build, as the simulation records them; audit R2-04).
    function _write(Plan memory p, string memory tag) internal returns (string memory dir) {
        MHManifestCheck.deriveRuntime(p);
        dir = string.concat(ROOT, tag, "/");
        vm.createDir(dir, true);
        vm.writeFile(string.concat(dir, "manifest.json"), MHDeployJson.manifest(p));
        vm.writeFile(string.concat(dir, p.batch1a.fileName), MHDeployJson.batchFile(p, p.batch1a));
        vm.writeFile(string.concat(dir, p.batch1b.fileName), MHDeployJson.batchFile(p, p.batch1b));
        vm.writeFile(string.concat(dir, p.batch2.fileName), MHDeployJson.batchFile(p, p.batch2));
        if (p.hasProposal) {
            vm.writeFile(
                string.concat(dir, "proposal-allow-vault.schedule.safe.json"),
                MHDeployJson.proposalFile(p, p.allowVault.schedule, "schedule")
            );
            vm.writeFile(
                string.concat(dir, "proposal-allow-vault.execute.safe.json"),
                MHDeployJson.proposalFile(p, p.allowVault.execute, "execute")
            );
        }
    }

    /// @dev Recomputes batch 2's MultiSend payload and Safe hashes after a call was changed (what an attacker who
    ///      controls the build output would do so that the device and safe-tx-hashes-util agree with the files).
    function _rehash(Plan memory p, SafeBatch memory b) internal pure {
        b.txData = abi.encodeCall(IMultiSendCallOnly.multiSend, (MHDeployPlan.encodeMultiSend(b.calls)));
        (b.domainSeparator, b.messageHash, b.safeTxHash) = MHDeployPlan.safeTxHash(
            p.cfg.gov.safe, p.chainId, BaseChain.MULTISEND_CALL_ONLY, 0, b.txData, 1, b.nonce
        );
    }

    function _expectMismatch(string memory dir, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(MHManifestCheck.ManifestMismatch.selector, what));
        this.checkExternal(dir);
    }

    // ================================================================ Honest

    function test_R1_05_honestCeremonyPasses() public {
        string memory dir = _write(MHDeployPlan.plan(_cfg(), BaseChain.BASE), "honest");
        this.checkExternal(dir);
        // A Sepolia ceremony with no vault (the rehearsal shape) passes too.
        DeployConfig memory c = _cfg();
        c.usdc = BaseChain.USDC_BASE_SEPOLIA;
        c.circleVault = address(0);
        this.checkExternal(_write(MHDeployPlan.plan(c, BaseChain.BASE_SEPOLIA), "honest-sepolia"));
    }

    // ================================================================ The verifiers' tampers

    /// @dev PoC R1-05 test A (the finding's example): Timelock proposers/executors [Gov, attacker], batch 2 rehashed
    ///      consistently. Rejected by re-derivation, and by the independent decoding alone.
    function test_R1_05_tamperA_extraTimelockProposer() public {
        Plan memory t = MHDeployPlan.plan(_cfg(), BaseChain.BASE);
        address[] memory two = new address[](2);
        (two[0], two[1]) = (gov, attacker);
        Deployment memory d = t.deployments[MHDeployPlan.TIMELOCK];
        d.constructorArgs = abi.encode(t.cfg.timelockDelay, two, two, gov);
        d.initCode = abi.encodePacked(d.creationCode, d.constructorArgs);
        t.batch2.calls[0].data = abi.encodeCall(ICreateX.deployCreate3, (d.salt, d.initCode));
        _rehash(t, t.batch2);
        string memory dir = _write(t, "tamper-a");
        _expectMismatch(dir, "manifest.json != the plan re-derived from its inputs");
        _expectIndependentRejects(dir, "timelock: constructor arguments differ from the roles");
    }

    /// @dev PoC R1-05 test B: the rotating implementation's address points at a pre-deployed attacker contract and
    ///      the factory's arguments wire it; batch 1 is untouched. It passed both the old offline check and
    ///      VerifyBase. Rejected now.
    function test_R1_05_tamperB_implementationSubstitution() public {
        Plan memory t = MHDeployPlan.plan(_cfg(), BaseChain.BASE);
        address evil = makeAddr("preDeployedEvilImpl");
        t.deployments[MHDeployPlan.ROTATING_IMPL].addr = evil;
        Deployment memory f = t.deployments[MHDeployPlan.FACTORY];
        f.constructorArgs = abi.encode(
            MHDeployPlan.at(t, MHDeployPlan.REGISTRY),
            MHDeployPlan.at(t, MHDeployPlan.REPUTATION),
            evil,
            MHDeployPlan.at(t, MHDeployPlan.ACCUMULATION_IMPL)
        );
        f.initCode = abi.encodePacked(f.creationCode, f.constructorArgs);
        t.batch2.calls[5].data = abi.encodeCall(ICreateX.deployCreate3, (f.salt, f.initCode));
        _rehash(t, t.batch2);
        string memory dir = _write(t, "tamper-b");
        // Audit R2-04: the factory's runtime (its ROTATING_IMPL immutable) now differs from the runtime derived from
        // the honest inputs, which is checked first.
        _expectMismatch(dir, "factory: runtime code differs from the local build");
        _expectIndependentRejects(dir, "rotatingImpl: address");
    }

    /// @dev PoC R1-05 test C: delay 0 recorded consistently in params and arguments (validate skipped). The policy
    ///      bound is re-applied to the inputs.
    function test_R1_05_tamperC_zeroDelayConsistent() public {
        DeployConfig memory c = _cfg();
        c.timelockDelay = 0;
        string memory dir = _write(MHDeployPlan.plan(c, BaseChain.BASE), "tamper-c");
        vm.expectRevert(
            abi.encodeWithSelector(
                MHManifestCheck.PolicyViolation.selector, "Timelock delay in [48h, 7 days]"
            )
        );
        this.checkExternal(dir);
    }

    /// @dev Hand edits: one constructor argument in the manifest text, or one byte of a batch file.
    function test_R1_05_handEditedFilesRejected() public {
        Plan memory p = MHDeployPlan.plan(_cfg(), BaseChain.BASE);
        string memory dir = _write(p, "hand-edit");
        string memory path = string.concat(dir, "manifest.json");
        string memory json = vm.readFile(path);
        string memory honestArgs = vm.toString(p.deployments[MHDeployPlan.REGISTRY].constructorArgs);
        bytes memory edited = abi.encodePacked(honestArgs); // a copy: bytes(honestArgs) would alias it
        // forge-lint: disable-next-line(unsafe-typecast)
        edited[edited.length - 1] = edited[edited.length - 1] == "0" ? bytes1("1") : bytes1("0");
        vm.writeFile(path, vm.replace(json, honestArgs, string(edited)));
        _expectMismatch(dir, "manifest.json != the plan re-derived from its inputs");

        dir = _write(p, "batch-edit");
        string memory b2 = string.concat(dir, p.batch2.fileName);
        vm.writeFile(b2, vm.replace(vm.readFile(b2), "Moolahub circles batch 2", "Moolahub circles batch 2."));
        _expectMismatch(dir, "batch 2 file != re-derived");
    }

    /// @dev PoC R1-17: the Gov Safe (or any role) as a Guardian Safe owner used to pass. The policy rejects a Safe
    ///      owned by a role (the on-chain EOA check lives in BuildBaseBatch and VerifyBase).
    function test_R1_17_safeOwnedByARoleRejected() public {
        DeployConfig memory c = _cfg();
        c.guardian.owners[0] = gov;
        string memory dir = _write(MHDeployPlan.plan(c, BaseChain.BASE), "r1-17-nested");
        vm.expectRevert(
            abi.encodeWithSelector(MHManifestCheck.PolicyViolation.selector, "Safe owner is not a role")
        );
        this.checkExternal(dir);

        c = _cfg();
        c.guardian.owners[1] = operator;
        dir = _write(MHDeployPlan.plan(c, BaseChain.BASE), "r1-17-operator");
        vm.expectRevert(
            abi.encodeWithSelector(MHManifestCheck.PolicyViolation.selector, "Safe owner is not a role")
        );
        this.checkExternal(dir);
    }

    // ================================================================ Defence in depth

    /// @dev Simulates a tampered planner: the files are self-consistent with the tamper (so re-derivation through
    ///      the same tampered planner would agree), and only the independent decoding stands between them and a
    ///      signer. Replays the checker with the re-derivation step skipped.
    function _expectIndependentRejects(string memory dir, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(MHManifestCheck.ManifestMismatch.selector, what));
        this.independentExternal(dir);
    }
}

