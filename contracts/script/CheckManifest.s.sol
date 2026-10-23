// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { BaseChain } from "./ceremony/BaseChain.sol";
import { MHManifestCheck } from "./ceremony/MHManifestCheck.sol";
import { MHDeployPlan, Plan, SafeSpec } from "./ceremony/MHDeployPlan.sol";

/// @title CheckManifest
/// @notice Offline, signer-side check of a ceremony directory (audit R1-05, R2-03, R2-04). Needs no RPC and no key: it
///         re-applies the input policy (including the chain's pinned circle vault and the per-role Safe thresholds),
///         re-derives the manifest and every batch file from the manifest's inputs and the local build, derives every
///         runtime codehash by running the initcodes in the local EVM, decodes every transaction the Gov Safe will
///         sign and recomputes every Safe transaction hash (the three batches and both allowVault proposal transactions;
///         see `MHManifestCheck`). It then prints EVERY input, the inputs hash and every hash a signer compares. Run it
///         after `forge clean && forge build`:
///           forge script script/CheckManifest.s.sol --sig "run(string)" deployments/base-mainnet
///         `script/check-manifest-bytecode.sh` wraps it (and, with `--signer <audited commit>`, also checks git).
contract CheckManifest is Script {
    /// @notice Checks `dir`; reverts with `ManifestMismatch` or `PolicyViolation` on the first problem.
    /// @param dir Directory holding `manifest.json` and the batch files (under `deployments/`).
    function run(string memory dir) external {
        Plan memory p = MHManifestCheck.check(dir);
        console2.log("CheckManifest: OK, every file equals the plan re-derived from the manifest inputs");
        _print(p);
    }

    /// @notice `run(dir)`, and the manifest's inputs hash must equal `inputsHash` from the independent ceremony record
    ///         (audit 2 R2-08: the Guardian and Treasury Safes, the operator, the wrapper and the delay are then tied
    ///         to that record, not only checked for shape). Signers use this form (`check-manifest-bytecode.sh
    ///         --signer <commit> --inputs-hash <hash>`).
    /// @param dir Directory holding `manifest.json` and the batch files (under `deployments/`).
    /// @param inputsHash The inputs hash from the independent ceremony record.
    function run(string memory dir, bytes32 inputsHash) external {
        Plan memory p = MHManifestCheck.checkInputs(dir, inputsHash);
        console2.log("CheckManifest: OK, every file equals the plan re-derived from the manifest inputs");
        console2.log("CheckManifest: OK, the inputs hash equals the independent ceremony record");
        _print(p);
    }

    function _print(Plan memory p) private pure {
        _inputs(p);
        // Audit 2 R2-16: the three values a signer compares with safe-tx-hashes-util and the device: the domain hash
        // (one per Safe and chain), and per transaction the message hash and the safeTxHash.
        console2.log("  Gov Safe domain hash", vm.toString(p.batch1a.domainSeparator));
        _tx("batch 1a", p.batch1a.nonce, p.batch1a.messageHash, p.batch1a.safeTxHash);
        _tx("batch 1b", p.batch1b.nonce, p.batch1b.messageHash, p.batch1b.safeTxHash);
        _tx("batch 2", p.batch2.nonce, p.batch2.messageHash, p.batch2.safeTxHash);
        if (p.hasProposal) {
            _tx(
                "allowVault schedule",
                p.allowVault.scheduleTx.nonce,
                p.allowVault.scheduleTx.messageHash,
                p.allowVault.scheduleTx.safeTxHash
            );
            _tx(
                "allowVault execute",
                p.allowVault.executeTx.nonce,
                p.allowVault.executeTx.messageHash,
                p.allowVault.executeTx.safeTxHash
            );
            console2.log("  allowVault Timelock operation id", vm.toString(p.allowVault.operationId));
        }
        // Audit 2 R1-04: the creation-code hash depends only on the audited source and the compiler settings, so the
        // audit report can cite it (with the tag) before any ceremony input exists; the initcode hash also commits
        // to the roles and addresses.
        for (uint256 i; i < p.deployments.length; ++i) {
            console2.log(
                string.concat(
                    "  ",
                    p.deployments[i].key,
                    " creationCodeHash ",
                    vm.toString(keccak256(p.deployments[i].creationCode)),
                    " initCodeHash ",
                    vm.toString(keccak256(p.deployments[i].initCode)),
                    " at ",
                    vm.toString(p.deployments[i].addr),
                    " runtimeCodeHash ",
                    vm.toString(p.deployments[i].runtimeCodeHash)
                )
            );
        }
    }

    function _tx(string memory name, uint256 nonce, bytes32 messageHash, bytes32 safeTxHash) private pure {
        console2.log(string.concat("  ", name, " nonce"), nonce);
        console2.log(string.concat("    message hash ", vm.toString(messageHash)));
        console2.log(string.concat("    safeTxHash   ", vm.toString(safeTxHash)));
    }

    /// @dev Audit R2-03: every input, so signers compare all of them (and the inputs hash) out of band.
    function _inputs(Plan memory p) private pure {
        console2.log("  network       ", p.network);
        console2.log("  chainId       ", p.chainId);
        console2.log("  commit        ", p.cfg.commit);
        console2.log("  inputsHash    ", vm.toString(MHDeployPlan.inputsHash(p)));
        console2.log("  USDC          ", p.cfg.usdc);
        console2.log("  operator      ", p.cfg.operator);
        console2.log("  circleVault   ", p.cfg.circleVault);
        if (p.cfg.circleVault != address(0) && p.cfg.circleVault == BaseChain.CIRCLE_VAULT_BASE) {
            console2.log("                 (the pinned Gauntlet USDC Prime, spec Appendix A)");
        }
        console2.log("  earnWrapper   ", p.cfg.earnWrapper);
        console2.log("  timelockDelay ", p.cfg.timelockDelay);
        console2.log("  rotatingFeeBps / accumulationFeeBps", p.cfg.rotatingFeeBps, p.cfg.accumulationFeeBps);
        console2.log("  saltSeed      ", vm.toString(p.cfg.saltSeed));
        console2.log("  govSafeNonce  ", p.cfg.govNonce);
        _safe("Gov", p.cfg.gov);
        _safe("Guardian", p.cfg.guardian);
        _safe("Treasury", p.cfg.treasury);
    }

    function _safe(string memory name, SafeSpec memory s) private pure {
        console2.log(string.concat("  ", name, " Safe "), s.safe);
        console2.log(string.concat("    threshold / owners"), s.threshold, s.owners.length);
        for (uint256 i; i < s.owners.length; ++i) {
            console2.log("    owner", s.owners[i]);
        }
    }
}
