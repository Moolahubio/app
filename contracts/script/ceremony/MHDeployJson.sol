// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { BaseChain } from "./BaseChain.sol";
import { MHDeployPlan, Plan, Deployment, Call, SafeBatch, SafeSpec, SafeTxRef } from "./MHDeployPlan.sol";

/// @title MHDeployJson
/// @notice Deterministic JSON for the ceremony: the manifest (salts, initcode hashes, addresses, Safe transaction
///         hashes) and Safe Transaction Builder batch files. Everything is assembled by hand so that the bytes depend
///         only on the plan: no timestamps, no map ordering, no float formatting. Strings are ASCII and checked to
///         need no JSON escaping.
library MHDeployJson {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Transaction Builder version stamped in `meta.txBuilderVersion` (safe-react-apps tx-builder 1.19.0).
    string internal constant TX_BUILDER_VERSION = "1.19.0";
    /// @notice Manifest schema id.
    /// @dev Version 2 (audit round 2): `inputsHash` (R2-03), derived runtime codehashes (R2-04) and the allowVault
    ///      proposal's two Gov Safe transactions (R2-03).
    string internal constant SCHEMA = "moolahub.circles.deploy-manifest/2";

    /// @notice A string would need JSON escaping (quote, backslash, control or non-ASCII character).
    error JsonUnsafeString(string value);

    // ================================================================ Transaction Builder

    /// @notice A Safe Transaction Builder batch file (format `version` 1.0) with a valid `meta.checksum`.
    /// @dev The checksum reproduces safe-react-apps `apps/tx-builder/src/lib/checksum.ts`: `serializeJSONObject` of
    ///      the file with `meta.name = null` and no `meta.checksum`, hashed with keccak256 (web3 `sha3`). Objects
    ///      serialize as `{` + JSON.stringify(sorted keys) + each value followed by `,` + `}`; arrays as `[` + the
    ///      elements joined by `,` + `]`. Transactions carry raw `data` only (no `contractMethod`), as the builder
    ///      itself exports custom-data transactions. `createdAt` is 0 so the file is reproducible.
    /// @param chainId The chain.
    /// @param safe The Safe the batch is for (`meta.createdFromSafeAddress`).
    /// @param name `meta.name`.
    /// @param description `meta.description`.
    /// @param calls The batch's calls.
    /// @return json The file contents.
    function txBuilderFile(
        uint256 chainId,
        address safe,
        string memory name,
        string memory description,
        Call[] memory calls
    ) internal pure returns (string memory json) {
        _safe(name);
        _safe(description);
        string memory chainStr = vm.toString(chainId);
        string memory safeStr = vm.toString(safe);

        string memory txsJson;
        string memory txsSer;
        for (uint256 i; i < calls.length; ++i) {
            string memory to = vm.toString(calls[i].to);
            string memory value = vm.toString(calls[i].value);
            string memory data = vm.toString(calls[i].data);
            txsJson = string.concat(
                txsJson,
                i == 0 ? "" : ",\n",
                "    {\n      \"to\": \"",
                to,
                "\",\n      \"value\": \"",
                value,
                "\",\n      \"data\": \"",
                data,
                "\"\n    }"
            );
            txsSer = string.concat(
                txsSer,
                i == 0 ? "" : ",",
                "{[\"data\",\"to\",\"value\"]\"",
                data,
                "\",\"",
                to,
                "\",\"",
                value,
                "\",}"
            );
        }

        string memory metaSer = string.concat(
            "{[\"createdFromOwnerAddress\",\"createdFromSafeAddress\",\"description\",\"name\",\"txBuilderVersion\"]",
            "\"\",\"",
            safeStr,
            "\",\"",
            description,
            "\",null,\"",
            TX_BUILDER_VERSION,
            "\",}"
        );
        string memory ser = string.concat(
            "{[\"chainId\",\"createdAt\",\"meta\",\"transactions\",\"version\"]\"",
            chainStr,
            "\",0,",
            metaSer,
            ",[",
            txsSer,
            "],\"1.0\",}"
        );
        bytes32 checksum = keccak256(bytes(ser));

        json = string.concat(
            "{\n  \"version\": \"1.0\",\n  \"chainId\": \"",
            chainStr,
            "\",\n  \"createdAt\": 0,\n  \"meta\": {\n    \"name\": \"",
            name,
            "\",\n    \"description\": \"",
            description,
            "\",\n    \"txBuilderVersion\": \"",
            TX_BUILDER_VERSION,
            "\",\n    \"createdFromSafeAddress\": \"",
            safeStr,
            "\",\n    \"createdFromOwnerAddress\": \"\",\n    \"checksum\": \"",
            vm.toString(checksum),
            "\"\n  },\n  \"transactions\": [\n",
            txsJson,
            "\n  ]\n}\n"
        );
    }

    /// @notice The Transaction Builder file for a Gov Safe batch, with the expected Safe transaction in the
    ///         description so signers see it in the UI.
    /// @param p The plan.
    /// @param b The batch.
    /// @return The file contents.
    function batchFile(Plan memory p, SafeBatch memory b) internal pure returns (string memory) {
        string memory description = string.concat(
            "Gov Safe ",
            vm.toString(p.cfg.gov.safe),
            " nonce ",
            vm.toString(b.nonce),
            b.operation == BaseChain.OP_DELEGATECALL
                ? ". Must execute as ONE Safe transaction: to MultiSendCallOnly "
                : ". Must execute as ONE plain Safe transaction: to ",
            vm.toString(b.to),
            b.operation == BaseChain.OP_DELEGATECALL
                ? ", operation 1 (DELEGATECALL)"
                : ", operation 0 (CALL)",
            ", value 0, safeTxGas 0, baseGas 0, gasPrice 0, gasToken 0, refundReceiver 0.",
            " Expected safeTxHash ",
            vm.toString(b.safeTxHash),
            " (domain ",
            vm.toString(b.domainSeparator),
            ", message ",
            vm.toString(b.messageHash),
            "). Commit ",
            p.cfg.commit,
            "."
        );
        return txBuilderFile(p.chainId, p.cfg.gov.safe, b.title, description, b.calls);
    }

    /// @notice The Transaction Builder file for one step (schedule or execute) of the allowVault proposal, with the
    ///         expected plain Safe transaction and its hash in the description (audit R2-03).
    /// @param p The plan.
    /// @param c The single call.
    /// @param step "schedule" or "execute".
    /// @return The file contents.
    function proposalFile(Plan memory p, Call memory c, string memory step)
        internal
        pure
        returns (string memory)
    {
        Call[] memory calls = new Call[](1);
        calls[0] = c;
        SafeTxRef memory t = keccak256(bytes(step)) == keccak256("schedule")
            ? p.allowVault.scheduleTx
            : p.allowVault.executeTx;
        string memory description = string.concat(
            "Gov Safe ",
            vm.toString(p.cfg.gov.safe),
            ": Timelock ",
            step,
            " of registry.allowVault(",
            vm.toString(p.cfg.circleVault),
            "). Timelock operation id ",
            vm.toString(p.allowVault.operationId),
            ", delay ",
            vm.toString(p.allowVault.delay),
            "s. Must execute as ONE plain Safe transaction: to the Timelock, operation 0 (CALL), value 0, every gas field 0, nonce ",
            vm.toString(t.nonce),
            ". Expected safeTxHash ",
            vm.toString(t.safeTxHash),
            ". Run script/CheckVaultPending.s.sol first. Commit ",
            p.cfg.commit,
            "."
        );
        return txBuilderFile(
            p.chainId,
            p.cfg.gov.safe,
            string.concat("Moolahub circles: ", step, " allowVault"),
            description,
            calls
        );
    }

    // ================================================================ Manifest

    /// @notice The deployment manifest. Every value is reproducible from the inputs and the compiled bytecode.
    /// @param p The plan, after simulation (runtime codehashes filled in).
    /// @return The manifest JSON.
    function manifest(Plan memory p) internal pure returns (string memory) {
        _safe(p.cfg.commit);
        return string.concat(
            _manifestHead(p), _manifestContracts(p), _manifestBatches(p), _manifestProposal(p), "}\n"
        );
    }

    function _manifestHead(Plan memory p) private pure returns (string memory s) {
        s = string.concat("{\n", _kvs("schema", SCHEMA, 1), _kvs("network", p.network, 1));
        s = string.concat(s, _kv("chainId", vm.toString(p.chainId), 1), _kvs("commit", p.cfg.commit, 1));
        s = string.concat(s, _kvs("inputsHash", vm.toString(MHDeployPlan.inputsHash(p)), 1));
        s = string.concat(s, "  \"compiler\": {\n", _kvs("solc", "0.8.28", 2), _kv("optimizerRuns", "200", 2));
        s = string.concat(s, _kvs("evmVersion", "cancun", 2), _kvsLast("bytecodeHash", "ipfs", 2), "  },\n");

        s = string.concat(s, "  \"external\": {\n", _kva("usdc", p.cfg.usdc, 2));
        s = string.concat(s, _kva("createX", BaseChain.CREATEX, 2));
        s = string.concat(s, _kva("multiSendCallOnly", BaseChain.MULTISEND_CALL_ONLY, 2));
        s = string.concat(s, _kva("safeSingleton", BaseChain.SAFE_L2, 2));
        s = string.concat(s, _kva("safeProxyFactory", BaseChain.SAFE_PROXY_FACTORY, 2));
        s = string.concat(s, _kvaLast("fallbackHandler", BaseChain.FALLBACK_HANDLER, 2), "  },\n");

        s = string.concat(s, "  \"roles\": {\n", _kva("govSafe", p.cfg.gov.safe, 2));
        s = string.concat(s, _kva("guardianSafe", p.cfg.guardian.safe, 2));
        s = string.concat(s, _kva("treasurySafe", p.cfg.treasury.safe, 2));
        s = string.concat(s, _kva("operator", p.cfg.operator, 2), _kva("circleVault", p.cfg.circleVault, 2));
        s = string.concat(s, _kvaLast("earnWrapper", p.cfg.earnWrapper, 2), "  },\n");

        s = string.concat(s, "  \"safes\": {\n", _safeJson("gov", p.cfg.gov, false));
        s = string.concat(s, _safeJson("guardian", p.cfg.guardian, false));
        s = string.concat(s, _safeJson("treasury", p.cfg.treasury, true), "  },\n");

        s = string.concat(s, "  \"params\": {\n", _kv("timelockDelay", vm.toString(p.cfg.timelockDelay), 2));
        s = string.concat(s, _kv("rotatingFeeBps", vm.toString(p.cfg.rotatingFeeBps), 2));
        s = string.concat(s, _kv("accumulationFeeBps", vm.toString(p.cfg.accumulationFeeBps), 2));
        s = string.concat(s, _kvs("saltSeed", vm.toString(p.cfg.saltSeed), 2));
        s = string.concat(s, _kvLast("govSafeNonce", vm.toString(p.cfg.govNonce), 2), "  },\n");
    }

    function _safeJson(string memory name, SafeSpec memory spec, bool last)
        private
        pure
        returns (string memory s)
    {
        string memory owners;
        for (uint256 i; i < spec.owners.length; ++i) {
            owners = string.concat(owners, i == 0 ? "" : ", ", "\"", vm.toString(spec.owners[i]), "\"");
        }
        s = string.concat("    \"", name, "\": {\n", _kva("address", spec.safe, 3));
        s = string.concat(s, _kv("threshold", vm.toString(spec.threshold), 3), "      \"owners\": [", owners);
        s = string.concat(s, "]\n    }", last ? "\n" : ",\n");
    }

    function _manifestContracts(Plan memory p) private pure returns (string memory s) {
        s = "  \"contracts\": {\n";
        for (uint256 i; i < p.deployments.length; ++i) {
            s = string.concat(
                s, _contractJson(p.deployments[i]), i + 1 == p.deployments.length ? "    }\n" : "    },\n"
            );
        }
        s = string.concat(s, "  },\n");
    }

    function _contractJson(Deployment memory dep) private pure returns (string memory s) {
        s = string.concat("    \"", dep.key, "\": {\n", _kvs("contract", dep.contractName, 3));
        s = string.concat(s, _kv("batch", vm.toString(dep.batch), 3), _kva("address", dep.addr, 3));
        s = string.concat(s, _kvs("salt", vm.toString(dep.salt), 3));
        s = string.concat(s, _kvs("guardedSalt", vm.toString(dep.guardedSalt), 3));
        s = string.concat(s, _kvs("creationCodeHash", vm.toString(keccak256(dep.creationCode)), 3));
        s = string.concat(s, _kvs("constructorArgs", vm.toString(dep.constructorArgs), 3));
        s = string.concat(s, _kvs("initCodeHash", vm.toString(keccak256(dep.initCode)), 3));
        s = string.concat(s, _kv("initCodeSize", vm.toString(dep.initCode.length), 3));
        s = string.concat(s, _kvs("runtimeCodeHash", vm.toString(dep.runtimeCodeHash), 3));
        s = string.concat(s, _kvLast("runtimeSize", vm.toString(dep.runtimeSize), 3));
    }

    function _manifestBatches(Plan memory p) private pure returns (string memory s) {
        s = string.concat(
            "  \"batches\": {\n", _batchJson(p, p.batch1a, false), _batchJson(p, p.batch1b, false)
        );
        s = string.concat(s, _batchJson(p, p.batch2, true), "  },\n");
    }

    function _batchJson(Plan memory p, SafeBatch memory b, bool last) private pure returns (string memory s) {
        s = string.concat("    \"", b.key, "\": {\n", _kvs("file", b.fileName, 3));
        s = string.concat(s, _kva("safe", p.cfg.gov.safe, 3), _kva("to", b.to, 3));
        s = string.concat(s, _kv("value", "0", 3), _kv("operation", vm.toString(b.operation), 3));
        s = string.concat(s, _kv("safeTxGas", "0", 3));
        s = string.concat(s, _kv("baseGas", "0", 3), _kv("gasPrice", "0", 3), _kva("gasToken", address(0), 3));
        s = string.concat(s, _kva("refundReceiver", address(0), 3), _kv("nonce", vm.toString(b.nonce), 3));
        s = string.concat(s, _kvs("dataHash", vm.toString(keccak256(b.txData)), 3));
        s = string.concat(s, _kvs("domainHash", vm.toString(b.domainSeparator), 3));
        s = string.concat(s, _kvs("messageHash", vm.toString(b.messageHash), 3));
        s = string.concat(s, _kvs("safeTxHash", vm.toString(b.safeTxHash), 3), "      \"calls\": [\n");
        for (uint256 i; i < b.calls.length; ++i) {
            s = string.concat(s, _callJson(b.calls[i]), i + 1 == b.calls.length ? "\n" : ",\n");
        }
        s = string.concat(s, "      ]\n", last ? "    }\n" : "    },\n");
    }

    function _callJson(Call memory c) private pure returns (string memory s) {
        s = string.concat("        {\"to\": \"", vm.toString(c.to), "\", \"value\": \"", vm.toString(c.value));
        s = string.concat(s, "\", \"dataHash\": \"", vm.toString(keccak256(c.data)));
        s = string.concat(s, "\", \"description\": \"", c.description, "\"}");
    }

    function _manifestProposal(Plan memory p) private pure returns (string memory s) {
        if (!p.hasProposal) return "  \"allowVaultProposal\": null\n";
        s = string.concat("  \"allowVaultProposal\": {\n", _kva("timelock", p.allowVault.schedule.to, 2));
        s = string.concat(s, _kva("target", p.allowVault.target, 2));
        s = string.concat(s, _kvs("data", vm.toString(p.allowVault.data), 2));
        s = string.concat(s, _kvs("predecessor", vm.toString(p.allowVault.predecessor), 2));
        s = string.concat(s, _kvs("salt", vm.toString(p.allowVault.salt), 2));
        s = string.concat(s, _kv("delay", vm.toString(p.allowVault.delay), 2));
        s = string.concat(s, _kvs("operationId", vm.toString(p.allowVault.operationId), 2));
        s = string.concat(s, _kvs("scheduleFile", "proposal-allow-vault.schedule.safe.json", 2));
        s = string.concat(s, _kvs("executeFile", "proposal-allow-vault.execute.safe.json", 2));
        s = string.concat(
            s, _plainTxJson(p, "scheduleSafeTx", p.allowVault.schedule, p.allowVault.scheduleTx, false)
        );
        s = string.concat(
            s, _plainTxJson(p, "executeSafeTx", p.allowVault.execute, p.allowVault.executeTx, true)
        );
        s = string.concat(s, "  }\n");
    }

    /// @dev One plain Gov Safe transaction of the allowVault proposal (audit R2-03).
    function _plainTxJson(Plan memory p, string memory key, Call memory c, SafeTxRef memory t, bool last)
        private
        pure
        returns (string memory s)
    {
        s = string.concat("    \"", key, "\": {\n", _kva("safe", p.cfg.gov.safe, 3), _kva("to", c.to, 3));
        s = string.concat(
            s, _kv("value", "0", 3), _kv("operation", "0", 3), _kv("nonce", vm.toString(t.nonce), 3)
        );
        s = string.concat(s, _kvs("dataHash", vm.toString(keccak256(c.data)), 3));
        s = string.concat(s, _kvs("messageHash", vm.toString(t.messageHash), 3));
        s = string.concat(
            s, _kvsLast("safeTxHash", vm.toString(t.safeTxHash), 3), last ? "    }\n" : "    },\n"
        );
    }

    // ================================================================ Helpers

    function _indent(uint256 level) private pure returns (string memory s) {
        for (uint256 i; i < level; ++i) {
            s = string.concat(s, "  ");
        }
    }

    function _kv(string memory k, string memory raw, uint256 level) private pure returns (string memory) {
        return string.concat(_indent(level), "\"", k, "\": ", raw, ",\n");
    }

    function _kvLast(string memory k, string memory raw, uint256 level) private pure returns (string memory) {
        return string.concat(_indent(level), "\"", k, "\": ", raw, "\n");
    }

    function _kvs(string memory k, string memory v, uint256 level) private pure returns (string memory) {
        return string.concat(_indent(level), "\"", k, "\": \"", v, "\",\n");
    }

    function _kvsLast(string memory k, string memory v, uint256 level) private pure returns (string memory) {
        return string.concat(_indent(level), "\"", k, "\": \"", v, "\"\n");
    }

    function _kva(string memory k, address a, uint256 level) private pure returns (string memory) {
        return _kvs(k, vm.toString(a), level);
    }

    function _kvaLast(string memory k, address a, uint256 level) private pure returns (string memory) {
        return _kvsLast(k, vm.toString(a), level);
    }

    /// @dev Rejects anything JSON.stringify would escape or a non-ASCII byte, so `"` + s + `"` is its exact JSON.
    function _safe(string memory s) private pure {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == 0x22 || c == 0x5c || c < 0x20 || c > 0x7e) revert JsonUnsafeString(s);
        }
    }
}
