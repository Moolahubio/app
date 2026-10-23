// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Cheatcodes forge 1.7.1 provides that forge-std v1.9.4's `Vm` does not declare yet (EIP-7702 and the
///         per-test EVM version). Test-only.
interface IVm7702 {
    struct SignedDelegation {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint64 nonce;
        address implementation;
    }

    function signAndAttachDelegation(address implementation, uint256 privateKey)
        external
        returns (SignedDelegation memory signedDelegation);
    function setEvmVersion(string calldata evm) external;
}

/// @notice Test-only Kernel-style batch executor that an EOA delegates to with EIP-7702. Only the account itself
///         can execute (a self-call, as when the EOA signs the transaction), and every call keeps the EOA as
///         `msg.sender`. Never deploy.
contract Mock7702BatchExecutor {
    struct Call {
        address target;
        bytes data;
    }

    error NotSelf();

    function execute(Call[] calldata calls) external {
        if (msg.sender != address(this)) revert NotSelf();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
