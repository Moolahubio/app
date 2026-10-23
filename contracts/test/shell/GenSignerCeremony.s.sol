// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { BaseChain } from "../../script/ceremony/BaseChain.sol";
import { MHDeployPlan, DeployConfig, SafeSpec, Plan } from "../../script/ceremony/MHDeployPlan.sol";
import { MHDeployJson } from "../../script/ceremony/MHDeployJson.sol";
import { MHManifestCheck } from "../../script/ceremony/MHManifestCheck.sol";

/// @notice Test helper for `check-manifest-bytecode.signer-layout.sh` (closeout A-R2-18): writes an offline ceremony
///         directory (Base mainnet shape, made-up Safes) whose manifest records `commit`, and prints its inputs hash.
///         Never broadcasts; writes only under `deployments/`.
contract GenSignerCeremony is Script {
    function _owners(string memory tag, uint256 n) internal pure returns (address[] memory o) {
        o = new address[](n);
        for (uint256 i; i < n; ++i) {
            o[i] = vm.addr(uint256(keccak256(abi.encode(tag, i))));
        }
    }

    function run(string memory dir, string memory commit) external {
        DeployConfig memory c;
        c.usdc = BaseChain.USDC_BASE;
        c.gov = SafeSpec({ safe: vm.addr(101), owners: _owners("govKey", 5), threshold: 3 });
        c.guardian = SafeSpec({ safe: vm.addr(102), owners: _owners("guardianKey", 4), threshold: 2 });
        c.treasury = SafeSpec({ safe: vm.addr(103), owners: _owners("treasuryKey", 3), threshold: 2 });
        c.operator = vm.addr(104);
        c.circleVault = BaseChain.CIRCLE_VAULT_BASE;
        c.timelockDelay = 48 hours;
        c.saltSeed = keccak256("signer layout seed");
        c.govNonce = 7;
        c.commit = commit;
        Plan memory p = MHDeployPlan.plan(c, BaseChain.BASE);
        MHManifestCheck.deriveRuntime(p);
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
        console2.log(string.concat("INPUTS_HASH=", vm.toString(MHDeployPlan.inputsHash(p))));
    }
}
