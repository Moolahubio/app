// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMoolaHubSusuEscrow} from "./interfaces/IMoolaHubSusuEscrow.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";

/// @title MoolaHubSusuEscrow
/// @notice Trustless rotating-savings (Susu/ROSCA) escrow. Deployed once as an
///         immutable implementation and used as EIP-1167 clones (one per circle).
///
/// @dev Non-discretionary design (mirrors the non-custodial vault reference):
///      funds entering the escrow can leave ONLY as
///        (a) a scheduled payout to the round's positional recipient,
///        (b) the platform fee to the immutable treasury, or
///        (c) a refund to the original contributor (cancellation path).
///      No owner/admin/guardian can choose or redirect a recipient. All economic
///      parameters are fixed at initialize() and cannot change afterward.
///
///      UNAUDITED. Must pass invariant/fuzz tests + external audit before mainnet.
contract MoolaHubSusuEscrow is IMoolaHubSusuEscrow, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 500; // hard cap 5%; MoolaHub uses 200 (2%)
    uint256 private constant BPS = 10_000;

    IERC20 public usdc;
    uint256 public contributionAmount;
    uint16 public feeBps;
    address public treasury;
    uint64 public roundDuration;
    uint64 public gracePeriod;
    address public guardian;
    IMoolaHubReputation public reputation;
    bytes32 public circleId;

    address[] private _members;
    mapping(address => bool) public isMember;

    Status public status;
    uint256 public currentRound; // 1-indexed
    uint256 public totalRounds;
    uint64 public roundDeadline;
    bool public paused;

    mapping(uint256 => mapping(address => bool)) public hasContributed;
    mapping(uint256 => uint256) public roundContributions; // count per round
    mapping(uint256 => bool) public roundFlagged; // delinquency reported for round
    mapping(address => uint256) public refundableOf;

    error NotMember();
    error NotActive();
    error AlreadyContributed();
    error NotGuardian();
    error NotStalled();
    error NothingToRefund();
    error BadConfig();

    /// @dev Lock the implementation so only clones (via initialize) are usable.
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.usdc == address(0) || p.treasury == address(0)) revert BadConfig();
        if (p.members.length < 2) revert BadConfig();
        if (p.contributionAmount == 0) revert BadConfig();
        if (p.feeBps > MAX_FEE_BPS) revert BadConfig();
        if (p.roundDuration == 0) revert BadConfig();

        usdc = IERC20(p.usdc);
        contributionAmount = p.contributionAmount;
        feeBps = p.feeBps;
        treasury = p.treasury;
        roundDuration = p.roundDuration;
        gracePeriod = p.gracePeriod;
        guardian = p.guardian;
        reputation = IMoolaHubReputation(p.reputation);
        circleId = p.circleId;

        uint256 n = p.members.length;
        for (uint256 i; i < n; ++i) {
            address m = p.members[i];
            if (m == address(0) || isMember[m]) revert BadConfig(); // no zero / no dupes
            isMember[m] = true;
            _members.push(m);
        }

        status = Status.Active;
        currentRound = 1;
        totalRounds = n;
        roundDeadline = uint64(block.timestamp) + p.roundDuration;
    }

    // --- Contributions -------------------------------------------------------

    function contribute() external nonReentrant {
        _contribute();
    }

    /// @notice One-signature contribution using EIP-2612 permit (USDC supports it).
    function contributeWithPermit(uint256 deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        // Permit may be front-run/already-consumed; ignore its revert and let the
        // subsequent safeTransferFrom enforce the allowance requirement.
        try IERC20Permit(address(usdc)).permit(msg.sender, address(this), contributionAmount, deadline, v, r, s)
        {} catch {}
        _contribute();
    }

    function _contribute() private {
        if (status != Status.Active || paused) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        uint256 round = currentRound;
        if (hasContributed[round][msg.sender]) revert AlreadyContributed();

        // Effects before interaction (CEI).
        hasContributed[round][msg.sender] = true;
        roundContributions[round] += 1;

        usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);
        emit Contributed(msg.sender, round, contributionAmount);

        if (roundContributions[round] == totalRounds) {
            _settleRound(round);
        }
    }

    function _settleRound(uint256 round) private {
        address recipient = _members[round - 1]; // positional, non-discretionary
        uint256 pot = contributionAmount * totalRounds;
        uint256 fee = (pot * feeBps) / BPS;
        uint256 payout = pot - fee;

        // Advance state before any transfer (CEI).
        if (round == totalRounds) {
            status = Status.Completed;
        } else {
            currentRound = round + 1;
            roundDeadline = uint64(block.timestamp) + roundDuration;
        }

        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(recipient, payout); // USDC has no transfer hook -> safe push
        emit RoundSettled(round, recipient, payout, fee);
        if (status == Status.Completed) emit CircleCompleted(totalRounds);
    }

    // --- Delinquency / cancellation -----------------------------------------

    /// @notice Flag members who missed the current round once it is past
    ///         deadline + grace, without cancelling. Permissionless.
    function flagDelinquents() external {
        if (status != Status.Active) revert NotActive();
        if (!_pastGrace() || roundContributions[currentRound] == totalRounds) revert NotStalled();
        _flagDelinquents(currentRound);
    }

    /// @notice Cancel a stalled circle so contributors can reclaim the current
    ///         round's contributions. Permissionless once past deadline + grace;
    ///         the guardian may also cancel in an emergency.
    function cancelStalled() external {
        if (status != Status.Active) revert NotActive();
        bool stalled = _pastGrace() && roundContributions[currentRound] < totalRounds;
        if (!stalled && msg.sender != guardian) revert NotStalled();

        if (stalled) _flagDelinquents(currentRound);
        status = Status.Cancelled;
        _accrueRefunds(currentRound);
        emit CircleCancelled(currentRound, msg.sender);
    }

    function _pastGrace() private view returns (bool) {
        return block.timestamp > uint256(roundDeadline) + gracePeriod;
    }

    function _flagDelinquents(uint256 round) private {
        if (roundFlagged[round]) return;
        roundFlagged[round] = true;
        if (address(reputation) == address(0)) {
            emit DelinquentsFlagged(round, 0);
            return;
        }
        uint256 count;
        uint256 n = _members.length;
        for (uint256 i; i < n; ++i) {
            address m = _members[i];
            if (!hasContributed[round][m]) {
                reputation.recordStrike(m, circleId, round, uint8(IMoolaHubReputation.Reason.MISSED_CONTRIBUTION));
                unchecked {
                    ++count;
                }
            }
        }
        emit DelinquentsFlagged(round, count);
    }

    /// @dev On cancellation, every contribution to the unsettled current round is
    ///      refundable to its contributor. Already-settled rounds stand.
    function _accrueRefunds(uint256 round) private {
        uint256 n = _members.length;
        for (uint256 i; i < n; ++i) {
            address m = _members[i];
            if (hasContributed[round][m]) refundableOf[m] += contributionAmount;
        }
    }

    function claimRefund() external nonReentrant {
        uint256 amount = refundableOf[msg.sender];
        if (amount == 0) revert NothingToRefund();
        refundableOf[msg.sender] = 0; // effects
        usdc.safeTransfer(msg.sender, amount); // interaction
        emit Refunded(msg.sender, amount);
    }

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true; // blocks new contributions; cannot move funds
    }

    // --- Views ---------------------------------------------------------------

    function getMembers() external view returns (address[] memory) {
        return _members;
    }

    function potAmount() external view returns (uint256) {
        return contributionAmount * totalRounds;
    }

    function currentRecipient() external view returns (address) {
        return status == Status.Active ? _members[currentRound - 1] : address(0);
    }
}
