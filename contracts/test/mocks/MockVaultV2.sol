// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IVaultV2 } from "../../src/circles/interfaces/IVaultV2.sol";
import { MockUSDC } from "./MockUSDC.sol";

/// @notice Test-only Morpho Vault V2. Never deploy.
///         - Governance surface: asset, gates, timelocks, abdication and sentinels with free setters, so tests can
///           toggle each `allowVault` check. It starts in the "Gauntlet USDC Prime" shape: exit gates zero and
///           abdicated, `setIsAllocator`/`addAdapter` timelocked 7 days.
///         - ERC-4626 mechanics with Vault V2's exact conversion formulas (VaultV2.sol @ abaae813):
///           `virtualShares = 10^(18 − 6) = 1e12`, `previewDeposit`/`previewRedeem` round down,
///           `previewWithdraw` rounds up, all over `(totalSupply + virtualShares)` and `(totalAssets + 1)`.
///           `withdraw(assets, receiver, onBehalf)` and `redeem(shares, receiver, onBehalf)` take Vault V2's
///           argument order. `maxRedeem`/`maxWithdraw` revert, so any test path that calls them fails loudly (Vault
///           V2 returns 0, and circles must never rely on them).
///         - Knobs: yield (USDC minted into the vault), loss (USDC sent away), an exhaustible liquidity budget for
///           exits (illiquidity), deposit and exit blocks (gates), a `previewRedeem` discount (a conservative,
///           drifting preview; actual exits still use the true price), and a broken accrual (audit R1-03: in Vault V2
///           `previewRedeem`, `deposit`, `withdraw` and `redeem` all accrue interest over every adapter's
///           `realAssets()`, so one reverting adapter makes all four revert while share transfers keep working).
///         - Audit 2 R1-01: `forceDeallocate` frees assets from an adapter's market into the vault's idle USDC
///           (`freedIdle`), taking Vault V2's penalty (`forceDeallocatePenalty`, WAD) from `onBehalf` as burned
///           shares whose assets stay in the vault. Exits are paid from `freedIdle` first and only then from the
///           liquidity budget (the liquidity adapter: `mockSetLiquidity(0)` models an allocator pointing it at an
///           empty market). `mockReallocate` models an allocator moving the freed idle back into a market.
contract MockVaultV2 is ERC20 {
    using Math for uint256;

    uint256 public constant VIRTUAL_SHARES = 1e12;
    address public constant LOSS_SINK = address(0xdead);

    address public asset;
    address public owner;
    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;
    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;
    mapping(address account => bool) public isSentinel;
    address public adapterRegistry = address(0xAD);
    address[] internal _adapters;

    uint256 internal _totalAssets;
    /// @notice Assets that can still leave through `withdraw`/`redeem` (type(uint256).max = unlimited).
    uint256 public liquidity = type(uint256).max;
    bool public depositsBlocked;
    bool public exitsBlocked;
    uint256 public previewRedeemDiscount;
    bool public navBroken;
    /// @notice Idle USDC freed by `forceDeallocate`, used by exits before the liquidity budget.
    uint256 public freedIdle;
    /// @notice Assets `forceDeallocate` can still free from the adapters' markets (type(uint256).max = unlimited).
    uint256 public forceable = type(uint256).max;
    mapping(address adapter => uint256 penalty) public forceDeallocatePenalty;

    /// @notice Test-only flow ledger for invariant suites (vault shares): transfers out of / into watched accounts.
    mapping(address account => bool) public watched;
    mapping(address from => mapping(address to => uint256 amount)) public sent;
    mapping(address to => mapping(address from => uint256 amount)) public received;
    mapping(address from => address[] recipients) internal _recipients;
    mapping(address from => mapping(address to => bool seen)) internal _isRecipient;

    constructor(address asset_, address owner_) ERC20("Mock Vault V2", "mvUSDC") {
        asset = asset_;
        owner = owner_;
        abdicated[IVaultV2.setReceiveAssetsGate.selector] = true;
        abdicated[IVaultV2.setReceiveSharesGate.selector] = true;
        abdicated[IVaultV2.setSendSharesGate.selector] = true;
        timelock[IVaultV2.setIsAllocator.selector] = 7 days;
        timelock[IVaultV2.addAdapter.selector] = 7 days;
        // Audit R1-04 checks, in the Gauntlet USDC Prime shape (Base, block 52.94M): removeAdapter 7 days,
        // setAdapterRegistry abdicated, caps and fees 3 days.
        timelock[IVaultV2.removeAdapter.selector] = 7 days;
        abdicated[IVaultV2.setAdapterRegistry.selector] = true;
        timelock[IVaultV2.increaseAbsoluteCap.selector] = 3 days;
        timelock[IVaultV2.increaseRelativeCap.selector] = 3 days;
        timelock[IVaultV2.setPerformanceFee.selector] = 3 days;
        timelock[IVaultV2.setManagementFee.selector] = 3 days;
    }

    function adapters(uint256 index) external view returns (address) {
        return _adapters[index];
    }

    function adaptersLength() external view returns (uint256) {
        return _adapters.length;
    }

    function isAdapter(address account) public view returns (bool) {
        for (uint256 i; i < _adapters.length; ++i) {
            if (_adapters[i] == account) return true;
        }
        return false;
    }

    /// @notice Vault V2 `forceDeallocate` (VaultV2.sol @ abaae813): deallocates `assets` from `adapter` into idle,
    ///         then takes `ceil(assets · penalty)` from `onBehalf` as a withdrawal to the vault itself.
    function forceDeallocate(address adapter, bytes memory, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares)
    {
        require(!navBroken, "MockVaultV2: adapter realAssets reverted");
        require(isAdapter(adapter), "MockVaultV2: not an adapter");
        require(assets <= forceable, "MockVaultV2: market illiquid");
        if (forceable != type(uint256).max) forceable -= assets;
        freedIdle += assets;
        uint256 penaltyAssets = assets.mulDiv(forceDeallocatePenalty[adapter], 1e18, Math.Rounding.Ceil);
        penaltyShares = previewWithdraw(penaltyAssets);
        if (msg.sender != onBehalf) _spendAllowance(onBehalf, msg.sender, penaltyShares);
        // The penalty's assets stay in the vault: the burned shares' value accrues to the remaining holders.
        _burn(onBehalf, penaltyShares);
    }

    // ---------------------------------------------------------------- ERC-4626 (Vault V2 flavour)

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(totalSupply() + VIRTUAL_SHARES, _totalAssets + 1);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(totalSupply() + VIRTUAL_SHARES, _totalAssets + 1, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        require(!navBroken, "MockVaultV2: adapter realAssets reverted");
        uint256 a = _redeemValue(shares);
        return a > previewRedeemDiscount ? a - previewRedeemDiscount : 0;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return previewDeposit(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _redeemValue(shares);
    }

    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares) {
        require(!navBroken, "MockVaultV2: adapter realAssets reverted");
        require(!depositsBlocked, "MockVaultV2: deposits gated");
        shares = previewDeposit(assets);
        require(IERC20(asset).transferFrom(msg.sender, address(this), assets), "MockVaultV2: pull");
        _mint(onBehalf, shares);
        _totalAssets += assets;
    }

    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _exit(assets, shares, receiver, onBehalf);
    }

    function redeem(uint256 shares, address receiver, address onBehalf) external returns (uint256 assets) {
        assets = _redeemValue(shares);
        _exit(assets, shares, receiver, onBehalf);
    }

    function maxRedeem(address) external pure returns (uint256) {
        revert("MockVaultV2: max* must not be called");
    }

    function maxWithdraw(address) external pure returns (uint256) {
        revert("MockVaultV2: max* must not be called");
    }

    // ---------------------------------------------------------------- Vault V2 owner function (wrapper rotation)

    function setIsSentinel(address account, bool newIsSentinel) external {
        require(msg.sender == owner, "Unauthorized");
        isSentinel[account] = newIsSentinel;
    }

    // ---------------------------------------------------------------- Test knobs: governance views

    function mockSetAsset(address a) external {
        asset = a;
    }

    function mockSetReceiveAssetsGate(address g) external {
        receiveAssetsGate = g;
    }

    function mockSetReceiveSharesGate(address g) external {
        receiveSharesGate = g;
    }

    function mockSetSendSharesGate(address g) external {
        sendSharesGate = g;
    }

    function mockSetSendAssetsGate(address g) external {
        sendAssetsGate = g;
    }

    function mockSetTimelock(bytes4 selector, uint256 duration) external {
        timelock[selector] = duration;
    }

    function mockSetAbdicated(bytes4 selector, bool value) external {
        abdicated[selector] = value;
    }

    function mockSetAdapterRegistry(address r) external {
        adapterRegistry = r;
    }

    function mockAddAdapter(address a) external {
        _adapters.push(a);
    }

    // ---------------------------------------------------------------- Test knobs: economics

    /// @notice Interest: `assets` USDC appear in the vault and in `totalAssets`.
    function mockYield(uint256 assets) external {
        MockUSDC(asset).mint(address(this), assets);
        _totalAssets += assets;
    }

    /// @notice Bad debt: `assets` USDC leave the vault and `totalAssets`.
    function mockLoss(uint256 assets) external {
        _totalAssets -= assets;
        require(IERC20(asset).transfer(LOSS_SINK, assets), "MockVaultV2: loss");
    }

    /// @notice Sets the remaining exit liquidity (the liquidity adapter's market being borrowed out).
    function mockSetLiquidity(uint256 assets) external {
        liquidity = assets;
    }

    function mockSetDepositsBlocked(bool blocked) external {
        depositsBlocked = blocked;
    }

    function mockSetExitsBlocked(bool blocked) external {
        exitsBlocked = blocked;
    }

    function mockSetPreviewRedeemDiscount(uint256 assets) external {
        previewRedeemDiscount = assets;
    }

    /// @notice Makes every accruing entry point (`previewRedeem`, `deposit`, `withdraw`, `redeem`) revert.
    function mockSetNavBroken(bool broken) external {
        navBroken = broken;
    }

    /// @notice Vault V2 `setForceDeallocatePenalty` (WAD, at most 2%; timelocked in the real vault).
    function mockSetForceDeallocatePenalty(address adapter, uint256 penalty) external {
        require(penalty <= 0.02e18, "MockVaultV2: penalty above 2%");
        forceDeallocatePenalty[adapter] = penalty;
    }

    /// @notice Caps what `forceDeallocate` can still free (the markets' own liquidity).
    function mockSetForceable(uint256 assets) external {
        forceable = assets;
    }

    /// @notice An allocator moves the idle USDC freed by `forceDeallocate` back into a market (instant).
    function mockReallocate() external {
        freedIdle = 0;
    }

    // ---------------------------------------------------------------- Test knobs: flow ledger

    function watch(address account) external {
        watched[account] = true;
    }

    function recipientsOf(address from) external view returns (address[] memory) {
        return _recipients[from];
    }

    // ---------------------------------------------------------------- Internal

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (watched[from]) {
            sent[from][to] += value;
            if (!_isRecipient[from][to]) {
                _isRecipient[from][to] = true;
                _recipients[from].push(to);
            }
        }
        if (watched[to]) received[to][from] += value;
    }

    function _redeemValue(uint256 shares) internal view returns (uint256) {
        return shares.mulDiv(_totalAssets + 1, totalSupply() + VIRTUAL_SHARES);
    }

    function _exit(uint256 assets, uint256 shares, address receiver, address onBehalf) internal {
        require(!navBroken, "MockVaultV2: adapter realAssets reverted");
        require(!exitsBlocked, "MockVaultV2: exits gated");
        uint256 fromIdle = assets < freedIdle ? assets : freedIdle;
        freedIdle -= fromIdle;
        uint256 rest = assets - fromIdle;
        require(rest <= liquidity, "MockVaultV2: illiquid");
        if (liquidity != type(uint256).max) liquidity -= rest;
        if (msg.sender != onBehalf) _spendAllowance(onBehalf, msg.sender, shares);
        _burn(onBehalf, shares);
        _totalAssets -= assets;
        require(IERC20(asset).transfer(receiver, assets), "MockVaultV2: send");
    }
}

/// @notice Test-only Morpho market adapter: just the curator-timelock views `allowVault` reads. Starts in the
///         Gauntlet liquidity adapter's shape (`burnShares` timelocked 3 days).
contract MockAdapterV2 {
    mapping(bytes4 selector => uint256) public timelock;
    mapping(bytes4 selector => bool) public abdicated;

    constructor() {
        timelock[bytes4(keccak256("burnShares(bytes32)"))] = 3 days;
    }

    function mockSetTimelock(bytes4 selector, uint256 duration) external {
        timelock[selector] = duration;
    }

    function mockSetAbdicated(bytes4 selector, bool value) external {
        abdicated[selector] = value;
    }
}
