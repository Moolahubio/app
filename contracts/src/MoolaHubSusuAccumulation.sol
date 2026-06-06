// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IMoolaHubSusuAccumulation} from "./interfaces/IMoolaHubSusuAccumulation.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";

/// @title MoolaHubSusuAccumulation
/// @notice Accumulation-mode Susu circle. Unlike rotation (one member takes the
///         pot each round), here every member simply saves on a shared schedule
///         and later withdraws their OWN accumulated balance. There is no
///         redistribution: a member can never receive another member's money.
///
/// @dev Design:
///      - Rounds are fixed time windows (`roundDuration` each, `totalRounds` of
///        them). A member may contribute once per open round window.
///      - Contributions accumulate into the member's own `savings` balance.
///      - Withdrawals: if `lockUntilMaturity`, allowed only at/after maturity (or
///        if the circle is cancelled); otherwise allowed anytime. A 2% fee goes
///        to the treasury on a normal withdrawal; cancellation withdrawals are
///        fee-free (the circle failed — return savings in full).
///      - Missing a round can be flagged to the reputation registry; enforcement
///        is decided off-chain. No admin can move user funds; the guardian can
///        only pause new contributions or cancel (which only unlocks withdrawals).
///
///      Deploy one instance per circle (constructor-configured, immutable).
///      Assumes a standard, non-fee-on-transfer, non-rebasing ERC-20 (USDC).
///      UNAUDITED reference — test + audit before mainnet.
contract MoolaHubSusuAccumulation is IMoolaHubSusuAccumulation, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap; MoolaHub uses 200 (2%)
    uint256 private constant BPS = 10_000;

    // Config — set once in initialize() (clone pattern: no immutables). Never
    // changes afterward, so it is effectively immutable per circle.
    IERC20 public usdc;
    uint256 public contributionAmount;
    uint16 public feeBps;
    address public treasury;
    uint64 public startTime;
    uint64 public roundDuration;
    uint64 public gracePeriod;
    uint256 public totalRounds;
    address public guardian;
    IMoolaHubReputation public reputation;
    bytes32 public circleId;
    bool public lockUntilMaturity;

    address[] private _members;
    mapping(address => bool) public isMember;

    Status public status;
    bool public paused;
    uint256 public totalSaved; // sum of all members' savings (excludes accidental sends)

    mapping(address => uint256) public savingsOf;
    mapping(uint256 => mapping(address => bool)) public contributed; // round => member => paid
    mapping(uint256 => bool) public roundFlagged;

    error NotMember();
    error NotActive();
    error AlreadyContributed();
    error NotInWindow();
    error NothingSaved();
    error Locked();
    error NotGuardian();
    error BadRound();
    error RoundNotClosed();
    error NoExcess();
    error BadConfig();

    /// @dev Lock the implementation so only clones (via initialize) are usable.
    constructor() {
        _disableInitializers();
    }

    function initialize(InitConfig calldata cfg, address[] calldata members_) external initializer {
        if (cfg.usdc == address(0) || cfg.treasury == address(0)) revert BadConfig();
        if (members_.length < 2) revert BadConfig();
        if (cfg.contributionAmount == 0) revert BadConfig();
        if (cfg.feeBps > MAX_FEE_BPS) revert BadConfig();
        if (cfg.roundDuration == 0 || cfg.totalRounds == 0) revert BadConfig();

        usdc = IERC20(cfg.usdc);
        contributionAmount = cfg.contributionAmount;
        feeBps = cfg.feeBps;
        treasury = cfg.treasury;
        startTime = uint64(block.timestamp);
        roundDuration = cfg.roundDuration;
        gracePeriod = cfg.gracePeriod;
        totalRounds = cfg.totalRounds;
        guardian = cfg.guardian;
        reputation = IMoolaHubReputation(cfg.reputation);
        circleId = cfg.circleId;
        lockUntilMaturity = cfg.lockUntilMaturity;

        for (uint256 i; i < members_.length; ++i) {
            address m = members_[i];
            if (m == address(0) || isMember[m]) revert BadConfig();
            isMember[m] = true;
            _members.push(m);
        }
        status = Status.Active;
    }

    // --- Contributions -------------------------------------------------------

    /// @notice Contribute the round amount. The member must have approved this
    ///         contract for at least `contributionAmount` USDC. (No EIP-2612
    ///         permit path: ERC-4337 smart accounts can't produce a valid permit
    ///         signature, so approve + contribute is the only flow.)
    function contribute() external nonReentrant {
        _contribute();
    }

    /// @dev Strict checks-effects-interactions: the token pull is the only external
    ///      call and it happens after all state writes.
    function _contribute() private {
        if (status != Status.Active || paused) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        uint256 round = currentRound();
        if (round < 1) revert NotInWindow(); // 0 means no open round (avoids strict == on a derived value)
        if (contributed[round][msg.sender]) revert AlreadyContributed();

        // Effects.
        contributed[round][msg.sender] = true;
        savingsOf[msg.sender] += contributionAmount;
        totalSaved += contributionAmount;
        emit Contributed(msg.sender, round, contributionAmount);

        // Interaction (CEI).
        usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);
    }

    // --- Withdrawals ---------------------------------------------------------

    /// @notice Withdraw your own accumulated savings. 2% fee normally; fee-free
    ///         if the circle was cancelled. Reverts while locked before maturity.
    function withdraw() external nonReentrant {
        bool cancelled = status == Status.Cancelled;
        if (!cancelled && lockUntilMaturity && !isMatured()) revert Locked();

        uint256 amount = savingsOf[msg.sender];
        if (amount == 0) revert NothingSaved();

        // Effects.
        savingsOf[msg.sender] = 0;
        totalSaved -= amount;

        uint256 fee = cancelled ? 0 : (amount * feeBps) / BPS;
        uint256 net = amount - fee;

        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(msg.sender, net); // only ever to the owner of the funds
        emit Withdrawn(msg.sender, amount, fee);
    }

    // --- Delinquency / admin -------------------------------------------------

    /// @notice Flag members who missed `round` once its window has closed
    ///         (deadline + grace). Permissionless. Idempotent per round.
    function flagRound(uint256 round) external nonReentrant {
        if (round < 1 || round > totalRounds) revert BadRound();
        // Round `round` covers [startTime + (round-1)*dur, startTime + round*dur).
        // slither-disable-next-line timestamp
        if (block.timestamp <= uint256(startTime) + round * roundDuration + gracePeriod) revert RoundNotClosed();
        if (roundFlagged[round]) return;
        roundFlagged[round] = true;

        if (address(reputation) == address(0)) {
            emit DelinquentsFlagged(round, 0);
            return;
        }
        // Collect missed members, then report in ONE batched call (no external
        // call inside the loop). The call is try/guarded so a misbehaving registry
        // can never block flagging.
        uint256 n = _members.length;
        address[] memory missed = new address[](n);
        uint256 count = 0;
        for (uint256 i; i < n; ++i) {
            address m = _members[i];
            if (!contributed[round][m]) {
                missed[i] = m;
                unchecked {
                    ++count;
                }
            }
        }
        if (count > 0) {
            try reputation.recordStrikeBatch(
                missed, circleId, round, uint8(IMoolaHubReputation.Reason.MISSED_CONTRIBUTION)
            ) {} catch {}
        }
        emit DelinquentsFlagged(round, count);
    }

    /// @notice Guardian emergency cancel: unlocks fee-free withdrawals of each
    ///         member's own savings. Cannot move funds to the guardian.
    function cancel() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (status != Status.Active) revert NotActive();
        status = Status.Cancelled;
        emit CircleCancelled(msg.sender);
    }

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true; // blocks new contributions only; never withdrawals
    }

    /// @notice Send only surplus USDC (accidental direct transfers, i.e. balance
    ///         beyond tracked savings) to the treasury. Never touches savings.
    function sweepExcess() external nonReentrant {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal <= totalSaved) revert NoExcess();
        uint256 excess = bal - totalSaved;
        usdc.safeTransfer(treasury, excess);
        emit ExcessSwept(excess);
    }

    // --- Views ---------------------------------------------------------------

    // NOTE: block.timestamp is used only for round/maturity scheduling. The
    // worst-case validator drift (a few seconds) is negligible against day-long
    // round windows, so these comparisons are safe and intentional. Slither's
    // `timestamp` detector is suppressed at each site for that reason.

    /// @return The currently open round (1..totalRounds), or 0 if before start or after the schedule.
    function currentRound() public view returns (uint256) {
        // slither-disable-next-line timestamp
        if (block.timestamp < startTime) return 0;
        uint256 r = (block.timestamp - startTime) / roundDuration + 1;
        // slither-disable-next-line timestamp
        if (r > totalRounds) return 0;
        return r;
    }

    function maturity() public view returns (uint256) {
        return uint256(startTime) + roundDuration * totalRounds;
    }

    function isMatured() public view returns (bool) {
        // slither-disable-next-line timestamp
        return block.timestamp >= maturity();
    }

    function canWithdraw(address member) external view returns (bool) {
        if (savingsOf[member] == 0) return false;
        if (status == Status.Cancelled) return true;
        // slither-disable-next-line timestamp
        return !lockUntilMaturity || isMatured();
    }

    function getMembers() external view returns (address[] memory) {
        return _members;
    }
}
