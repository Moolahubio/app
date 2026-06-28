// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IYieldAdapter} from "./adapters/IYieldAdapter.sol";

/// @title MoolaHubGoalVaultV2
/// @notice Yield-bearing singleton savings vault, keyed (owner, goalId). Idle USDC
///         is routed through a swappable `IYieldAdapter`, so balances earn yield;
///         accounting is share-based (ERC-4626 style) and `balanceOf` returns
///         principal + accrued yield — or LESS after a lender loss. Yield-bearing
///         is NOT principal-guaranteed: a depositor redeems the current value of
///         their shares (run a goal on the PassthroughAdapter for no market risk).
///
/// @dev Strictly non-custodial: only the owning account can move its own balance.
///      The owner (multisig) may tune fee/treasury and swap the adapter, but the
///      adapter swap moves funds only through the vault's own redeem path and the
///      owner has NO function to withdraw a user's principal.
///
///      Preserved from V1: the locked-fee feature — a withdrawal's fee is the
///      LOWER of the rate locked at first deposit into the slot and the current
///      global rate, so fee hikes never retroactively cost existing depositors.
///      Fee = effectiveFee% of the gross USDC withdrawn (principal + its yield).
///
///      First-depositor inflation/donation attack is mitigated with virtual shares
///      (offset 1e6, the OZ ERC-4626 pattern): a griefer would have to donate
///      ~1e6x a victim's deposit to round it down. Rounding always favors the
///      protocol (mint down, burn up), so `Σ balanceOf ≤ totalManagedAssets`.
contract MoolaHubGoalVaultV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap; MoolaHub uses 200 (2%)
    uint256 private constant BPS = 10_000;
    /// @dev Virtual-share offset (1e6) backing the inflation defense. Also the
    ///      scale of shares vs assets when the vault is empty (shares ≈ assets·1e6).
    uint256 private constant VIRTUAL_SHARES = 1e6;

    IERC20 public immutable usdc;
    uint16 public feeBps;
    address public treasury;
    IYieldAdapter public adapter;

    mapping(address => mapping(bytes32 => uint256)) private _shares; // owner => goalId => shares
    uint256 public totalShares;
    /// @notice Contributed cost basis per slot (assets). yield = balanceOf − principalOf.
    mapping(address => mapping(bytes32 => uint256)) public principalOf;
    /// @dev Fee rate locked at first deposit into a slot; cleared when it empties.
    mapping(address => mapping(bytes32 => uint16)) private _lockedFeeBps;
    mapping(address => mapping(bytes32 => uint64)) public unlockAt; // advisory only

    event GoalDeposited(address indexed owner, bytes32 indexed goalId, uint256 amount);
    event GoalWithdrawn(address indexed owner, bytes32 indexed goalId, uint256 grossAmount, uint256 fee);
    event UnlockSet(address indexed owner, bytes32 indexed goalId, uint64 unlockAt);
    event FeeBpsSet(uint16 feeBps);
    event TreasurySet(address indexed treasury);
    event AdapterSet(address indexed adapter);

    error ZeroAmount();
    error Insufficient();
    error ZeroAddress();
    error FeeTooHigh();
    error NoAdapter();
    error AssetMismatch();
    error AdapterNotLiquid();

    constructor(address usdc_, address treasury_, uint16 feeBps_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        usdc = IERC20(usdc_);
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // --- Share math (OZ ERC-4626 virtual-shares pattern) ---------------------

    /// @notice Total USDC backing all shares: idle in the vault + deployed in the adapter.
    function totalManagedAssets() public view returns (uint256) {
        uint256 deployed = address(adapter) == address(0) ? 0 : adapter.totalAssets();
        return usdc.balanceOf(address(this)) + deployed;
    }

    function _toShares(uint256 assets, Math.Rounding r) internal view returns (uint256) {
        return assets.mulDiv(totalShares + VIRTUAL_SHARES, totalManagedAssets() + 1, r);
    }

    function _toAssets(uint256 shares, Math.Rounding r) internal view returns (uint256) {
        return shares.mulDiv(totalManagedAssets() + 1, totalShares + VIRTUAL_SHARES, r);
    }

    // --- Deposits (free) -----------------------------------------------------

    /// @notice Deposit into a goal. Caller must have approved this vault for `amount`.
    function deposit(bytes32 goalId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(adapter) == address(0)) revert NoAdapter();

        // Price uses pre-deposit state (assets not yet pulled in). Mint rounds down.
        uint256 sh = _toShares(amount, Math.Rounding.Floor);
        if (sh == 0) revert ZeroAmount(); // dust below one share

        if (_shares[msg.sender][goalId] == 0) {
            _lockedFeeBps[msg.sender][goalId] = feeBps; // snapshot on first deposit into the slot
        }
        _shares[msg.sender][goalId] += sh; // effects
        totalShares += sh;
        principalOf[msg.sender][goalId] += amount;
        emit GoalDeposited(msg.sender, goalId, amount);

        usdc.safeTransferFrom(msg.sender, address(this), amount); // interactions (CEI)
        usdc.forceApprove(address(adapter), amount);
        adapter.deposit(amount);
    }

    // --- Withdrawals (fee) ---------------------------------------------------

    /// @notice Withdraw `grossAmount` USDC from a goal; caller receives gross minus
    ///         the effective fee. `grossAmount` may be up to the slot's current
    ///         redeemable value (`balanceOf`). Passing exactly `balanceOf` exits the
    ///         slot fully (no dust shares left behind).
    function withdraw(bytes32 goalId, uint256 grossAmount) external nonReentrant {
        if (grossAmount == 0) revert ZeroAmount();
        uint256 slotShares = _shares[msg.sender][goalId];
        uint256 redeemable = _toAssets(slotShares, Math.Rounding.Floor);
        if (grossAmount > redeemable) revert Insufficient();

        uint256 slotPrincipal = principalOf[msg.sender][goalId];
        uint256 burn;
        uint256 principalReduce;
        if (grossAmount == redeemable) {
            burn = slotShares; // full exit — leave no dust
            principalReduce = slotPrincipal;
        } else {
            burn = _toShares(grossAmount, Math.Rounding.Ceil); // burn up (protocol-favor)
            if (burn > slotShares) burn = slotShares;
            principalReduce = slotShares == 0 ? 0 : slotPrincipal.mulDiv(burn, slotShares, Math.Rounding.Floor);
        }

        uint16 locked = _lockedFeeBps[msg.sender][goalId];
        uint16 effectiveFee = locked < feeBps ? locked : feeBps;

        // Effects.
        _shares[msg.sender][goalId] = slotShares - burn;
        totalShares -= burn;
        principalOf[msg.sender][goalId] = slotPrincipal - principalReduce;
        if (_shares[msg.sender][goalId] == 0) {
            _lockedFeeBps[msg.sender][goalId] = 0;
        }

        uint256 fee = (grossAmount * effectiveFee) / BPS;
        uint256 net = grossAmount - fee;
        emit GoalWithdrawn(msg.sender, goalId, grossAmount, fee);

        // Interactions (CEI): cover the payout from idle first, then the adapter.
        uint256 idle = usdc.balanceOf(address(this));
        if (grossAmount > idle) adapter.withdraw(grossAmount - idle, address(this));
        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(msg.sender, net); // only ever to the owner of the funds
    }

    function setUnlock(bytes32 goalId, uint64 unlockAt_) external {
        unlockAt[msg.sender][goalId] = unlockAt_;
        emit UnlockSet(msg.sender, goalId, unlockAt_);
    }

    // --- Views ---------------------------------------------------------------

    /// @notice Current redeemable value of a slot (principal + accrued yield, or
    ///         less after a loss). Rounds down (protocol favor).
    function balanceOf(address owner_, bytes32 goalId) external view returns (uint256) {
        return _toAssets(_shares[owner_][goalId], Math.Rounding.Floor);
    }

    function sharesOf(address owner_, bytes32 goalId) external view returns (uint256) {
        return _shares[owner_][goalId];
    }

    function lockedFeeBpsOf(address owner_, bytes32 goalId) external view returns (uint16) {
        if (_shares[owner_][goalId] == 0) return 0;
        uint16 locked = _lockedFeeBps[owner_][goalId];
        return locked < feeBps ? locked : feeBps;
    }

    function quoteWithdrawFor(address owner_, bytes32 goalId, uint256 grossAmount)
        external
        view
        returns (uint256 net, uint256 fee)
    {
        uint16 effectiveFee;
        if (_shares[owner_][goalId] == 0) {
            effectiveFee = feeBps;
        } else {
            uint16 locked = _lockedFeeBps[owner_][goalId];
            effectiveFee = locked < feeBps ? locked : feeBps;
        }
        fee = (grossAmount * effectiveFee) / BPS;
        net = grossAmount - fee;
    }

    // --- Admin (multisig) — fee/treasury/adapter only, never user funds ------

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Set or swap the yield adapter. Migrates all backing USDC from the
    ///         old adapter into the new one through the vault's own redeem path
    ///         (never an admin sweep); shares are untouched, so balances are
    ///         preserved. The new adapter's `asset()` must be USDC. Reverts if the
    ///         old adapter can't be fully drained, so a frozen lender blocks the
    ///         swap rather than silently corrupting accounting.
    function setAdapter(IYieldAdapter newAdapter) external onlyOwner nonReentrant {
        _setAdapter(newAdapter);
    }

    /// @notice Circuit breaker (plan §5.3/§5.8E): move all funds back to a no-yield
    ///         PassthroughAdapter. Same mechanics as `setAdapter`.
    function emergencyExitToPassthrough(IYieldAdapter passthrough) external onlyOwner nonReentrant {
        _setAdapter(passthrough);
    }

    function _setAdapter(IYieldAdapter newAdapter) private {
        if (address(newAdapter) == address(0)) revert ZeroAddress();
        if (newAdapter.asset() != address(usdc)) revert AssetMismatch();

        IYieldAdapter old = adapter;
        adapter = newAdapter;

        if (address(old) != address(0)) {
            uint256 amt = old.maxWithdraw();
            if (amt > 0) old.withdraw(amt, address(this));
            if (old.totalAssets() > 1) revert AdapterNotLiquid(); // 1-wei dust tolerance
        }
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) {
            uint256 newBefore = newAdapter.totalAssets();
            usdc.forceApprove(address(newAdapter), bal);
            newAdapter.deposit(bal);
            // Defense-in-depth: reject a migration that credits materially less
            // than was deposited (e.g. a donatable / pre-inflated ERC-4626), which
            // would realize a loss across all holders. A compliant internal-
            // accounting lender (Curvance cUSDC) credits ~1:1 and passes.
            if (newAdapter.totalAssets() + bal / 1e6 + 10 < newBefore + bal) {
                revert AdapterNotLiquid();
            }
        }
        emit AdapterSet(address(newAdapter));
    }
}
