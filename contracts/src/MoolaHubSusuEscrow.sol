// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    /// @dev Hard cap on roster size. Bounding members prevents the stall-recovery
    ///      loops in cancelStalled() (_accrueRefunds + _flagDelinquents) from
    ///      exceeding block gas limits, which would permanently lock contributions.
    uint256 public constant MAX_MEMBERS = 20;

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
    /// @dev Collateral withheld from a recipient's OWN payout, equal to the
    ///      value of their still-unpaid future rounds (see `_contribute`).
    ///      Always an exact multiple of `contributionAmount`. It funds their
    ///      own future obligations from the inside (no fresh transferFrom
    ///      needed) and is forfeited to the members it would otherwise strand
    ///      if they default (see `_accrueRefunds`). This is what makes early
    ///      payouts safe: nobody can take the full pot and walk away, because
    ///      the pot itself never contained more than their own contributions.
    mapping(address => uint256) public heldReserve;

    error NotMember();
    error NotActive();
    error AlreadyContributed();
    error NotGuardian();
    error NotStalled();
    error NothingToRefund();
    error BadConfig();
    error CirclePaused();

    /// @dev Lock the implementation so only clones (via initialize) are usable.
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.usdc == address(0) || p.treasury == address(0)) revert BadConfig();
        if (p.members.length < 2) revert BadConfig();
        if (p.members.length > MAX_MEMBERS) revert BadConfig();
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

    /// @notice Contribute the round amount. The member must have approved this
    ///         escrow for at least `contributionAmount` USDC. (No EIP-2612 permit
    ///         path: ERC-4337 smart accounts can't produce a valid permit
    ///         signature, so approve + contribute is the only flow.)
    function contribute() external nonReentrant {
        _contribute();
    }

    /// @dev Strict checks-effects-interactions: ALL state (including settlement's
    ///      round advance / completion) is written before ANY token transfer. The
    ///      member's pull happens first so the pot is funded before the payout.
    ///
    ///      Reserve accounting (the fix for the early-recipient default/theft
    ///      vector): a recipient's payout withholds the value of THEIR OWN
    ///      still-unpaid future rounds (`heldReserve`). That withheld money
    ///      never leaves the contract, so it can satisfy their future round
    ///      obligations without a fresh transferFrom (`fromReserve` below), and
    ///      it is forfeited to the members it would otherwise strand if they
    ///      default instead (see `_accrueRefunds`). Net effect for an honest
    ///      member across the full circle is unchanged; a dishonest one can no
    ///      longer profit by taking a payout and then refusing to contribute.
    function _contribute() private {
        if (status != Status.Active || paused) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        uint256 round = currentRound;
        if (hasContributed[round][msg.sender]) revert AlreadyContributed();

        // --- Effects ---
        hasContributed[round][msg.sender] = true;
        uint256 filled = roundContributions[round] + 1;
        roundContributions[round] = filled;
        emit Contributed(msg.sender, round, contributionAmount);

        // If this member already has this round's due sitting in their own
        // reserve (withheld from an earlier payout), draw from it instead of
        // pulling a fresh transfer — the funds are already inside the
        // contract. `heldReserve` is always an exact multiple of
        // `contributionAmount`, so this is all-or-nothing per round.
        uint256 reserve = heldReserve[msg.sender];
        bool fromReserve = reserve >= contributionAmount;
        if (fromReserve) {
            heldReserve[msg.sender] = reserve - contributionAmount;
            emit ReserveDrawn(msg.sender, round, contributionAmount);
        }

        bool settle = filled == totalRounds;
        address recipient = address(0);
        uint256 payout = 0;
        uint256 fee = 0;
        uint256 reserved = 0;
        if (settle) {
            recipient = _members[round - 1]; // positional, non-discretionary
            uint256 pot = contributionAmount * totalRounds;
            fee = (pot * feeBps) / BPS;
            // Withhold the recipient's own remaining contribution obligations
            // from their payout rather than paying the full pot. MAX_MEMBERS
            // and MAX_FEE_BPS bound `reserved` well under `pot - fee`, so this
            // subtraction cannot underflow (Solidity 0.8 would revert if it
            // somehow did, never silently wrap).
            reserved = contributionAmount * (totalRounds - round);
            payout = pot - fee - reserved;
            if (reserved > 0) heldReserve[recipient] += reserved;
            if (round == totalRounds) {
                status = Status.Completed;
            } else {
                currentRound = round + 1;
                roundDeadline = uint64(block.timestamp) + roundDuration;
            }
        }

        // --- Interactions (CEI): pull this contribution, then settle payouts ---
        if (!fromReserve) {
            usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);
        }
        if (settle) {
            if (fee > 0) usdc.safeTransfer(treasury, fee);
            if (payout > 0) usdc.safeTransfer(recipient, payout); // USDC has no transfer hook
            emit RoundSettled(round, recipient, payout, fee);
            if (reserved > 0) emit ReserveWithheld(recipient, reserved);
            if (status == Status.Completed) emit CircleCompleted(totalRounds);
        }
    }

    // --- Delinquency / cancellation -----------------------------------------

    /// @notice Flag members who missed the current round once it is past
    ///         deadline + grace, without cancelling. Permissionless.
    function flagDelinquents() external nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (!_pastGrace() || roundContributions[currentRound] == totalRounds) revert NotStalled();
        _flagDelinquents(currentRound);
    }

    /// @notice Cancel a stalled circle so contributors can reclaim the current
    ///         round's contributions. Permissionless once the round is past
    ///         deadline + grace with missing contributions. The guardian has no
    ///         special cancellation power — use pause() to halt contributions,
    ///         then any member can call unpause() to resume.
    ///
    /// @dev Cancellation is explicitly blocked while the circle is paused.
    ///      This prevents a guardian from manufacturing a stall (pause →
    ///      deadline expires → cancel) to strand later members' principal.
    ///      Members can always call unpause() to nullify an abusive pause before
    ///      the round deadline passes.
    function cancelStalled() external nonReentrant {
        if (status != Status.Active) revert NotActive();
        if (paused) revert CirclePaused();
        bool stalled = _pastGrace() && roundContributions[currentRound] < totalRounds;
        if (!stalled) revert NotStalled();

        // Effects before the external (reputation) interaction — strict CEI.
        status = Status.Cancelled;
        _accrueRefunds(currentRound);
        emit CircleCancelled(currentRound, msg.sender);
        _flagDelinquents(currentRound);
    }

    function _pastGrace() private view returns (bool) {
        // Scheduling only; validator drift is negligible vs the round duration.
        // slither-disable-next-line timestamp
        return block.timestamp > uint256(roundDeadline) + gracePeriod;
    }

    function _flagDelinquents(uint256 round) private {
        if (roundFlagged[round]) return;
        roundFlagged[round] = true;
        if (address(reputation) == address(0)) {
            emit DelinquentsFlagged(round, 0);
            return;
        }
        // Collect missed members, then report in ONE batched call (no external
        // call inside the loop). try/guarded so a misbehaving registry can never
        // block cancellation/refunds.
        uint256 n = _members.length;
        address[] memory missed = new address[](n);
        uint256 count = 0;
        for (uint256 i; i < n; ++i) {
            address m = _members[i];
            if (!hasContributed[round][m]) {
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

    /// @dev On cancellation, every contribution to the unsettled current round is
    ///      refundable to its contributor. Already-settled rounds stand.
    ///
    ///      Reserve settlement: a past recipient's `heldReserve` was funded out
    ///      of THEIR OWN earlier payout to cover rounds that will now never
    ///      happen. If they kept up with this round, that reserve is simply
    ///      theirs back (no default occurred — the circle just ended early).
    ///      If they missed this round (the delinquent whose default likely
    ///      caused the stall), their reserve is forfeited and split across the
    ///      round's honest contributors instead of sitting unclaimed — this is
    ///      what makes earlier contributors whole rather than only refunding
    ///      the unsettled round.
    function _accrueRefunds(uint256 round) private {
        uint256 n = _members.length;
        uint256 forfeited = 0;
        uint256 honestCount = 0;
        for (uint256 i; i < n; ++i) {
            address m = _members[i];
            bool contributed = hasContributed[round][m];
            if (contributed) {
                refundableOf[m] += contributionAmount;
                unchecked {
                    ++honestCount;
                }
            }
            uint256 reserve = heldReserve[m];
            if (reserve > 0) {
                heldReserve[m] = 0;
                if (contributed) {
                    refundableOf[m] += reserve;
                } else {
                    forfeited += reserve;
                    emit ReserveForfeited(m, reserve);
                }
            }
        }
        if (forfeited > 0) {
            if (honestCount > 0) {
                uint256 share = forfeited / honestCount;
                uint256 distributed = 0;
                for (uint256 i; i < n; ++i) {
                    address m = _members[i];
                    if (hasContributed[round][m]) {
                        refundableOf[m] += share;
                        distributed += share;
                    }
                }
                // Integer-division dust (can't split evenly) — route to the
                // treasury via the same pull-based refund path rather than
                // stranding a few wei/units in the contract forever.
                uint256 dust = forfeited - distributed;
                if (dust > 0) refundableOf[treasury] += dust;
            } else {
                // No one contributed this round to redistribute to (e.g. a
                // pathological all-delinquent round) — the treasury absorbs it
                // rather than leaving it permanently unclaimable.
                refundableOf[treasury] += forfeited;
            }
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

    /// @notice Any member may resume a paused circle. This nullifies an abusive
    ///         guardian pause that would otherwise manufacture a stall, since
    ///         `cancelStalled()` is blocked while `paused == true`. Members
    ///         acting collectively can always restore contribution ability.
    function unpause() external {
        if (status != Status.Active) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        paused = false;
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
