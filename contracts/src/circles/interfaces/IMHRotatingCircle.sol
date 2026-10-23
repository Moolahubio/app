// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMHCircle } from "./IMHCircle.sol";
import { CircleStatus, RotatingParams } from "../MHCircleTypes.sol";

/// @title IMHRotatingCircle
/// @notice Rotating (ROSCA) circle: idle USDC only, no yield (decision 12). Implemented by `MHRotatingCircle`.
///         Each round every member puts in `contribution`; round k's gross pot goes to slot k. Paying slot k early
///         lends it `(n−k)·c`, so slot k must hold security `S_k = ceil(σ_k·(n−k)·c)`: collateral first, then a
///         holdback from its payout. Later contributions are drawn from security above the requirement, so the
///         wallet owes `c − draw` (spec §4.4).
/// @dev The factory depends only on `initialize`; the implementation address is a factory immutable.
interface IMHRotatingCircle is IMHCircle {
    // ---------------------------------------------------------------- Types

    /// @notice Why a circle was cancelled.
    /// @dev Unjoined: not every member joined before `joinDeadline`. Stalled: a round stayed short past
    ///      grace + cure. Guardian: the Guardian cancelled before the first payout.
    enum CancelReason {
        Unjoined,
        Stalled,
        Guardian
    }

    /// @notice Per-member state. All amounts are USDC base units.
    /// @param cashIn USDC this member moved in (collateral plus wallet contributions).
    /// @param cashOut USDC paid or queued to this member (payout cash, security withdrawals, claims).
    /// @param sec Security held for this member (collateral plus holdback, less draws and covers).
    /// @param claim End-state claim after a cancellation.
    /// @param paidRounds Rounds whose contribution is satisfied (wallet, draw or cover).
    /// @param securityBps This slot's sigma in bps.
    /// @param slot 1-based payout slot (0 = not a member).
    /// @param joined Whether the member has joined.
    /// @param received Whether the member has received their payout.
    struct MemberState {
        uint256 cashIn;
        uint256 cashOut;
        uint256 sec;
        uint256 claim;
        uint32 paidRounds;
        uint16 securityBps;
        uint8 slot;
        bool joined;
        bool received;
    }

    // ---------------------------------------------------------------- Errors

    /// @notice A collateral deposit or security withdrawal of zero.
    error ZeroAmount();
    /// @notice `contribute` for a round while an earlier unsettled round is unpaid and can be neither netted (the
    ///         caller's own round, when `settleRound` can net it) nor drawn in full from the caller's security
    ///         (audit 2 R1-11, R2-02, R2-03).
    error OutOfOrder();

    // ---------------------------------------------------------------- Events

    /// @notice A member accepted the terms and joined, posting `collateral` (may be zero).
    event Joined(address indexed member, uint256 collateral);
    /// @notice The last member joined; round 1 opens at `startTime`.
    event Activated(uint256 startTime);
    /// @notice A member added collateral to their security.
    event CollateralDeposited(address indexed member, uint256 amount);
    /// @notice A member's round-`round` contribution was satisfied: `fromWallet` pulled from the wallet and
    ///         `fromSecurity` drawn (or covered) from their security. `late` is true when it was paid after grace
    ///         with a LATE strike, or covered with a COVERED strike.
    event Contributed(
        address indexed member, uint256 indexed round, uint256 fromWallet, uint256 fromSecurity, bool late
    );
    /// @notice After grace, an unpaid wallet portion was covered in full from the member's security (COVERED
    ///         strike). Always accompanied by a `Contributed` event with `fromSecurity == amount`.
    event Covered(address indexed member, uint256 indexed round, uint256 amount);
    /// @notice The recipient of round `round` had not paid its own contribution, so `amount` (the whole
    ///         contribution; audit 2 R2-03: nothing is drawn from its security for it) was taken from its payout
    ///         instead (audit R1-07; no strike). Accompanied by a `Contributed` event with zero amounts, and
    ///         `RoundSettled.cash` is already net of `amount`. Ledger: `amount` moves payout → `circle_pool`, it never
    ///         touched the wallet.
    event OwnContributionNetted(address indexed member, uint256 indexed round, uint256 amount);
    /// @notice Round `round` paid `recipient`: `gross = fee + holdback + cash`.
    event RoundSettled(
        uint256 indexed round,
        address indexed recipient,
        uint256 gross,
        uint256 fee,
        uint256 holdback,
        uint256 cash
    );
    /// @notice The last round settled.
    event CircleCompleted();
    /// @notice A member withdrew security.
    event SecurityWithdrawn(address indexed member, uint256 amount);
    /// @notice A member's gap stalled round `round` (DEFAULT strike); `penalty` was moved from their net position
    ///         to the other members' (min(E, contribution), or 0 when no other member has a positive position).
    event Defaulted(address indexed member, uint256 indexed round, uint256 penalty);
    /// @notice A stall cancellation at round `round` wrote off `amount`, what `member` had taken out beyond what it
    ///         paid in (its fee included): the unsecured part of a paid-out member's remaining contributions (audit 2
    ///         R1-02). Not a strike; the Trusted-tier gate reads it to catch repeat beneficiaries.
    event PositionWrittenOff(address indexed member, uint256 indexed round, uint256 amount);
    /// @notice On cancellation: `member`'s net position `E = max(0, cashIn − cashOut − refund − fee charged on its
    ///         payout)` and the claim assigned (its at-par refund of security that backed no debt, plus its pool
    ///         share). Ledger mapping uses `claim` only: `netPosition` is informational (audit R2-22).
    event ClaimAssigned(address indexed member, uint256 netPosition, uint256 claim);
    /// @notice The circle was cancelled. `assets` (refunds plus the pool) were split into claims; `residual` is the
    ///         rounding dust. Escrowed fees not needed to cover the creditors' shortfall stay in `feeEscrow` for the
    ///         treasury.
    event CircleCancelled(CancelReason indexed reason, uint256 assets, uint256 residual);
    /// @notice A member claimed (or had queued in `owed`) their end-state claim.
    event Claimed(address indexed member, uint256 amount);
    /// @notice Escrowed fees were sent (or queued) to the treasury after completion or cancellation.
    event FeesFlushed(address indexed treasury, uint256 amount);
    /// @notice The Guardian pushed every round deadline back by `by` seconds; `totalExtension` is the new total.
    event DeadlineExtended(uint256 by, uint256 totalExtension);
    /// @notice Untracked USDC (donations) was sent (or queued) to the treasury.
    event DonationsSwept(address indexed treasury, uint256 amount);
    /// @notice Rounding residual was sent (or queued) to the treasury.
    event ResidualSwept(address indexed treasury, uint256 amount);

    // ---------------------------------------------------------------- Initialization

    /// @notice Initializes a fresh clone. Called by the factory in the same transaction as the clone, so nobody
    ///         can front-run it; the implementation itself has initializers disabled.
    /// @dev Checks `circleId != 0`, every §4.1 bound, members unique and non-zero,
    ///      `totalRounds == members.length`, `securityBps.length == members.length`, then stores `termsHash`
    ///      (see `MHCircleTerms.rotating`). Reverts `BadConfig` otherwise.
    /// @param p Terms, members in payout order, and per-slot sigma.
    function initialize(RotatingParams calldata p) external;

    // ---------------------------------------------------------------- Member actions

    /// @notice Joins the circle, accepting `terms`, and optionally posts collateral. The last join activates the
    ///         circle with `startTime = max(now, plannedStart)`.
    /// @dev Reverts `NotPending`, `JoinClosed` (after `joinDeadline`), `NotMember`, `AlreadyJoined`, `BadTerms`.
    ///      Collateral is pulled with `transferFrom` (exact approval expected).
    /// @param terms Must equal `termsHash()`.
    /// @param collateral USDC to post as security (may be zero).
    function join(bytes32 terms, uint256 collateral) external;

    /// @notice Adds collateral to the caller's security (Pending or Active, joined members only). Audit 2 R2-05: a
    ///         deposit that turns the caller's unpaid, short draw for an unsettled round past its grace into a full
    ///         one pays that round late, so it records a LATE strike like a late `contribute` (not for a recipient
    ///         whose own round `settleRound` can net). Closing review: every such round is struck, walking the
    ///         unsettled rounds in order as `settleRound` would draw them, not only the settling round.
    /// @dev Reverts `NotActive`, `NotMember` (not a joined member), `ZeroAmount`, and `UsdcPaused` /
    ///      `CircleBlacklisted` for such a late deposit.
    /// @param amount USDC to add.
    function depositCollateral(uint256 amount) external;

    /// @notice Pays the caller's round-`round` contribution: draws from security above the requirement, then
    ///         pulls the rest (`c − draw`) from the wallet. A LATE strike is recorded when a wallet payment is made
    ///         after grace, except by a round's recipient paying its own round when `settleRound` could net it
    ///         (audit 2 R1-19: that payment is circular). Rounds are paid in order (audit 2 R1-11): every unsettled
    ///         round before `round` must be paid first, except the caller's own round when `settleRound` can net it
    ///         (audit 2 R2-02); an earlier round drawn in full from the caller's security is satisfied by this call
    ///         first, with a zero pull and its own `Contributed` event (audit 2 R2-03), so no separate zero-pull call
    ///         is needed.
    /// @dev Window: `nextSettle ≤ round ≤ currentRound()`. Reverts `NotActive`, `NotMember`, `BadRound`,
    ///      `AlreadyPaid`, `OutOfOrder`, `ExceedsMaxPull`, and `UsdcPaused` for a late payment while USDC is
    ///      paused.
    /// @param round The round to pay.
    /// @param maxPull Upper bound on the wallet pull, protecting against state changes since `amountDue`.
    /// @return pulled The USDC pulled from the wallet.
    function contribute(uint256 round, uint256 maxPull) external returns (uint256 pulled);

    /// @notice Withdraws `amount` of the caller's security: anything above the requirement while Active,
    ///         everything once Completed. No fee. While Active it keeps `requiredSecurity` (which, for a paid-out
    ///         member that has not paid round `nextSettle`, includes a full contribution for that round: audit
    ///         R2-05), and a member that has not paid round `nextSettle` after its grace has ended (the deadline +
    ///         grace without any Guardian extension, audit R2-13) cannot take its security below `contribution`
    ///         (audit R1-06).
    /// @dev Reverts `NotActive` (Pending or Cancelled), `ZeroAmount`, `NotMember`, `InsufficientSecurity`.
    /// @param amount USDC to withdraw.
    function withdrawSecurity(uint256 amount) external;

    /// @notice Pays the caller's end-state claim after a cancellation (queued in `owed` if it cannot be sent).
    /// @dev Reverts `NothingToClaim`.
    /// @return amount The claim paid or queued.
    function claim() external returns (uint256 amount);

    // ---------------------------------------------------------------- Permissionless transitions

    /// @notice Settles round `nextSettle`: takes the draws of members whose wallet owes nothing, nets the
    ///         recipient's own unpaid part from its payout when the payout can absorb it (no strike), covers other
    ///         unpaid members in full from security after grace (COVERED strike), then pays the recipient
    ///         `gross − fee − holdback − netted`.
    /// @dev Reverts `NotActive`, `BadRound` (the round has not opened), `RoundShort` (a gap that cannot be
    ///      covered yet), `UsdcPaused` (a cover is needed while USDC is paused).
    function settleRound() external;

    /// @notice Cancels a circle whose round `nextSettle` is still short after grace + cure. Security that backs
    ///         no debt is refunded at par to its non-defaulting owner; each uncoverable member gets a DEFAULT strike
    ///         and loses `min(E, contribution)` of their net position to the others; the pool is split by net
    ///         position, with escrowed fees folded in only up to the creditors' shortfall. A non-defaulter that had
    ///         not paid the round is covered for it from its security and gets the COVERED strike `settleRound` would
    ///         give it (audit R2-08; not the round's recipient, and not a member whose draw is the whole
    ///         contribution).
    /// @dev Reverts `NotActive`, `NotStalled` (too early, or every gap is coverable), `UsdcPaused`.
    function cancelStalled() external;

    /// @notice Cancels a Pending circle after `joinDeadline`; every member's collateral becomes a claim (exact
    ///         refund). No strikes.
    /// @dev Reverts `NotPending`, `NotStalled` (deadline not passed), `UsdcPaused`.
    function cancelUnjoined() external;

    /// @notice Sends escrowed fees to the treasury once the circle is Completed, or after a cancellation the part
    ///         not folded back into the creditors' recovery.
    /// @dev Reverts `NotEnded`, `NothingToClaim`.
    function flushFees() external;

    /// @notice Sends untracked USDC (donations) to the treasury.
    /// @dev Reverts `NothingToClaim` when the balance holds nothing beyond the tracked buckets and `owedTotal`.
    function sweepDonations() external;

    /// @notice Sends the rounding residual to the treasury once every member bucket is zero.
    /// @dev Reverts `NotEnded` (not Completed/Cancelled, or security or claims remain), `NothingToClaim`.
    function sweepResidual() external;

    // ---------------------------------------------------------------- Guardian

    /// @notice Guardian: cancels the circle before the first payout (R4). Exact refunds, no strikes.
    /// @dev Reverts `NotGuardian`, `NotActive` (already ended), `BadRound` (a payout has been made).
    function guardianCancel() external;

    /// @notice Guardian: pushes every round deadline (and so every grace, cover and stall gate) back by `by`.
    /// @dev Active only. Reverts `NotGuardian`, `NotActive`, `ExtensionLimit` (zero, more than 7 days per call,
    ///      or more than 30 days in total).
    /// @param by Seconds to add.
    function extendDeadline(uint256 by) external;

    // ---------------------------------------------------------------- Views

    /// @notice Per-round contribution in USDC base units.
    function contribution() external view returns (uint256);

    /// @notice Fee in bps of the gross pot, charged on each successful settlement.
    function feeBps() external view returns (uint16);

    /// @notice Seconds per round.
    function roundDuration() external view returns (uint64);

    /// @notice Seconds after a round deadline before a payment is late and a gap can be covered.
    function grace() external view returns (uint64);

    /// @notice Seconds after grace before a short round can stall the circle.
    function cure() external view returns (uint64);

    /// @notice Last timestamp at which members can join.
    function joinDeadline() external view returns (uint64);

    /// @notice Earliest start.
    function plannedStart() external view returns (uint64);

    /// @notice Number of rounds (equal to the member count).
    function totalRounds() external view returns (uint32);

    /// @notice Lifecycle status.
    function status() external view returns (CircleStatus);

    /// @notice When round 1 opened (0 until Active).
    function startTime() external view returns (uint64);

    /// @notice Total Guardian extension, in seconds, added to every round deadline.
    function extension() external view returns (uint64);

    /// @notice The next round to settle (1-based).
    function nextSettle() external view returns (uint32);

    /// @notice Members that have joined.
    function joinedCount() external view returns (uint8);

    /// @notice Sum of every member's security.
    function secTotal() external view returns (uint256);

    /// @notice Sum of every unsettled round's pot.
    function potTotal() external view returns (uint256);

    /// @notice Fees escrowed until completion (after a cancellation: the part kept for the treasury).
    function feeEscrow() external view returns (uint256);

    /// @notice Sum of every unclaimed end-state claim.
    function claimTotal() external view returns (uint256);

    /// @notice Rounding residual from a cancellation, owed to the treasury.
    function residual() external view returns (uint256);

    /// @notice USDC contributed to round `round` that has not been settled (0 once the circle is Cancelled: unsettled
    ///         pots are folded into the claims).
    /// @param round The round.
    function pot(uint256 round) external view returns (uint256);

    /// @notice Whether `member`'s round-`round` contribution is satisfied. Every round below `nextSettle` is
    ///         settled, so it counts as paid for every member (settlement draws and covers write no flag).
    /// @param round The round.
    /// @param member The member.
    function paid(uint256 round, address member) external view returns (bool);

    /// @notice Members in payout order.
    function members() external view returns (address[] memory);

    /// @notice 1-based payout slot of `account` (0 = not a member).
    /// @param account The address.
    function slotOf(address account) external view returns (uint256);

    /// @notice Full per-member state.
    /// @param account The member.
    function memberState(address account) external view returns (MemberState memory);

    /// @notice The current round (0 before round 1 opens; capped at `totalRounds`).
    function currentRound() external view returns (uint256);

    /// @notice Round `round`'s deadline, `startTime + round·roundDuration + extension` (0 until Active).
    /// @param round The round.
    function roundDeadline(uint256 round) external view returns (uint256);

    /// @notice What `member` owes from its wallet for `round` now: `contribution − draw`, or 0 when not Active,
    ///         not a member, already paid, already settled, not open yet (audit R2-22: a round after
    ///         `currentRound()` cannot be paid), not payable yet because an earlier unsettled round is unpaid and
    ///         cannot be netted or drawn in full (audit 2 R1-11/R2-02), or `member`'s own round when `settleRound`
    ///         can net it from the payout (audit 2 R1-03/R1-19: `contribute` would still accept that circular
    ///         payment, but nothing is due). Earlier rounds drawn in full are drawn first, as `contribute` does (audit
    ///         2 R2-03), so the amount is the wallet pull `contribute(round, …)` makes now.
    /// @param member The member.
    /// @param round The round.
    function amountDue(address member, uint256 round) external view returns (uint256);

    /// @notice Security `member` must keep while Active: `S_k` before their payout,
    ///         `ceil(σ·(n − paidRounds)·c)` after it, and `ceil(σ·(n − paidRounds − 1)·c) + c` after it while round
    ///         `nextSettle` is unpaid (audit R2-05: the open round's full contribution; equal at σ = 100%). After grace
    ///         `withdrawSecurity` also keeps `contribution` for a member that has not paid round `nextSettle` (R1-06).
    /// @param member The member.
    function requiredSecurity(address member) external view returns (uint256);

    /// @notice Sum of the tracked buckets: security, unsettled pots, escrowed fees, claims and residual.
    ///         `USDC.balanceOf(this) ≥ trackedAssets() + owedTotal()` always holds.
    function trackedAssets() external view returns (uint256);
}
