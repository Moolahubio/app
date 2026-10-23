// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";

/// @notice Test-only extra Morpho Vault V2 surface used by the Base fork tests. Every signature is copied verbatim
///         from morpho-org/vault-v2 `src/interfaces/IVaultV2.sol` and `src/VaultV2.sol`
///         (main @ abaae813e754218061e7326e37487df718edd576, the commit `IVaultV2` is vendored from).
interface IVaultV2Fork is IVaultV2 {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function executableAt(bytes memory data) external view returns (uint256);
    function performanceFee() external view returns (uint96);
    function performanceFeeRecipient() external view returns (address);
    function maxRate() external view returns (uint64);
    function forceDeallocatePenalty(address adapter) external view returns (uint256);
    function submit(bytes memory data) external;
    function decreaseTimelock(bytes4 selector, uint256 newDuration) external;
    function accrueInterest() external;
    function maxWithdraw(address) external pure returns (uint256);
    function maxRedeem(address) external pure returns (uint256);
}

/// @notice Morpho Blue market parameters (morpho-org/morpho-blue `src/interfaces/IMorpho.sol`).
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Test-only Morpho Blue subset (signatures verbatim from morpho-org/morpho-blue `IMorpho.sol`, main).
interface IMorphoBlue {
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function accrueInterest(MarketParams memory marketParams) external;
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @notice Morpho Blue oracle (morpho-org/morpho-blue `src/interfaces/IOracle.sol`): price of one collateral unit
///         in loan units, scaled by 1e36.
interface IOracle {
    function price() external view returns (uint256);
}

/// @notice Circle FiatToken v2.2 roles used to blacklist and pause on the fork (FiatTokenV1 `Blacklistable`,
///         `Pausable`).
interface IFiatToken {
    function blacklister() external view returns (address);
    function pauser() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function pause() external;
    function unpause() external;
    function isBlacklisted(address account) external view returns (bool);
    function paused() external view returns (bool);
}
