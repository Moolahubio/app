// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import { MHDeployPlan, DeployConfig, SafeSpec, Plan } from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "../../script/ceremony/MHManifestCheck.sol";

/// @notice Closeout of the internal audit, offline ceremony checks: A-R2-03 (the vault is pinned), A-R2-04 (runtime
///         codehashes are derived, never copied), A-R2-17 (per-role Safe thresholds) and B-R2-08 (the non-Gov inputs
///         are tied to the independent ceremony record through the inputs hash). Ceremony directories are written to
///         `deployments/rehearsal/closeout/` (git-ignored).
contract MHCloseoutScriptsTest is Test {
    string internal constant ROOT = "deployments/rehearsal/closeout/";

    address internal gov = makeAddr("govSafe");
    address internal guardian = makeAddr("guardianSafe");
    address internal treasury = makeAddr("treasurySafe");
    address internal operator = makeAddr("operator");
    address internal attacker = makeAddr("attacker");

    function checkExternal(string memory dir) external {
        MHManifestCheck.check(dir);
    }

    function checkInputsExternal(string memory dir, bytes32 expected) external {
        MHManifestCheck.checkInputs(dir, expected);
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
        c.circleVault = BaseChain.CIRCLE_VAULT_BASE;
        c.earnWrapper = address(0);
        c.timelockDelay = 48 hours;
        c.saltSeed = keccak256("closeout seed");
        c.govNonce = 7;
        c.commit = "0123456789abcdef0123456789abcdef01234567";
    }

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

    function _expectPolicy(string memory dir, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(MHManifestCheck.PolicyViolation.selector, what));
        this.checkExternal(dir);
    }

    /// @dev A-R2-03: a ceremony that allowlists any vault other than the one pinned for the chain in reviewed source
    ///      is refused offline (the vault changes no initcode, address or batch hash, so only the pin binds it).
    function test_A1R2_03_foreignVaultRefused() public {
        DeployConfig memory c = _cfg();
        c.circleVault = makeAddr("foreignVault");
        _expectPolicy(
            _write(MHDeployPlan.plan(c, BaseChain.BASE), "a1r2-03"),
            "circle vault is the chain's pinned vault"
        );
    }

    /// @dev A-R2-04: the manifest's runtime codehash is derived from the local build, never copied: a manifest that
    ///      names another runtime (what a substituted contract at a CREATE3 address would have) is refused, so
    ///      VerifyBase and check-sourcify compare the chain with the audited runtime.
    function test_A1R2_04_runtimeCodehashIsDerived() public {
        Plan memory p = MHDeployPlan.plan(_cfg(), BaseChain.BASE);
        string memory dir = _write(p, "a1r2-04");
        string memory path = string.concat(dir, "manifest.json");
        string memory honest = vm.toString(p.deployments[MHDeployPlan.REGISTRY].runtimeCodeHash);
        vm.writeFile(
            path, vm.replace(vm.readFile(path), honest, vm.toString(keccak256("substituted runtime")))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                MHManifestCheck.ManifestMismatch.selector,
                "registry: runtime code differs from the local build"
            )
        );
        this.checkExternal(dir);
    }

    /// @dev A-R2-17: the spec §5 per-role thresholds: a 2-of-5 Gov Safe and a 2-of-9 Guardian Safe are refused; the
    ///      spec shapes (Gov 3-of-5 or 2-of-3, Guardian 2-of-4, Treasury 2-of-3) pass.
    function test_A1R2_17_perRoleThresholdPolicy() public {
        DeployConfig memory c = _cfg();
        c.gov.threshold = 2;
        _expectPolicy(_write(MHDeployPlan.plan(c, BaseChain.BASE), "a1r2-17-gov"), "Safe threshold policy");
        c = _cfg();
        c.guardian = SafeSpec({ safe: guardian, owners: _owners("guardianKey", 9), threshold: 2 });
        _expectPolicy(
            _write(MHDeployPlan.plan(c, BaseChain.BASE), "a1r2-17-guardian"), "Safe threshold policy"
        );
        c = _cfg();
        c.gov = SafeSpec({ safe: gov, owners: _owners("govKey", 3), threshold: 2 });
        this.checkExternal(_write(MHDeployPlan.plan(c, BaseChain.BASE), "a1r2-17-ok"));
        assertTrue(BaseChain.safePolicyOk(BaseChain.ROLE_GUARDIAN, 2, 4));
        assertTrue(BaseChain.safePolicyOk(BaseChain.ROLE_TREASURY, 2, 3));
        assertFalse(BaseChain.safePolicyOk(BaseChain.ROLE_TREASURY, 2, 5));
    }

    /// @dev B-R2-08 (reproduced first: the coordinator substitutes its own, policy-compliant Guardian Safe, operator
    ///      and treasury, rebuilds everything consistently, and the plain check passes, since the policy only checks
    ///      the shape of these inputs). Anchored to the inputs hash of the independent ceremony record
    ///      (`checkInputs`, `CheckManifest.run(string,bytes32)`, `--inputs-hash`), it is refused; the honest ceremony
    ///      passes.
    function test_A2R2_08_substitutedRoles_passShapeCheck_failInputsAnchor() public {
        DeployConfig memory honest = _cfg();
        Plan memory hp = MHDeployPlan.plan(honest, BaseChain.BASE);
        bytes32 record = MHDeployPlan.inputsHash(hp); // what the Gov signers agreed on before the build

        DeployConfig memory c = _cfg();
        c.guardian = SafeSpec({
            safe: makeAddr("attackerGuardianSafe"), owners: _owners("attackerKey", 4), threshold: 2
        });
        c.treasury = SafeSpec({
            safe: makeAddr("attackerTreasury"), owners: _owners("attackerTKey", 3), threshold: 2
        });
        c.operator = attacker;
        string memory dir = _write(MHDeployPlan.plan(c, BaseChain.BASE), "a2r2-08-substituted");
        this.checkExternal(dir); // the reported gap: shape-only checks pass
        vm.expectRevert(
            abi.encodeWithSelector(
                MHManifestCheck.ManifestMismatch.selector, "inputsHash != the independent ceremony record"
            )
        );
        this.checkInputsExternal(dir, record);

        this.checkInputsExternal(_write(hp, "a2r2-08-honest"), record);
    }
}
