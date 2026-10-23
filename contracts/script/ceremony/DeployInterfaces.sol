// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISafe (vendored subset of Safe v1.4.1)
/// @notice Signatures copied from safe-global/safe-smart-account tag v1.4.1 (`contracts/Safe.sol`,
///         `base/OwnerManager.sol`, `base/ModuleManager.sol`). `Enum.Operation` is ABI-encoded as `uint8`.
interface ISafe {
    /// @notice "1.4.1".
    function VERSION() external view returns (string memory);
    /// @notice Owners in linked-list order.
    function getOwners() external view returns (address[] memory);
    /// @notice Confirmation threshold.
    function getThreshold() external view returns (uint256);
    /// @notice Whether `owner` is an owner.
    function isOwner(address owner) external view returns (bool);
    /// @notice Next transaction nonce.
    function nonce() external view returns (uint256);
    /// @notice Hashes approved by each owner (`approveHash`).
    function approvedHashes(address owner, bytes32 hash) external view returns (uint256);
    /// @notice Paginated module list starting at `start` (SENTINEL = 0x1).
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    /// @notice EIP-712 domain separator (chainId, this).
    function domainSeparator() external view returns (bytes32);
    /// @notice EIP-712 hash of a Safe transaction.
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    /// @notice Marks `hashToApprove` as approved by `msg.sender` (an owner).
    function approveHash(bytes32 hashToApprove) external;
    /// @notice Executes a Safe transaction.
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    /// @notice Initial setup of a proxy.
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    /// @notice Enables a module (authorized: only the Safe itself).
    function enableModule(address module) external;
    /// @notice Sets a guard (authorized: only the Safe itself).
    function setGuard(address guard) external;
}

/// @title ISafeProxyFactory (vendored subset of Safe v1.4.1 `proxies/SafeProxyFactory.sol`)
interface ISafeProxyFactory {
    /// @notice Deploys a SafeProxy with CREATE2 and calls `initializer` on it.
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    /// @notice SafeProxy creation code (without the singleton argument).
    function proxyCreationCode() external pure returns (bytes memory);
}

/// @title IMultiSendCallOnly (Safe v1.4.1 `libraries/MultiSendCallOnly.sol`)
interface IMultiSendCallOnly {
    /// @notice Packed (uint8 operation = 0, address to, uint256 value, uint256 dataLength, bytes data) entries.
    function multiSend(bytes memory transactions) external payable;
}

/// @title ICreateX (vendored subset of pcaversaccio/createx `src/CreateX.sol`, main)
interface ICreateX {
    /// @notice CREATE3 deployment. The salt is guarded (`_guard`): with bytes 0..19 == msg.sender and byte 20 ==
    ///         0x01 the effective salt is keccak256(abi.encode(msg.sender, block.chainid, salt)).
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    /// @notice CREATE3 address for an already-guarded `salt` and `deployer`.
    function computeCreate3Address(bytes32 salt, address deployer)
        external
        pure
        returns (address computedAddress);
}

/// @notice Morpho `VaultV2Factory` provenance view (morpho-org/vault-v2 @ abaae813 `IVaultV2Factory.sol`).
interface IVaultV2FactoryView {
    /// @notice Whether `account` was created by this factory.
    function isVaultV2(address account) external view returns (bool);
}
