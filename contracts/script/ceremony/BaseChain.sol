// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BaseChain
/// @notice Pinned external addresses and runtime codehashes for the circle deployment ceremony (spec §5, Appendix A).
///         Every address is checksummed. Every codehash was read on Base 8453 and Base Sepolia 84532 on 2026-10-22
///         (mainnet head 52,940,172) and, where the publisher states one, matched against the published value:
///         - Safe v1.4.1 (SafeL2 singleton, SafeProxyFactory, MultiSendCallOnly, CompatibilityFallbackHandler):
///           `codeHash` in safe-global/safe-deployments `src/assets/v1.4.1/*.json` ("canonical" deployment), identical
///           on both chains;
///         - CreateX: the runtime-bytecode hash stated in the pcaversaccio/createx README, identical on both chains;
///         - SafeProxy v1.4.1: runtime code returned by `proxyCreationCode()` ‖ abi.encode(SafeL2), executed with
///           `cast call --create` (171 bytes; the singleton lives in storage slot 0, so every proxy has this hash);
///         - USDC: Circle's FiatTokenProxy on each chain (addresses from developers.circle.com
///           "USDC contract addresses"). The proxy's code never changes on an implementation upgrade, so pinning the
///           proxy codehash is stable; the implementation is deliberately not pinned (Circle can upgrade it).
library BaseChain {
    // ---------------------------------------------------------------- Chains

    /// @notice Base mainnet.
    uint256 internal constant BASE = 8453;
    /// @notice Base Sepolia (rehearsal only).
    uint256 internal constant BASE_SEPOLIA = 84532;

    // ---------------------------------------------------------------- USDC (per chain)

    /// @notice Native USDC on Base mainnet (Appendix A).
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice Runtime codehash of the Base mainnet USDC proxy.
    bytes32 internal constant USDC_BASE_CODEHASH =
        0xa6705a10bb756b5dea144591118be77d7af0c3eee3bf2dfe2583dcb0364fefab;
    /// @notice Native USDC on Base Sepolia (Circle testnet deployment).
    address internal constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    /// @notice Runtime codehash of the Base Sepolia USDC proxy.
    bytes32 internal constant USDC_BASE_SEPOLIA_CODEHASH =
        0xedc5281a85c0efecd49999a1ef668390c59b88702f2d4a07029d7f5d63059d6c;

    // ---------------------------------------------------------------- Deterministic deployments (same on both chains)

    /// @notice CreateX (Appendix A).
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    /// @notice CreateX runtime codehash (createx README).
    bytes32 internal constant CREATEX_CODEHASH =
        0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    /// @notice SafeL2 v1.4.1 singleton (Appendix A).
    address internal constant SAFE_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    /// @notice SafeL2 v1.4.1 runtime codehash (safe-deployments).
    bytes32 internal constant SAFE_L2_CODEHASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;

    /// @notice SafeProxyFactory v1.4.1 (Appendix A).
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    /// @notice SafeProxyFactory v1.4.1 runtime codehash (safe-deployments).
    bytes32 internal constant SAFE_PROXY_FACTORY_CODEHASH =
        0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;

    /// @notice Multicall3 (same address on every chain): a public call forwarder, never acceptable as the operator
    ///         (audit 2 R1-26).
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @notice MultiSendCallOnly v1.4.1 (Appendix A). The only delegatecall target the Gov Safe signs for.
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    /// @notice MultiSendCallOnly v1.4.1 runtime codehash (safe-deployments).
    bytes32 internal constant MULTISEND_CALL_ONLY_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;

    /// @notice CompatibilityFallbackHandler v1.4.1 (Appendix A).
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    /// @notice CompatibilityFallbackHandler v1.4.1 runtime codehash (safe-deployments).
    bytes32 internal constant FALLBACK_HANDLER_CODEHASH =
        0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9;

    /// @notice Runtime codehash of every SafeProxy created by SafeProxyFactory v1.4.1.
    bytes32 internal constant SAFE_PROXY_CODEHASH =
        0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;

    // ---------------------------------------------------------------- Circle vault (Base mainnet only)

    /// @notice The only Vault V2 a ceremony may allowlist on Base mainnet: Gauntlet USDC Prime (spec Appendix A,
    ///         source "Morpho API"). Audit R2-03: `CIRCLE_VAULT` changes no initcode, address or batch hash, so it is
    ///         bound here, in reviewed source covered by the audited commit, instead; a different vault needs a
    ///         reviewed change to this file. Base Sepolia has no vault (address(0)).
    address internal constant CIRCLE_VAULT_BASE = 0x050cE30b927Da55177A4914EC73480238BAD56f0;
    /// @notice Morpho `VaultV2Factory` on Base. [VERIFY] against Morpho's published Base addresses before mainnet:
    ///         read on chain 2026-10-22, `isVaultV2(CIRCLE_VAULT_BASE) == true`. Used only to fail closed: the vault
    ///         must have been created by it (provenance, R1-04 open question 5), and its `CreateVaultV2` log anchors
    ///         the pending-submission scan (audit R2-01).
    address internal constant VAULT_V2_FACTORY_BASE = 0x4501125508079A99ebBebCE205DeC9593C2b5857;
    /// @notice Morpho adapter registry (RegistryList) the circle vault must use. [VERIFY] against Morpho's
    ///         published Base addresses before mainnet: read on chain 2026-10-22 as Gauntlet USDC Prime's
    ///         `adapterRegistry()` (owner 0xcBa28b38103307Ec8dA98377ffF9816C164f9AFa). Audit R2-01 (d): any
    ///         non-zero registry used to pass, including a curator-owned one. Used only to fail closed.
    address internal constant MORPHO_ADAPTER_REGISTRY_BASE = 0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a;

    // ---------------------------------------------------------------- Safe v1.4.1 storage and hashing

    /// @notice Storage slot of the proxy's singleton (`SafeStorage.singleton`).
    bytes32 internal constant SAFE_SINGLETON_SLOT = bytes32(uint256(0));
    /// @notice Storage slot of `SafeStorage.nonce`.
    bytes32 internal constant SAFE_NONCE_SLOT = bytes32(uint256(5));
    /// @notice `GuardManager.GUARD_STORAGE_SLOT` (keccak256("guard_manager.guard.address")).
    bytes32 internal constant SAFE_GUARD_SLOT =
        0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    /// @notice `FallbackManager.FALLBACK_HANDLER_STORAGE_SLOT` (keccak256("fallback_manager.handler.address")).
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    /// @notice Linked-list sentinel for owners and modules.
    address internal constant SAFE_SENTINEL = address(0x1);
    /// @notice keccak256("EIP712Domain(uint256 chainId,address verifyingContract)").
    bytes32 internal constant SAFE_DOMAIN_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    /// @notice keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256
    ///         baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)").
    bytes32 internal constant SAFE_TX_TYPEHASH =
        0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;
    /// @notice Safe `Enum.Operation.Call`.
    uint8 internal constant OP_CALL = 0;
    /// @notice Safe `Enum.Operation.DelegateCall`.
    uint8 internal constant OP_DELEGATECALL = 1;

    // ---------------------------------------------------------------- Ceremony bounds (spec §5)

    /// @notice Each batch stays at or under 10M gas (Base's per-transaction cap is 2^24).
    uint256 internal constant MAX_BATCH_GAS = 10_000_000;
    /// @notice Shortest Timelock delay accepted (48h at launch).
    uint256 internal constant MIN_TIMELOCK_DELAY = 48 hours;
    /// @notice Longest Timelock delay accepted (7 days after ~90 stable days).
    uint256 internal constant MAX_TIMELOCK_DELAY = 7 days;
    /// @notice Smallest Safe threshold accepted for any of the three Safes.
    uint256 internal constant MIN_SAFE_THRESHOLD = 2;
    /// @notice Smallest Gov Safe threshold, except a 2-of-3 Gov Safe (spec §5: 3-of-5, minimum 2-of-3).
    uint256 internal constant MIN_GOV_THRESHOLD = 3;

    /// @notice Safe roles for `safePolicyOk`.
    uint8 internal constant ROLE_GOV = 0;
    uint8 internal constant ROLE_GUARDIAN = 1;
    uint8 internal constant ROLE_TREASURY = 2;

    /// @notice Spec §5 threshold policy per Safe role (audit R2-17: "2 ≤ threshold < owners" accepted a 2-of-9 Gov or
    ///         Guardian Safe). Every Safe keeps a spare key (`threshold < owners`). Gov (3-of-5, minimum 2-of-3): a
    ///         strict majority and at least 3, or exactly 2-of-3. Guardian (2-of-4) and Treasury (2-of-3): at least 2
    ///         and at least half the owners.
    /// @param role `ROLE_GOV`, `ROLE_GUARDIAN` or `ROLE_TREASURY`.
    /// @param threshold The Safe threshold.
    /// @param owners The owner count.
    /// @return Whether the policy holds.
    function safePolicyOk(uint8 role, uint256 threshold, uint256 owners) internal pure returns (bool) {
        if (threshold < MIN_SAFE_THRESHOLD || threshold >= owners) return false;
        if (role == ROLE_GOV) {
            return threshold * 2 > owners && (threshold >= MIN_GOV_THRESHOLD || owners == 3);
        }
        return threshold * 2 >= owners;
    }

    /// @notice The circle vault a ceremony may allowlist on `chainId` (address(0): none allowed).
    /// @param chainId The chain id.
    /// @return The pinned vault.
    function circleVaultOf(uint256 chainId) internal pure returns (address) {
        return chainId == BASE ? CIRCLE_VAULT_BASE : address(0);
    }

    /// @notice Canonical USDC for `chainId`, or address(0) for an unsupported chain.
    /// @param chainId The chain id.
    /// @return usdc The USDC address.
    /// @return codehash Its pinned proxy codehash.
    function usdcOf(uint256 chainId) internal pure returns (address usdc, bytes32 codehash) {
        if (chainId == BASE) return (USDC_BASE, USDC_BASE_CODEHASH);
        if (chainId == BASE_SEPOLIA) return (USDC_BASE_SEPOLIA, USDC_BASE_SEPOLIA_CODEHASH);
        return (address(0), bytes32(0));
    }

    /// @notice Manifest/network label for `chainId` ("base-mainnet" or "base-sepolia"), empty if unsupported.
    /// @param chainId The chain id.
    /// @return The label.
    function networkOf(uint256 chainId) internal pure returns (string memory) {
        if (chainId == BASE) return "base-mainnet";
        if (chainId == BASE_SEPOLIA) return "base-sepolia";
        return "";
    }
}
