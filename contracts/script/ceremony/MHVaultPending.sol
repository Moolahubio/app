// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Vm } from "forge-std/Vm.sol";

import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";

/// @notice The timelock surface Morpho's Vault V2 and MorphoMarketV1AdapterV2 share (morpho-org/vault-v2 @ abaae813,
///         `IVaultV2.sol` and `IMorphoMarketV1AdapterV2.sol`; signatures copied verbatim). Both emit
///         `Submit(bytes4 indexed selector, bytes data, uint256 executableAt)` and clear `executableAt[data]` when the
///         data executes or is revoked.
interface ITimelockedV2 {
    /// @notice When `data` becomes executable (0 = not pending).
    function executableAt(bytes memory data) external view returns (uint256);
    /// @notice Whether a timelocked function has been permanently disabled.
    function abdicated(bytes4 selector) external view returns (bool);
}

/// @title MHVaultPending
/// @notice Audit R2-01: finds pending ("sleeper") Vault V2 submissions. A Vault V2 or Morpho adapter timelock only
///         bounds data submitted after it was set: data submitted while it was shorter (every timelock starts at 0)
///         keeps its `executableAt` forever and anyone can execute it once matured, so a vault whose timelocks read
///         7d/3d can still change allocators, raise caps or drop a timelock in one transaction. `executableAt` is
///         keyed by the full calldata, so pending data can only be found from the `Submit` logs: this library reads
///         every `Submit` of the vault and of each current adapter since the vault's creation, and reports each one
///         whose `executableAt(data)` is still non-zero and whose selector is not abdicated (abdicated data can
///         never execute). Completeness rests on the scan starting at or before the vault's creation, which is
///         checked against the Vault V2 factory's `CreateVaultV2` log. Adapters only accept `submit` from the
///         vault's curator, so none of their submissions predates the vault.
///         Used by `CheckVaultPending` (mandatory before scheduling and before executing `allowVault`, and by the
///         Guardian's monitor), `BuildBaseBatch.run` and `VerifyBase.run`.
library MHVaultPending {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice `Submit(bytes4,bytes,uint256)` topic, identical on the vault and on the market adapter.
    bytes32 internal constant SUBMIT_TOPIC = keccak256("Submit(bytes4,bytes,uint256)");
    /// @notice `VaultV2Factory.CreateVaultV2(address,address,bytes32,address)` topic (`newVaultV2` is topic 3).
    bytes32 internal constant CREATE_VAULT_V2_TOPIC =
        keccak256("CreateVaultV2(address,address,bytes32,address)");

    /// @notice One `Submit` log.
    struct Submission {
        address target;
        bytes data;
        uint256 executableAt;
        uint256 blockNumber;
    }

    /// @notice Data submitted to `target` is still pending (executable now or later) and not abdicated.
    error PendingSubmission(address target, bytes4 selector, uint256 executableAt, bytes data);
    /// @notice The vault's `CreateVaultV2` log is not in the first chunk of the scan: either the scan starts after
    ///         the vault was created (it could miss submissions) or the vault was not created by the factory.
    error VaultCreationNotFound(address vault, address factory, uint256 fromBlock, uint256 toBlock);
    /// @notice The block range or chunk size is invalid.
    error BadScanRange(uint256 fromBlock, uint256 toBlock, uint256 chunk);

    // ================================================================ Targets and anchor

    /// @notice The vault followed by each of its current adapters.
    /// @param vault The Vault V2.
    /// @return t The addresses whose `Submit` logs must be scanned.
    function targetsOf(address vault) internal view returns (address[] memory t) {
        uint256 n = IVaultV2(vault).adaptersLength();
        t = new address[](n + 1);
        t[0] = vault;
        for (uint256 i; i < n; ++i) {
            t[i + 1] = IVaultV2(vault).adapters(i);
        }
    }

    /// @notice Requires the factory's `CreateVaultV2` log for `vault` in `[fromBlock, fromBlock + chunk − 1]`, so
    ///         a scan from `fromBlock` sees every submission (and the vault is a genuine factory Vault V2).
    /// @param vault The vault.
    /// @param factory The Vault V2 factory.
    /// @param fromBlock The scan's first block (the vault's creation block, or a little before).
    /// @param chunk The `eth_getLogs` range.
    function requireCreatedIn(address vault, address factory, uint256 fromBlock, uint256 chunk) internal {
        uint256 toBlock = fromBlock + chunk - 1;
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = CREATE_VAULT_V2_TOPIC;
        Vm.EthGetLogs[] memory l = vm.eth_getLogs(fromBlock, toBlock, factory, topics);
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics.length == 4 && address(uint160(uint256(l[i].topics[3]))) == vault) return;
        }
        revert VaultCreationNotFound(vault, factory, fromBlock, toBlock);
    }

    // ================================================================ Collecting Submit logs

    /// @notice Every `Submit` log of `targets` in `[fromBlock, toBlock]`, read with `eth_getLogs` in `chunk`-block
    ///         requests (an archive RPC is needed for an old vault).
    /// @param targets The vault and its adapters.
    /// @param fromBlock First block.
    /// @param toBlock Last block.
    /// @param chunk Blocks per request.
    /// @return s The submissions, in log order per target.
    function fromRpc(address[] memory targets, uint256 fromBlock, uint256 toBlock, uint256 chunk)
        internal
        returns (Submission[] memory s)
    {
        if (chunk == 0 || fromBlock > toBlock) revert BadScanRange(fromBlock, toBlock, chunk);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = SUBMIT_TOPIC;
        for (uint256 t; t < targets.length; ++t) {
            for (uint256 from = fromBlock; from <= toBlock; from += chunk) {
                uint256 to = from + chunk - 1 > toBlock ? toBlock : from + chunk - 1;
                Vm.EthGetLogs[] memory l = vm.eth_getLogs(from, to, targets[t], topics);
                Submission[] memory next = new Submission[](s.length + l.length);
                for (uint256 i; i < s.length; ++i) {
                    next[i] = s[i];
                }
                for (uint256 i; i < l.length; ++i) {
                    (bytes memory data, uint256 at) = abi.decode(l[i].data, (bytes, uint256));
                    next[s.length + i] = Submission(targets[t], data, at, l[i].blockNumber);
                }
                s = next;
            }
        }
    }

    /// @notice Every `Submit` log of `targets` among logs recorded with `vm.recordLogs` (tests and simulations).
    /// @param logs The recorded logs.
    /// @param targets The vault and its adapters.
    /// @return s The submissions.
    function fromRecorded(Vm.Log[] memory logs, address[] memory targets)
        internal
        pure
        returns (Submission[] memory s)
    {
        uint256 n;
        Submission[] memory all = new Submission[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != SUBMIT_TOPIC) continue;
            if (!_isTarget(logs[i].emitter, targets)) continue;
            (bytes memory data, uint256 at) = abi.decode(logs[i].data, (bytes, uint256));
            all[n++] = Submission(logs[i].emitter, data, at, 0);
        }
        s = new Submission[](n);
        for (uint256 i; i < n; ++i) {
            s[i] = all[i];
        }
    }

    // ================================================================ Checking

    /// @notice The submissions still pending on their target (`executableAt(data) != 0`) whose selector is not
    ///         abdicated, matured or not.
    /// @param subs Submissions from `fromRpc` or `fromRecorded`.
    /// @return p The pending ones.
    function pending(Submission[] memory subs) internal view returns (Submission[] memory p) {
        uint256 n;
        Submission[] memory all = new Submission[](subs.length);
        for (uint256 i; i < subs.length; ++i) {
            Submission memory x = subs[i];
            if (x.data.length < 4 || _seen(all, n, x)) continue;
            ITimelockedV2 t = ITimelockedV2(x.target);
            uint256 at = t.executableAt(x.data);
            if (at == 0 || t.abdicated(bytes4(x.data))) continue;
            x.executableAt = at;
            all[n++] = x;
        }
        p = new Submission[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = all[i];
        }
    }

    /// @notice Reverts `PendingSubmission` on the first pending submission.
    /// @param p The pending submissions.
    function requireNone(Submission[] memory p) internal pure {
        if (p.length != 0) {
            revert PendingSubmission(p[0].target, bytes4(p[0].data), p[0].executableAt, p[0].data);
        }
    }

    /// @notice The full scan: anchor on the vault's creation, read every `Submit` of the vault and its adapters
    ///         from `fromBlock` to `toBlock`, and revert on any pending submission.
    /// @param vault The vault.
    /// @param factory The Vault V2 factory.
    /// @param fromBlock The vault's creation block (or a little before, within `chunk`).
    /// @param toBlock Last block (normally the head).
    /// @param chunk Blocks per `eth_getLogs` request.
    /// @return scanned The number of `Submit` logs read.
    function scan(address vault, address factory, uint256 fromBlock, uint256 toBlock, uint256 chunk)
        internal
        returns (uint256 scanned)
    {
        if (chunk == 0 || fromBlock > toBlock) revert BadScanRange(fromBlock, toBlock, chunk);
        requireCreatedIn(vault, factory, fromBlock, chunk);
        Submission[] memory subs = fromRpc(targetsOf(vault), fromBlock, toBlock, chunk);
        requireNone(pending(subs));
        return subs.length;
    }

    // ================================================================ Helpers

    function _isTarget(address a, address[] memory targets) private pure returns (bool) {
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == a) return true;
        }
        return false;
    }

    /// @dev The same (target, data) is reported once (it can be submitted, executed and submitted again).
    function _seen(Submission[] memory all, uint256 n, Submission memory x) private pure returns (bool) {
        bytes32 h = keccak256(x.data);
        for (uint256 i; i < n; ++i) {
            if (all[i].target == x.target && keccak256(all[i].data) == h) return true;
        }
        return false;
    }
}
