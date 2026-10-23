// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";

import { IVaultV2 } from "../src/circles/interfaces/IVaultV2.sol";
import { BaseChain } from "./ceremony/BaseChain.sol";
import { IVaultV2FactoryView } from "./ceremony/DeployInterfaces.sol";
import { MHVaultPending } from "./ceremony/MHVaultPending.sol";

/// @notice The Vault V2 role and cap views the review prints (VaultV2.sol @ abaae813).
interface IVaultV2Roles {
    function curator() external view returns (address);
    function isAllocator(address account) external view returns (bool);
    function liquidityAdapter() external view returns (address);
    function absoluteCap(bytes32 id) external view returns (uint256);
}

/// @title CheckVaultPending
/// @notice Audit R2-01: the mandatory pending-submission scan of a circle vault. `registry.allowVault` checks
///         timelock durations, but a duration only bounds data submitted after it was set; data submitted earlier
///         ("sleepers") stays executable by anyone, so this scan is part of the allowVault check. Read-only, never
///         broadcasts. Fails (non-zero exit) when any data is still pending on the vault or on one of its adapters,
///         printing every pending entry (target, selector, `executableAt`, matured or not, the calldata) first.
///
///         Run it (runbook step 10) before Gov signs the allowVault schedule transaction, again right before the
///         execute transaction, and from the Guardian's monitor on a schedule for every allowlisted vault (it keeps
///         failing while any entry remains; the Guardian then calls `registry.disallowVault`):
///           CIRCLE_VAULT_FROM_BLOCK=<vault creation block> forge script script/CheckVaultPending.s.sol --rpc-url base
///         Environment: CIRCLE_VAULT (default: the vault pinned for the chain in `BaseChain`), CIRCLE_VAULT_FROM_BLOCK
///         (required: the vault's creation block, checked against the factory's `CreateVaultV2` log; Gauntlet USDC
///         Prime: 37,179,342), LOG_CHUNK (default 5,000; the RPC must serve archive `eth_getLogs` at that range).
///
///         Audit 2 R1-23: the check is mandatory for EVERY allowVault proposal, not just the ceremony vault. On Base it
///         also requires the vault to come from the pinned Vault V2 factory and to use the pinned Morpho adapter
///         registry (a curator-owned registry would let a malicious adapter in after the 7-day addAdapter timelock),
///         and it prints, for explicit sign-off, every current allocator (from `SetIsAllocator` logs; allocators act
///         instantly: liquidity adapter, allocations within existing caps, audit 2 R1-01), whether the curator is
///         one, the liquidity adapter, and every id with a non-zero absolute cap (from `IncreaseAbsoluteCap` logs).
contract CheckVaultPending is Script {
    /// @notice Run under `--broadcast`/`--resume`.
    error NeverBroadcast();
    /// @notice No vault to check on this chain.
    error NoVault(uint256 chainId);
    /// @notice The vault was not created by the pinned Vault V2 factory.
    error VaultNotFromFactory(address vault);
    /// @notice The vault's adapter registry is not the pinned Morpho registry.
    error AdapterRegistryNotPinned(address expected, address actual);

    /// @notice `SetIsAllocator(address indexed account, bool newIsAllocator)`.
    bytes32 internal constant SET_IS_ALLOCATOR_TOPIC = keccak256("SetIsAllocator(address,bool)");
    /// @notice `IncreaseAbsoluteCap(bytes32 indexed id, bytes idData, uint256 newAbsoluteCap)`.
    bytes32 internal constant INCREASE_ABSOLUTE_CAP_TOPIC =
        keccak256("IncreaseAbsoluteCap(bytes32,bytes,uint256)");

    /// @notice Reads the environment and scans.
    function run() external {
        if (
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                || vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) revert NeverBroadcast();
        address vault = vm.envOr("CIRCLE_VAULT", BaseChain.circleVaultOf(block.chainid));
        if (vault == address(0)) revert NoVault(block.chainid);
        check(
            vault, vm.envUint("CIRCLE_VAULT_FROM_BLOCK"), block.number, vm.envOr("LOG_CHUNK", uint256(5_000))
        );
    }

    /// @notice Scans `vault` and its adapters from `fromBlock` to `toBlock`; prints and reverts on any pending data.
    /// @param vault The Vault V2.
    /// @param fromBlock The vault's creation block.
    /// @param toBlock Last block.
    /// @param chunk Blocks per `eth_getLogs` request.
    /// @return scanned The number of `Submit` logs read.
    function check(address vault, uint256 fromBlock, uint256 toBlock, uint256 chunk)
        public
        returns (uint256 scanned)
    {
        checkProvenance(vault);
        MHVaultPending.requireCreatedIn(vault, BaseChain.VAULT_V2_FACTORY_BASE, fromBlock, chunk);
        address[] memory targets = MHVaultPending.targetsOf(vault);
        MHVaultPending.Submission[] memory subs = MHVaultPending.fromRpc(targets, fromBlock, toBlock, chunk);
        MHVaultPending.Submission[] memory p = MHVaultPending.pending(subs);
        console2.log("CheckVaultPending: vault", vault);
        console2.log("  adapters scanned       ", targets.length - 1);
        console2.log("  Submit logs read       ", subs.length);
        console2.log("  pending (not abdicated)", p.length);
        for (uint256 i; i < p.length; ++i) {
            console2.log(
                string.concat(
                    "  PENDING target ",
                    vm.toString(p[i].target),
                    " selector ",
                    vm.toString(abi.encodePacked(bytes4(p[i].data))),
                    // forge-lint: disable-next-line(block-timestamp)
                    p[i].executableAt <= block.timestamp
                        ? " MATURED (executable by anyone now)"
                        : " executableAt ",
                    // forge-lint: disable-next-line(block-timestamp)
                    p[i].executableAt <= block.timestamp ? "" : vm.toString(p[i].executableAt),
                    " data ",
                    vm.toString(p[i].data)
                )
            );
        }
        MHVaultPending.requireNone(p);
        review(
            vault,
            _logged(vault, SET_IS_ALLOCATOR_TOPIC, fromBlock, toBlock, chunk),
            _logged(vault, INCREASE_ABSOLUTE_CAP_TOPIC, fromBlock, toBlock, chunk)
        );
        return subs.length;
    }

    /// @notice On Base: the vault comes from the pinned Vault V2 factory and uses the pinned Morpho adapter registry
    ///         (audit R2-01 (d), extended to every allowVault proposal by audit 2 R1-23).
    /// @param vault The Vault V2.
    function checkProvenance(address vault) public view {
        if (block.chainid != BaseChain.BASE) return;
        if (!IVaultV2FactoryView(BaseChain.VAULT_V2_FACTORY_BASE).isVaultV2(vault)) {
            revert VaultNotFromFactory(vault);
        }
        address registry = IVaultV2(vault).adapterRegistry();
        if (registry != BaseChain.MORPHO_ADAPTER_REGISTRY_BASE) {
            revert AdapterRegistryNotPinned(BaseChain.MORPHO_ADAPTER_REGISTRY_BASE, registry);
        }
    }

    /// @notice Prints, for sign-off, the instant powers a timelock does not bound: every current allocator among
    ///         `accounts` (with a warning when the curator is one, audit 2 R1-01), the liquidity adapter, and every id
    ///         among `ids` with a non-zero absolute cap (allocators can move funds into those markets instantly).
    /// @param vault The Vault V2.
    /// @param accounts Every account ever named in a `SetIsAllocator` log (topic 1).
    /// @param ids Every id ever named in an `IncreaseAbsoluteCap` log (topic 1).
    /// @return allocators The current allocators.
    /// @return curatorIsAllocator Whether the curator is one of them.
    function review(address vault, bytes32[] memory accounts, bytes32[] memory ids)
        public
        view
        returns (address[] memory allocators, bool curatorIsAllocator)
    {
        IVaultV2Roles v = IVaultV2Roles(vault);
        address curator = v.curator();
        allocators = new address[](accounts.length);
        uint256 n;
        for (uint256 i; i < accounts.length; ++i) {
            address a = address(uint160(uint256(accounts[i])));
            if (!v.isAllocator(a) || _contains(allocators, n, a)) continue;
            allocators[n++] = a;
            if (a == curator) curatorIsAllocator = true;
            console2.log("  ALLOCATOR (instant powers)", a, a == curator ? "  <- the curator" : "");
        }
        assembly ("memory-safe") {
            mstore(allocators, n)
        }
        if (curatorIsAllocator) {
            console2.log(
                "  WARNING: the curator is an allocator; the Guardian's exit is `forceExit` (audit 2 R1-01)"
            );
        }
        console2.log("  liquidity adapter      ", v.liquidityAdapter());
        for (uint256 i; i < ids.length; ++i) {
            uint256 cap = v.absoluteCap(ids[i]);
            if (cap != 0) console2.log(string.concat("  CAP id ", vm.toString(ids[i]), " absolute "), cap);
        }
    }

    function _logged(address vault, bytes32 topic, uint256 fromBlock, uint256 toBlock, uint256 chunk)
        private
        returns (bytes32[] memory out)
    {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic;
        bytes32[] memory all = new bytes32[](0);
        for (uint256 from = fromBlock; from <= toBlock; from += chunk) {
            uint256 to = from + chunk - 1 > toBlock ? toBlock : from + chunk - 1;
            Vm.EthGetLogs[] memory l = vm.eth_getLogs(from, to, vault, topics);
            bytes32[] memory next = new bytes32[](all.length + l.length);
            for (uint256 i; i < all.length; ++i) {
                next[i] = all[i];
            }
            for (uint256 i; i < l.length; ++i) {
                next[all.length + i] = l[i].topics.length > 1 ? l[i].topics[1] : bytes32(0);
            }
            all = next;
        }
        return all;
    }

    function _contains(address[] memory a, uint256 n, address x) private pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == x) return true;
        }
        return false;
    }
}
