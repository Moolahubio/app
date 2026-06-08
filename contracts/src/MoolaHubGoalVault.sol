// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMoolaHubGoalVault} from "./interfaces/IMoolaHubGoalVault.sol";

/// @title MoolaHubGoalVault
/// @notice Singleton USDC vault holding savings per (owner, goalId). Strictly
///         non-custodial: only the owning account can move its own balance —
///         there is NO admin path to user funds anywhere in this contract.
///
/// @dev Fee model: deposits are free; withdrawals charge a fee to the treasury.
///      The fee applied to any withdrawal is the LOWER of:
///        (a) the global `feeBps` at the time of withdrawal, and
///        (b) the `feeBps` that was in effect when the user first deposited into
///            that (owner, goalId) slot (snapshotted in `_lockedFeeBps`).
///      This means fee increases can never retroactively raise costs on already-
///      deposited principal — the owner can only make things cheaper for existing
///      depositors. New deposits into an empty slot pick up the current global fee.
///
///      The owner (multisig) can only tune feeBps (capped) and the treasury
///      address; it can never withdraw a user's balance.
contract MoolaHubGoalVault is IMoolaHubGoalVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap; MoolaHub uses 200 (2%)
    uint256 private constant BPS = 10_000;

    IERC20 public immutable usdc;
    uint16 public feeBps;
    address public treasury;

    mapping(address => mapping(bytes32 => uint256)) private _bal; // owner => goalId => amount
    mapping(address => mapping(bytes32 => uint64)) public unlockAt; // advisory only

    /// @dev The fee rate locked at the time of first deposit into each (owner, goalId)
    ///      slot. Reset to 0 when the balance returns to zero, so the next deposit
    ///      always picks up the then-current global fee.
    mapping(address => mapping(bytes32 => uint16)) private _lockedFeeBps;

    error ZeroAmount();
    error Insufficient();
    error ZeroAddress();
    error FeeTooHigh();

    constructor(address usdc_, address treasury_, uint16 feeBps_, address owner_) Ownable(owner_) {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        usdc = IERC20(usdc_);
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // --- Deposits (free) -----------------------------------------------------

    /// @notice Deposit into a goal. The caller must have approved this vault for
    ///         `amount` USDC. (No EIP-2612 permit path — see the contribute notes
    ///         in the circle contracts; smart accounts can't sign a permit.)
    function deposit(bytes32 goalId, uint256 amount) external nonReentrant {
        _deposit(goalId, amount);
    }

    function _deposit(bytes32 goalId, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        // Snapshot the current fee for this slot on the first deposit (or after
        // the balance was fully withdrawn). Subsequent top-ups keep the existing
        // locked rate so the user's position is never retroactively worsened.
        if (_bal[msg.sender][goalId] == 0) {
            _lockedFeeBps[msg.sender][goalId] = feeBps;
        }
        _bal[msg.sender][goalId] += amount; // effects
        usdc.safeTransferFrom(msg.sender, address(this), amount); // interaction
        emit GoalDeposited(msg.sender, goalId, amount);
    }

    // --- Withdrawals ---------------------------------------------------------

    /// @inheritdoc IMoolaHubGoalVault
    function withdraw(bytes32 goalId, uint256 grossAmount) external nonReentrant {
        uint256 b = _bal[msg.sender][goalId];
        if (grossAmount == 0) revert ZeroAmount();
        if (grossAmount > b) revert Insufficient();

        _bal[msg.sender][goalId] = b - grossAmount; // effects

        // Use the lower of the locked rate and the current global rate so that
        // (a) fee increases never hurt existing depositors, and
        // (b) fee decreases always benefit them immediately.
        uint16 locked = _lockedFeeBps[msg.sender][goalId];
        uint16 effectiveFee = locked < feeBps ? locked : feeBps;

        // Clear the locked rate once the slot is emptied so the next deposit
        // always picks up the then-current fee.
        if (_bal[msg.sender][goalId] == 0) {
            _lockedFeeBps[msg.sender][goalId] = 0;
        }

        uint256 fee = (grossAmount * effectiveFee) / BPS;
        uint256 net = grossAmount - fee;
        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(msg.sender, net); // only ever to the owner of the funds
        emit GoalWithdrawn(msg.sender, goalId, grossAmount, fee);
    }

    function setUnlock(bytes32 goalId, uint64 unlockAt_) external {
        unlockAt[msg.sender][goalId] = unlockAt_;
        emit UnlockSet(msg.sender, goalId, unlockAt_);
    }

    // --- Views ---------------------------------------------------------------

    function balanceOf(address owner_, bytes32 goalId) external view returns (uint256) {
        return _bal[owner_][goalId];
    }

    /// @notice The effective withdrawal fee rate for a given (owner, goalId) slot.
    ///         Returns the lower of the locked rate and the current global rate.
    ///         Returns 0 for empty slots (no balance, so no locked rate applies yet).
    ///         Note: also returns 0 when the slot was funded while feeBps was 0.
    function lockedFeeBpsOf(address owner_, bytes32 goalId) external view returns (uint16) {
        if (_bal[owner_][goalId] == 0) return 0; // empty slot
        uint16 locked = _lockedFeeBps[owner_][goalId];
        return locked < feeBps ? locked : feeBps;
    }

    function quoteWithdraw(uint256 grossAmount) external view returns (uint256 net, uint256 fee) {
        fee = (grossAmount * feeBps) / BPS;
        net = grossAmount - fee;
    }

    /// @notice Quote a withdrawal using the effective fee for a specific (owner, goalId) slot.
    ///         Uses balance presence to distinguish an empty slot from a deposit made at fee=0.
    ///         Mirrors withdraw() exactly: effectiveFee = min(lockedFee, currentFee).
    function quoteWithdrawFor(address owner_, bytes32 goalId, uint256 grossAmount)
        external
        view
        returns (uint256 net, uint256 fee)
    {
        uint16 effectiveFee;
        if (_bal[owner_][goalId] == 0) {
            // Empty slot — use global fee as indicative reference for UI display.
            effectiveFee = feeBps;
        } else {
            uint16 locked = _lockedFeeBps[owner_][goalId];
            effectiveFee = locked < feeBps ? locked : feeBps;
        }
        fee = (grossAmount * effectiveFee) / BPS;
        net = grossAmount - fee;
    }

    // --- Admin (multisig) — fee/treasury only, never user funds --------------

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
}
