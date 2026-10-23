// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import { MHDeployPlan, DeployConfig, SafeSpec, Plan } from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "../../script/ceremony/MHManifestCheck.sol";

/// @notice Closing review of the internal audit closeout, offline ceremony checks: the Safe owner lists are canonical
///         (sorted ascending by the planner), so the inputs hash a signer rebuilds does not depend on the order in
///         which the owners were given (README: "comma-separated, any order"). Ceremony directories are written to
///         `deployments/rehearsal/closing-review/` (git-ignored).
contract MHClosingReviewScriptsTest is Test {
    string internal constant ROOT = "deployments/rehearsal/closing-review/";

    function checkExternal(string memory dir) external {
        MHManifestCheck.check(dir);
    }

    function checkInputsExternal(string memory dir, bytes32 expected) external {
        MHManifestCheck.checkInputs(dir, expected);
    }

    /// @dev `n` owners in descending address order (the reverse of the canonical order).
    function _descending(string memory tag, uint256 n) internal returns (address[] memory o) {
        o = new address[](n);
        for (uint256 i; i < n; ++i) {
            o[i] = makeAddr(string.concat(tag, vm.toString(i)));
        }
        MHDeployPlan.sortAddresses(o);
        for (uint256 i; i < n / 2; ++i) {
            (o[i], o[n - 1 - i]) = (o[n - 1 - i], o[i]);
        }
    }

    function _reversed(address[] memory a) internal pure returns (address[] memory r) {
        r = new address[](a.length);
        for (uint256 i; i < a.length; ++i) {
            r[i] = a[a.length - 1 - i];
        }
    }

    /// @dev A permutation that is neither ascending nor descending: rotate left by one.
    function _rotated(address[] memory a) internal pure returns (address[] memory r) {
        r = new address[](a.length);
        for (uint256 i; i < a.length; ++i) {
            r[i] = a[(i + 1) % a.length];
        }
    }

    function _cfg(address[] memory gov, address[] memory guardian, address[] memory treasury)
        internal
        returns (DeployConfig memory c)
    {
        c.usdc = BaseChain.USDC_BASE;
        c.gov = SafeSpec({ safe: makeAddr("govSafe"), owners: gov, threshold: 3 });
        c.guardian = SafeSpec({ safe: makeAddr("guardianSafe"), owners: guardian, threshold: 2 });
        c.treasury = SafeSpec({ safe: makeAddr("treasurySafe"), owners: treasury, threshold: 2 });
        c.operator = makeAddr("operator");
        c.circleVault = BaseChain.CIRCLE_VAULT_BASE;
        c.earnWrapper = address(0);
        c.timelockDelay = 48 hours;
        c.saltSeed = keccak256("closing review seed");
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

    function _assertAscending(address[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; ++i) {
            assertLt(uint160(a[i - 1]), uint160(a[i]), "recorded owners ascending");
        }
    }

    /// @dev Closing review, finding 3 (reproduced first: with the owner lists hashed in input order, the coordinator's
    ///      and a signer's runs over the same owners in a different order printed different inputs hashes, and the
    ///      signer's `--inputs-hash` check failed). The coordinator gives every Safe's owners in descending order,
    ///      a signer in ascending order and another in a rotated order: one inputs hash, one recorded owner list
    ///      (ascending), and each signer's own hash anchors the coordinator's ceremony.
    function test_CR_03_ownerOrder_doesNotChangeTheInputsHash() public {
        address[] memory g = _descending("govKey", 5);
        address[] memory q = _descending("guardianKey", 4);
        address[] memory t = _descending("treasuryKey", 3);
        Plan memory coordinator = MHDeployPlan.plan(_cfg(g, q, t), BaseChain.BASE);

        g = _descending("govKey", 5);
        q = _descending("guardianKey", 4);
        t = _descending("treasuryKey", 3);
        Plan memory ascending =
            MHDeployPlan.plan(_cfg(_reversed(g), _reversed(q), _reversed(t)), BaseChain.BASE);
        Plan memory rotated = MHDeployPlan.plan(_cfg(_rotated(g), _rotated(q), _rotated(t)), BaseChain.BASE);

        bytes32 h = MHDeployPlan.inputsHash(coordinator);
        assertEq(MHDeployPlan.inputsHash(ascending), h, "same owners, another order: same inputs hash");
        assertEq(MHDeployPlan.inputsHash(rotated), h, "same owners, another order: same inputs hash");
        _assertAscending(coordinator.cfg.gov.owners);
        _assertAscending(coordinator.cfg.guardian.owners);
        _assertAscending(coordinator.cfg.treasury.owners);

        string memory dir = _write(coordinator, "cr-03-coordinator");
        this.checkInputsExternal(dir, MHDeployPlan.inputsHash(ascending));
        this.checkInputsExternal(dir, MHDeployPlan.inputsHash(rotated));
    }

    /// @dev Closing review, finding 3: the recorded lists must be canonical. A manifest whose Guardian owners are
    ///      recorded out of order (with an inputs hash consistently recomputed over that order) is refused by the
    ///      offline policy, so no ceremony can be published with a non-canonical hash.
    function test_CR_03_unsortedRecordedOwners_refused() public {
        Plan memory p = MHDeployPlan.plan(
            _cfg(_descending("govKey", 5), _descending("guardianKey", 4), _descending("treasuryKey", 3)),
            BaseChain.BASE
        );
        this.checkExternal(_write(p, "cr-03-sorted"));
        p.cfg.guardian.owners = _reversed(p.cfg.guardian.owners);
        string memory dir = _write(p, "cr-03-unsorted");
        vm.expectRevert(
            abi.encodeWithSelector(MHManifestCheck.PolicyViolation.selector, "Safe owners sorted ascending")
        );
        this.checkExternal(dir);
    }
}
