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
/// @dev Fee model: deposits are free; withdrawals charge `feeBps` (2%) to the
///      treasury. Collecting the fee here (rather than on a separate "cash out"
///      endpoint) means a user cannot escape it by exporting their wallet and
///      moving funds directly — the only way out of the vault is withdraw().
///      Early withdrawal is always permitted; `unlockAt` is advisory metadata
///      surfaced in the UI, never enforced.
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
        _bal[msg.sender][goalId] += amount; // effects
        usdc.safeTransferFrom(msg.sender, address(this), amount); // interaction
        emit GoalDeposited(msg.sender, goalId, amount);
    }

    // --- Withdrawals (2% fee) ------------------------------------------------

    /// @inheritdoc IMoolaHubGoalVault
    function withdraw(bytes32 goalId, uint256 grossAmount) external nonReentrant {
        uint256 b = _bal[msg.sender][goalId];
        if (grossAmount == 0) revert ZeroAmount();
        if (grossAmount > b) revert Insufficient();

        _bal[msg.sender][goalId] = b - grossAmount; // effects

        uint256 fee = (grossAmount * feeBps) / BPS;
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

    function quoteWithdraw(uint256 grossAmount) external view returns (uint256 net, uint256 fee) {
        fee = (grossAmount * feeBps) / BPS;
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
