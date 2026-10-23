// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { MHCircleBase } from "./MHCircleBase.sol";
import { MHCircleConstants as K } from "./MHCircleConstants.sol";
import { IMHCircle } from "./interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "./interfaces/IMHRotatingCircle.sol";
import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "./interfaces/IMHReputation.sol";
import { IUSDC } from "./interfaces/IUSDC.sol";
import { CircleMode, CircleStatus, RotatingConfig, RotatingParams } from "./MHCircleTypes.sol";

// Every time gate is days long (rounds ≥ 7 days, grace ≥ 48h, cure ≥ 72h): a few seconds of sequencer timestamp
// drift cannot change an outcome that matters.
// forge-lint: disable-start(block-timestamp)

/// @title MHRotatingCircle
/// @notice Rotating savings circle (ROSCA) on idle USDC, with no yield (spec §4.4, decision 12). Round k's pot of
///         `n·c` goes to slot k. Because slot k is paid before it has finished contributing, it must hold
///         security `S_k = ceil(σ_k·(n−k)·c)`: its own collateral first, then a holdback from its payout. Every
///         later contribution draws `min(c, sec − reqAfter)` from that security, so at σ = 100% a paid member's
///         wallet owes nothing and nobody else carries its credit risk.
///         A round that is still short after grace is covered in full from the missing member's security (COVERED
///         strike), never partially; the recipient's own missing part is netted from its payout instead (no strike).
///         A round still short after grace + cure lets anyone cancel: security that backs no debt is refunded at
///         par, each uncoverable member gets a DEFAULT strike and loses `min(E, c)` of its net position to the
///         others (a covered non-defaulter gets the COVERED strike `settleRound` would give it), the pool is split
///         pro rata to the adjusted positions, and escrowed fees go back into it only as far as the creditors are
///         short (the rest stays for the treasury). The stalled round's recipient's own contribution never counts
///         (it is circular, audit 2 R1-03), a written-off negative position is flagged (`PositionWrittenOff`, audit
///         2 R1-02), and rounds are paid in order (audit 2 R1-11). See `_unwind`.
/// @dev EIP-1167 clone of an immutable implementation (initializers disabled in the base constructor). No admin,
///      owner, Guardian, operator or treasury path to member principal: the Guardian can only cancel before the
///      first payout (refunds are exact) and extend deadlines; the treasury only receives fees after completion,
///      cancellation dust and donations. Every loop is over the members (≤ 50) or the rounds (= members).
///      Rounding: security requirements round up (against the member being paid), the fee rounds down (against
///      the treasury), claims round down with the remainder kept as residual.
///      Storage: a member is two slots, and `claim` shares a slot with `cashIn`/`cashOut` so that assigning claims
///      on a cancellation never writes a fresh slot. Settlement does not write `paid` flags for the members it
///      draws or covers: every round below `nextSettle` is paid by definition (see `paid`). Both keep the n = 50
///      worst cases under the spec's 5M gas bound.
contract MHRotatingCircle is MHCircleBase, IMHRotatingCircle {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Storage layout of a member. 80-bit amounts hold 1.2e18 USDC; every write is range-checked.
    struct Member {
        // slot 0
        uint80 cashIn;
        uint80 cashOut;
        uint80 claim;
        // slot 1
        uint80 sec;
        uint32 paidRounds;
        uint16 securityBps;
        uint8 slot;
        bool joined;
        bool received;
    }

    // ---------------------------------------------------------------- Config (written once in `initialize`)

    /// @inheritdoc IMHCircle
    bytes32 public circleId;
    /// @inheritdoc IMHCircle
    bytes32 public termsHash;
    /// @inheritdoc IMHRotatingCircle
    uint256 public contribution;
    /// @inheritdoc IMHRotatingCircle
    uint16 public feeBps;
    /// @inheritdoc IMHRotatingCircle
    uint64 public roundDuration;
    /// @inheritdoc IMHRotatingCircle
    uint64 public grace;
    /// @inheritdoc IMHRotatingCircle
    uint64 public cure;
    /// @inheritdoc IMHRotatingCircle
    uint64 public joinDeadline;
    /// @inheritdoc IMHRotatingCircle
    uint64 public plannedStart;
    /// @inheritdoc IMHRotatingCircle
    uint32 public totalRounds;

    // ---------------------------------------------------------------- Lifecycle

    /// @inheritdoc IMHRotatingCircle
    CircleStatus public status;
    /// @inheritdoc IMHRotatingCircle
    uint64 public startTime;
    /// @inheritdoc IMHRotatingCircle
    uint64 public extension;
    /// @inheritdoc IMHRotatingCircle
    uint32 public nextSettle;
    /// @inheritdoc IMHRotatingCircle
    uint8 public joinedCount;

    // ---------------------------------------------------------------- Buckets (USDC base units)

    /// @inheritdoc IMHRotatingCircle
    uint256 public secTotal;
    /// @inheritdoc IMHRotatingCircle
    uint256 public potTotal;
    /// @inheritdoc IMHRotatingCircle
    uint256 public feeEscrow;
    /// @inheritdoc IMHRotatingCircle
    uint256 public claimTotal;
    /// @inheritdoc IMHRotatingCircle
    uint256 public residual;
    /// @dev Contributions to rounds that are not yet settled. Left as is on a cancellation (see `pot`).
    mapping(uint256 round => uint256 amount) private _pot;

    address[] private _members;
    mapping(address account => Member state) private _m;
    /// @dev Contributions made through `contribute` to rounds that are not yet settled.
    mapping(uint256 round => mapping(address member => bool done)) private _paid;

    /// @param usdc USDC on this chain.
    /// @param registry The circle registry (Guardian and treasury are read from it at call time).
    /// @param reputation The strike register.
    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation)
        MHCircleBase(usdc, registry, reputation)
    { }

    // ---------------------------------------------------------------- Initialization

    /// @inheritdoc IMHCircle
    function circleMode() external pure returns (CircleMode) {
        return CircleMode.Rotating;
    }

    /// @inheritdoc IMHRotatingCircle
    function initialize(RotatingParams calldata p) external initializer {
        RotatingConfig calldata cfg = p.config;
        uint256 n = p.members.length;
        _checkConfig(cfg, n, p.securityBps.length);
        // Audit 2 R1-17: only a factory clone (registered as a reporter before `initialize`) can become a circle;
        // any other clone could never record a strike, so its strike paths would revert and trap funds.
        if (!REPUTATION.isReporter(address(this))) revert BadConfig();
        for (uint256 i; i < n; ++i) {
            address a = p.members[i];
            uint16 sigma = p.securityBps[i];
            if (a == address(0) || sigma < K.MIN_SECURITY_BPS || sigma > K.MAX_SECURITY_BPS) {
                revert BadConfig();
            }
            Member storage m = _m[a];
            if (m.slot != 0) revert BadConfig(); // duplicate member
            // forge-lint: disable-next-line(unsafe-typecast)
            m.slot = uint8(i + 1); // i < MAX_MEMBERS = 50
            m.securityBps = sigma;
            _members.push(a);
        }
        circleId = cfg.circleId;
        contribution = cfg.contribution;
        feeBps = cfg.feeBps;
        roundDuration = cfg.roundDuration;
        grace = cfg.grace;
        cure = cfg.cure;
        joinDeadline = cfg.joinDeadline;
        plannedStart = cfg.plannedStart;
        totalRounds = cfg.totalRounds;
        nextSettle = 1;
        termsHash = _rotatingTermsHash(cfg, p.members, p.securityBps);
    }

    // ---------------------------------------------------------------- Member actions

    /// @inheritdoc IMHRotatingCircle
    function join(bytes32 terms, uint256 collateral) external nonReentrant {
        if (status != CircleStatus.Pending) revert NotPending();
        if (block.timestamp > joinDeadline) revert JoinClosed();
        Member storage m = _m[msg.sender];
        if (m.slot == 0) revert NotMember();
        if (m.joined) revert AlreadyJoined();
        if (terms != termsHash) revert BadTerms();

        m.joined = true;
        uint8 joined = joinedCount + 1;
        joinedCount = joined;
        if (collateral != 0) _addCollateral(m, collateral);
        emit Joined(msg.sender, collateral);
        if (joined == _members.length) {
            uint64 start = block.timestamp > plannedStart ? uint64(block.timestamp) : plannedStart;
            startTime = start;
            status = CircleStatus.Active;
            emit Activated(start);
        }
        if (collateral != 0) _pull(msg.sender, collateral);
    }

    /// @inheritdoc IMHRotatingCircle
    function depositCollateral(uint256 amount) external nonReentrant {
        CircleStatus st = status;
        if (st != CircleStatus.Pending && st != CircleStatus.Active) revert NotActive();
        if (amount == 0) revert ZeroAmount();
        Member storage m = _m[msg.sender];
        if (!m.joined) revert NotMember();

        // Audit 2 R2-05: collateral that pays an unsettled round late (see `_latePaid`; closing review: every such
        // round, not only the settling one) records a LATE strike for it, exactly like a late wallet `contribute`.
        // A deposit too small to complete a draw is not a payment: `settleRound` still covers that round (COVERED)
        // or it stalls, so a round is never struck twice. 0 while Pending (no round has opened).
        uint256 late = _latePaid(m, amount);
        _addCollateral(m, amount);
        if (late != 0) _requireUsdcLive();
        emit CollateralDeposited(msg.sender, amount);
        for (uint256 r = nextSettle; late >> r != 0; ++r) {
            if ((late >> r) & 1 == 1) _strike(msg.sender, r, IMHReputation.Reason.LATE);
        }
        _pull(msg.sender, amount);
    }

    /// @inheritdoc IMHRotatingCircle
    function contribute(uint256 round, uint256 maxPull) external nonReentrant returns (uint256 pulled) {
        if (status != CircleStatus.Active) revert NotActive();
        Member storage m = _m[msg.sender];
        uint256 slot = m.slot;
        if (slot == 0) revert NotMember();
        uint256 s = nextSettle;
        if (round < s || round > currentRound()) revert BadRound();
        if (_paid[round][msg.sender]) revert AlreadyPaid();
        uint256 c = contribution;
        _catchUp(msg.sender, m, slot, round, s, c);
        uint256 draw = _draw(m, c);
        pulled = c - draw;
        if (pulled > maxPull) revert ExceedsMaxPull();
        // A member whose wallet owes nothing is never struck (spec §4.4), and neither is a recipient paying its
        // own round when `settleRound` could have netted it at no cost (audit 2 R1-19).
        bool late = pulled != 0 && block.timestamp > _graceEnd(round)
            && !(slot == round && _nettable(m, round, c, draw));
        if (late) _requireUsdcLive();

        _paid[round][msg.sender] = true;
        m.paidRounds += 1;
        if (draw != 0) {
            m.sec = (uint256(m.sec) - draw).toUint80();
            secTotal -= draw;
        }
        m.cashIn = (uint256(m.cashIn) + pulled).toUint80();
        _pot[round] += c;
        potTotal += c;
        emit Contributed(msg.sender, round, pulled, draw, late);

        if (late) _strike(msg.sender, round, IMHReputation.Reason.LATE);
        if (pulled != 0) _pull(msg.sender, pulled);
    }

    /// @inheritdoc IMHRotatingCircle
    function withdrawSecurity(uint256 amount) external nonReentrant {
        CircleStatus st = status;
        if (st != CircleStatus.Active && st != CircleStatus.Completed) revert NotActive();
        if (amount == 0) revert ZeroAmount();
        Member storage m = _m[msg.sender];
        if (m.slot == 0) revert NotMember();
        uint256 have = m.sec;
        if (st == CircleStatus.Active) {
            uint256 c = contribution;
            uint256 req = _required(msg.sender, m, c);
            if (amount > (have > req ? have - req : 0)) revert InsufficientSecurity();
            // Audit R1-06: once the settling round is past grace, a member that has not paid it cannot take its
            // security below c. Below c it is (or becomes) a defaulter, and shrinking its net position would shrink
            // the min(E, c) penalty the others are owed. Paying the round first lifts the restriction. Audit R2-13:
            // measured against the grace end without the Guardian's extension, so an extension never lifts it.
            uint256 s = nextSettle;
            if (
                have - amount < c && block.timestamp > uint256(startTime) + s * roundDuration + grace
                    && !_paid[s][msg.sender]
            ) revert InsufficientSecurity();
        } else if (amount > have) {
            revert InsufficientSecurity();
        }

        m.sec = (uint256(m.sec) - amount).toUint80();
        m.cashOut = (uint256(m.cashOut) + amount).toUint80();
        secTotal -= amount;
        emit SecurityWithdrawn(msg.sender, amount);
        _pay(msg.sender, amount);
    }

    /// @inheritdoc IMHRotatingCircle
    function claim() external nonReentrant returns (uint256 amount) {
        Member storage m = _m[msg.sender];
        amount = m.claim;
        if (amount == 0) revert NothingToClaim();

        m.claim = 0;
        m.cashOut = (uint256(m.cashOut) + amount).toUint80();
        claimTotal -= amount;
        emit Claimed(msg.sender, amount);
        _pay(msg.sender, amount);
    }

    // ---------------------------------------------------------------- Permissionless transitions

    /// @inheritdoc IMHRotatingCircle
    function settleRound() external nonReentrant {
        if (status != CircleStatus.Active) revert NotActive();
        uint256 s = nextSettle;
        if (s > currentRound()) revert BadRound();
        (uint256 covered, uint256 drawn, uint256 netted) = _collect(s);
        if (covered != 0) _requireUsdcLive();
        (address recipient, uint256 cash) = _payout(s, drawn, netted);
        _strikeAll(covered, s, IMHReputation.Reason.COVERED);
        _pay(recipient, cash);
    }

    /// @inheritdoc IMHRotatingCircle
    function cancelStalled() external nonReentrant {
        if (status != CircleStatus.Active) revert NotActive();
        uint256 s = nextSettle;
        if (block.timestamp <= _graceEnd(s) + cure) revert NotStalled();
        _requireUsdcLive();
        // A gap is uncoverable exactly when `settleRound` (past grace) would revert on it: unpaid, sec < c, and not
        // the recipient whose payout can absorb its own part.
        uint256 c = contribution;
        uint256 n = _members.length;
        uint256 defaulters;
        uint256 covered;
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            if (_paid[s][a]) continue;
            Member storage m = _m[a];
            bool recipient = i + 1 == s;
            uint256 draw = _draw(m, c);
            if (m.sec >= c) {
                // Audit R2-08: `_refund` covers it for round s from its security, exactly as `settleRound` would, so
                // it gets the same COVERED strike (none when its draw is the whole contribution, and never for the
                // recipient, whose own part `settleRound` nets).
                // forge-lint: disable-next-line(incorrect-shift)
                if (!recipient && draw < c) covered |= 1 << i;
                continue;
            }
            if (recipient && _nettable(m, s, c, draw)) continue;
            // forge-lint: disable-next-line(incorrect-shift)
            defaulters |= 1 << i; // bit i = member index i
        }
        if (defaulters == 0) revert NotStalled();
        _unwind(CancelReason.Stalled, defaulters, s);
        _strikeAll(defaulters, s, IMHReputation.Reason.DEFAULT);
        _strikeAll(covered, s, IMHReputation.Reason.COVERED);
    }

    /// @inheritdoc IMHRotatingCircle
    function cancelUnjoined() external nonReentrant {
        if (status != CircleStatus.Pending) revert NotPending();
        if (block.timestamp <= joinDeadline) revert NotStalled();
        _requireUsdcLive();
        _unwind(CancelReason.Unjoined, 0, 1);
    }

    /// @inheritdoc IMHRotatingCircle
    function flushFees() external nonReentrant {
        CircleStatus st = status;
        if (st != CircleStatus.Completed && st != CircleStatus.Cancelled) revert NotEnded();
        uint256 amount = feeEscrow;
        if (amount == 0) revert NothingToClaim();
        feeEscrow = 0;
        address treasury = REGISTRY.treasury();
        emit FeesFlushed(treasury, amount);
        _pay(treasury, amount);
    }

    /// @inheritdoc IMHRotatingCircle
    function sweepDonations() external nonReentrant {
        uint256 held = trackedAssets() + owedTotal;
        uint256 balance = USDC.balanceOf(address(this));
        if (balance <= held) revert NothingToClaim();
        uint256 amount = balance - held;
        address treasury = REGISTRY.treasury();
        emit DonationsSwept(treasury, amount);
        _pay(treasury, amount);
    }

    /// @inheritdoc IMHRotatingCircle
    function sweepResidual() external nonReentrant {
        CircleStatus st = status;
        if (
            (st != CircleStatus.Completed && st != CircleStatus.Cancelled) || secTotal != 0 || claimTotal != 0
        ) revert NotEnded();
        uint256 amount = residual;
        if (amount == 0) revert NothingToClaim();
        residual = 0;
        address treasury = REGISTRY.treasury();
        emit ResidualSwept(treasury, amount);
        _pay(treasury, amount);
    }

    // ---------------------------------------------------------------- Guardian

    /// @inheritdoc IMHRotatingCircle
    function guardianCancel() external nonReentrant {
        if (msg.sender != REGISTRY.guardian()) revert NotGuardian();
        CircleStatus st = status;
        if (st != CircleStatus.Pending && st != CircleStatus.Active) revert NotActive();
        // R4: once a payout has been made, a cancel would let early recipients keep their pots.
        if (nextSettle != 1) revert BadRound();
        _unwind(CancelReason.Guardian, 0, 1);
    }

    /// @inheritdoc IMHRotatingCircle
    function extendDeadline(uint256 by) external nonReentrant {
        if (msg.sender != REGISTRY.guardian()) revert NotGuardian();
        if (status != CircleStatus.Active) revert NotActive();
        if (by == 0 || by > K.MAX_EXTENSION_PER_CALL) revert ExtensionLimit();
        uint256 total = extension + by;
        if (total > K.MAX_EXTENSION_TOTAL) revert ExtensionLimit();
        // forge-lint: disable-next-line(unsafe-typecast)
        extension = uint64(total); // ≤ 30 days
        emit DeadlineExtended(by, total);
    }

    // ---------------------------------------------------------------- Views

    /// @inheritdoc IMHRotatingCircle
    function pot(uint256 round) external view returns (uint256) {
        return status == CircleStatus.Cancelled ? 0 : _pot[round];
    }

    /// @inheritdoc IMHRotatingCircle
    function paid(uint256 round, address member) external view returns (bool) {
        if (round == 0 || _m[member].slot == 0) return false;
        return round < nextSettle || _paid[round][member];
    }

    /// @inheritdoc IMHRotatingCircle
    function members() external view returns (address[] memory) {
        return _members;
    }

    /// @inheritdoc IMHRotatingCircle
    function slotOf(address account) external view returns (uint256) {
        return _m[account].slot;
    }

    /// @inheritdoc IMHRotatingCircle
    function memberState(address account) external view returns (MemberState memory st) {
        Member storage m = _m[account];
        st.cashIn = m.cashIn;
        st.cashOut = m.cashOut;
        st.sec = m.sec;
        st.claim = m.claim;
        st.paidRounds = m.paidRounds;
        st.securityBps = m.securityBps;
        st.slot = m.slot;
        st.joined = m.joined;
        st.received = m.received;
    }

    /// @inheritdoc IMHRotatingCircle
    function currentRound() public view returns (uint256) {
        uint256 start = startTime;
        if (start == 0 || block.timestamp < start) return 0;
        uint256 r = (block.timestamp - start) / roundDuration + 1;
        uint256 n = totalRounds;
        return r > n ? n : r;
    }

    /// @inheritdoc IMHRotatingCircle
    function roundDeadline(uint256 round) external view returns (uint256) {
        if (startTime == 0) return 0;
        return _deadline(round);
    }

    /// @inheritdoc IMHRotatingCircle
    function amountDue(address member, uint256 round) external view returns (uint256) {
        Member storage m = _m[member];
        // Audit R2-22: 0 for a round that has not opened yet (`contribute` would revert `BadRound`); audit 2 R1-11:
        // and for one that would be paid out of order (`OutOfOrder`).
        uint256 s = nextSettle;
        if (
            status != CircleStatus.Active || m.slot == 0 || round < s || round > currentRound()
                || _paid[round][member]
        ) return 0;
        uint256 c = contribution;
        // Audit 2 R2-03: `contribute` first satisfies every earlier unsettled round that is fully drawn from security
        // (`_catchUp`); the same walk here, on copies, so a member fully drawn for round s is asked for round s + 1.
        uint256 sec = m.sec;
        uint256 paidRounds = m.paidRounds;
        for (uint256 r = _catchUpFrom(member, round, s); r < round; ++r) {
            uint256 d = _drawAt(m, sec, paidRounds, c);
            if (r == m.slot && _nettableAt(m, sec, r, c, d)) continue;
            if (d != c) return 0; // `OutOfOrder`
            sec -= c;
            ++paidRounds;
        }
        uint256 draw = _drawAt(m, sec, paidRounds, c);
        // Audit 2 R1-03/R1-19: a recipient's own round is netted from its payout at no cost (audit R1-07), so the
        // app never asks for it.
        if (m.slot == round && _nettableAt(m, sec, round, c, draw)) return 0;
        return c - draw;
    }

    /// @inheritdoc IMHRotatingCircle
    function requiredSecurity(address member) external view returns (uint256) {
        Member storage m = _m[member];
        if (m.slot == 0) return 0;
        return _required(member, m, contribution);
    }

    /// @inheritdoc IMHRotatingCircle
    function trackedAssets() public view returns (uint256) {
        return secTotal + potTotal + feeEscrow + claimTotal + residual;
    }

    // ---------------------------------------------------------------- Internal: settlement

    /// @dev Satisfies every member of round `s` that has not contributed: the recipient (slot `s`) has its whole own
    ///      contribution netted from its payout when the payout can absorb it (audit R1-07, no strike, at any time;
    ///      audit 2 R2-03: nothing is drawn from its security, which stays for its later rounds); a member whose draw
    ///      is the whole contribution is drawn without a strike; anyone else is covered in full from security after
    ///      grace, or the call reverts `RoundShort` (no partial cover).
    ///      Returns the bitmap of covered member indices, the USDC taken from security and the netted amount. No
    ///      `_paid` flag is written: once `nextSettle` moves past `s` every member counts as paid for it.
    function _collect(uint256 s) private returns (uint256 covered, uint256 drawn, uint256 netted) {
        uint256 c = contribution;
        uint256 n = _members.length;
        bool afterGrace = block.timestamp > _graceEnd(s);
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            if (_paid[s][a]) continue;
            Member storage m = _m[a];
            uint256 fromSec = _draw(m, c);
            bool cover = fromSec < c;
            if (i + 1 == s && _nettable(m, s, c, 0)) {
                // Audit R1-07: the recipient's own contribution is netted from its payout (circular, no strike).
                // Audit 2 R2-03: all of it, with nothing drawn from its security, so the security its later rounds
                // were shown as drawing from (`amountDue` 0) is still there after this payout.
                fromSec = 0;
                netted = c;
                cover = false;
                emit OwnContributionNetted(a, s, c);
            } else if (cover) {
                // A draw of the whole contribution already implies `sec ≥ c`; a cover needs the same.
                if (!afterGrace || m.sec < c) revert RoundShort();
                fromSec = c;
            }
            m.paidRounds += 1;
            if (fromSec != 0) m.sec = (uint256(m.sec) - fromSec).toUint80();
            drawn += fromSec;
            emit Contributed(a, s, 0, fromSec, cover);
            if (cover) {
                // forge-lint: disable-next-line(incorrect-shift)
                covered |= 1 << i; // bit i = member index i
                emit Covered(a, s, c);
            }
        }
    }

    /// @dev Audit 2 R1-11, amended by R2-02 and R2-03: rounds are paid in order, so a member never has money in a
    ///      later pot while an earlier unsettled round counts it as missing. Before `round`, every unsettled round
    ///      `r` in `[s, round)` must be paid, or be the member's own round that `settleRound` can net (R2-02: a
    ///      recipient that cannot be netted must pay its own round first), or be drawn in full from its security
    ///      now: such a round is satisfied here with a zero pull, exactly as `contribute(r, 0)` would, so the draw
    ///      for `round` is computed after it (R2-03: a member fully drawn for round s is not blocked from round s + 1,
    ///      and `amountDue` asks for it). Anything else reverts `OutOfOrder`. At most `round − s` iterations, and
    ///      O(1) when the previous round is already paid (the usual case).
    function _catchUp(address a, Member storage m, uint256 slot, uint256 round, uint256 s, uint256 c)
        private
    {
        for (uint256 r = _catchUpFrom(a, round, s); r < round; ++r) {
            uint256 draw = _draw(m, c);
            if (r == slot && _nettable(m, r, c, draw)) continue;
            if (draw != c) revert OutOfOrder();
            _paid[r][a] = true;
            m.paidRounds += 1;
            m.sec = (uint256(m.sec) - c).toUint80();
            secTotal -= c;
            _pot[r] += c;
            potTotal += c;
            emit Contributed(a, r, 0, c, false);
        }
    }

    /// @dev Audit 2 R2-05, closing review: the rounds (bit r = round r) that a collateral deposit of `amount` by the
    ///      caller (`m`) pays late. Walks the unsettled rounds from `nextSettle` in order, as `settleRound` would draw
    ///      them (and `_catchUp`/`amountDue` simulate), while they are past their grace end: a round the caller
    ///      paid is skipped; before the deposit, a round drawn in full is consumed and the caller's own round that
    ///      `settleRound` can net is skipped, until the first round the caller owes (unpaid, short, not nettable).
    ///      From that round on, every round the deposit makes a full draw is paid late (its own round only when it
    ///      cannot be netted after the deposit either); the walk stops at the first round still short. So one
    ///      deposit that completes several overlapping rounds is struck for each, whatever the keeper's timing, as
    ///      paying them through `contribute` would be. Rounds ≤ 50, so the bitmap fits; at most
    ///      `currentRound − nextSettle + 1` ≤ 50 iterations.
    function _latePaid(Member storage m, uint256 amount) private view returns (uint256 late) {
        uint256 c = contribution;
        uint256 slot = m.slot;
        uint256 before = m.sec;
        uint256 sec = before + amount;
        uint256 p = m.paidRounds;
        uint256 cur = currentRound();
        bool owing;
        for (uint256 r = nextSettle; r <= cur && block.timestamp > _graceEnd(r); ++r) {
            if (_paid[r][msg.sender]) continue;
            uint256 d = _drawAt(m, sec, p, c);
            if (!owing) {
                uint256 d0 = _drawAt(m, before, p, c);
                if (r == slot && _nettableAt(m, before, r, c, d0)) continue;
                if (d0 == c) before -= c;
                else owing = true;
            } else if (r == slot && _nettableAt(m, sec, r, c, d)) {
                continue;
            }
            if (d != c) break;
            // forge-lint: disable-next-line(incorrect-shift)
            if (owing) late |= 1 << r; // r ≤ 50
            sec -= c;
            ++p;
        }
    }

    /// @dev The first round of the unpaid run that ends just before `round`: walking back from `round − 1` to the
    ///      settling round `s`, it stops after the first round `a` paid. A paid round implies every unsettled round
    ///      before it is paid or is `a`'s own nettable round (its `contribute` checked them), so only `[from, round)`
    ///      needs checking.
    function _catchUpFrom(address a, uint256 round, uint256 s) private view returns (uint256 from) {
        from = round;
        while (from > s && !_paid[from - 1][a]) {
            --from;
        }
    }

    /// @dev Whether the recipient of round `s` can have `c − draw` netted from its payout: after taking `draw` from
    ///      its security, `n·c − fee − holdback ≥ c − draw` (the same numbers `_payout` uses). The answer does not
    ///      depend on `draw` (with `sec ≥ S_s` both sides hold since `n·c − fee ≥ c`; below it the draw is 0), so
    ///      `_collect` nets the whole contribution (`draw = 0`).
    function _nettable(Member storage r, uint256 s, uint256 c, uint256 draw) private view returns (bool) {
        return _nettableAt(r, r.sec, s, c, draw);
    }

    /// @dev `_nettable` with the recipient's security given as `sec` (`amountDue`'s simulation).
    function _nettableAt(Member storage r, uint256 sec, uint256 s, uint256 c, uint256 draw)
        private
        view
        returns (bool)
    {
        uint256 gross = uint256(totalRounds) * c;
        uint256 left = sec - draw;
        uint256 need = _req(r.securityBps, totalRounds - s, c);
        uint256 holdback = left >= need ? 0 : need - left;
        return gross - gross * feeBps / K.BPS - holdback >= c - draw;
    }

    /// @dev Pays round `s` to slot `s`: `gross = _pot[s] + drawn + netted` (= n·c), `fee = floor(gross·feeBps)`,
    ///      `holdback = max(0, S_s − sec)`, `cash = gross − fee − holdback − netted`. The cash is paid by the
    ///      caller after every effect. `S_s ≤ (n−1)·c ≤ gross − fee` because n ≤ 50 and feeBps ≤ 200, and
    ///      `_collect` nets only what the payout can absorb, so `cash` never underflows.
    function _payout(uint256 s, uint256 drawn, uint256 netted)
        private
        returns (address recipient, uint256 cash)
    {
        uint256 fromPot = _pot[s];
        uint256 gross = fromPot + drawn + netted;
        recipient = _members[s - 1];
        Member storage r = _m[recipient];
        uint256 fee = gross * feeBps / K.BPS;
        uint256 need = _req(r.securityBps, totalRounds - s, contribution);
        uint256 have = r.sec;
        uint256 holdback = have >= need ? 0 : need - have;
        cash = gross - fee - holdback - netted;

        _pot[s] = 0;
        potTotal -= fromPot;
        secTotal = secTotal - drawn + holdback;
        feeEscrow += fee;
        r.sec = (have + holdback).toUint80();
        r.received = true;
        r.cashOut = (uint256(r.cashOut) + cash).toUint80();
        // forge-lint: disable-next-line(unsafe-typecast)
        nextSettle = uint32(s + 1); // s ≤ 50
        emit RoundSettled(s, recipient, gross, fee, holdback, cash);
        if (s == totalRounds) {
            status = CircleStatus.Completed;
            emit CircleCompleted();
        }
    }

    // ---------------------------------------------------------------- Internal: cancellation

    /// @dev Cancels at settling round `s` (`defaulters` is a bitmap over member indices; 0 for an unjoined or
    ///      Guardian cancellation) and assigns every claim (fixes R1; audit R1-01, R1-02):
    ///      1. Refund at par, outside the pool, the security of each non-defaulter that backs no debt (`_refund`:
    ///         all of it before the member's payout, the excess over `ceil(σ·(n − paidRounds)·c)` after it), after
    ///         returning its contributions to rounds after `s` to its security and, on a stall, covering its own
    ///         round-`s` gap. Free collateral therefore never moves anyone else's claim, whenever it is deposited
    ///         or withdrawn. A defaulter's security stays in the pool (it is the penalty base).
    ///      2. Net position `E = max(0, cashIn − cashOut − refund − fee charged on its payout)`.
    ///      3. Escrowed fees join the pool only up to the creditors' shortfall (the total negative position); the
    ///         rest stays in `feeEscrow` for the treasury (`flushFees`).
    ///      4. Defaulters lose `min(E, c)`, redistributed to the other members pro rata to their E; if none of them
    ///         has a positive E nothing is moved (a penalty can never go to the treasury).
    ///      5. `claim_m = refund_m + floor(pool·W_m/ΣW)`; the pool remainder is residual.
    function _unwind(CancelReason reason, uint256 defaulters, uint256 s) private {
        uint256 n = _members.length;
        uint256 c = contribution;
        (uint256[] memory e, uint256[] memory refunds, uint256 refundTotal, uint256 debt) =
            _positions(defaulters, s, c);
        uint256 escrow = feeEscrow;
        uint256 kept = escrow > debt ? escrow - debt : 0;
        uint256 pool = secTotal + potTotal - refundTotal + (escrow - kept);

        uint256[] memory w = _weights(e, defaulters, s, c);
        uint256 sumW;
        for (uint256 i; i < n; ++i) {
            sumW += w[i];
        }
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            uint256 share = sumW == 0 ? 0 : pool * w[i] / sumW;
            assigned += share;
            uint256 amount = share + refunds[i];
            if (amount != 0) _m[a].claim = amount.toUint80();
            emit ClaimAssigned(a, e[i], amount);
        }
        // Unsettled pots are folded into `pool` through `potTotal`; their per-round entries are dead from here on
        // (`pot` reads 0 once Cancelled). Not clearing them saves up to 49 storage writes, which keeps the
        // n = 50 worst case of `cancelStalled` clear of the 5M gas bound.
        secTotal = 0;
        potTotal = 0;
        feeEscrow = kept;
        claimTotal = assigned + refundTotal;
        residual = pool - assigned;
        status = CircleStatus.Cancelled;
        emit CircleCancelled(reason, pool + refundTotal, pool - assigned);
    }

    /// @dev Steps 1–2 of `_unwind` for every member: its at-par refund and its net position E, plus the refund total
    ///      and the creditors' shortfall (the sum of the negative positions). Zeroes every member's security.
    function _positions(uint256 defaulters, uint256 s, uint256 c)
        private
        returns (uint256[] memory e, uint256[] memory refunds, uint256 refundTotal, uint256 debt)
    {
        uint256 n = _members.length;
        uint256 fee = n * c * feeBps / K.BPS; // every settled round charged its recipient this fee
        bool stall = defaulters != 0;
        e = new uint256[](n);
        refunds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = (defaulters >> i) & 1 == 1 ? 0 : _refundAt(i, s, c, stall);
            refunds[i] = r;
            refundTotal += r;
            address a = _members[i];
            Member storage m = _m[a];
            uint256 debit = uint256(m.cashOut) + r + (m.received ? fee : 0);
            if (m.cashIn > debit) {
                e[i] = m.cashIn - debit;
            } else if (debit != m.cashIn) {
                uint256 d = debit - m.cashIn;
                debt += d;
                // Audit 2 R1-02: what this member took out beyond what it paid in (its fee included) is written off
                // by the cancellation; flagged for the Trusted-tier gate.
                if (stall) emit PositionWrittenOff(a, s, d);
            }
            if (m.sec != 0) m.sec = 0;
        }
    }

    /// @dev Audit 2 R1-03: the recipient's own round-`s` contribution is circular (`settleRound` nets it, audit
    ///      R1-07), so it never counts in E: if paid, it is returned to its security and refunded at par, and it is
    ///      never covered at cancel time. Its E is always `(s − 1)·c`-based, whatever it chose to do in the cure.
    function _refundAt(uint256 i, uint256 s, uint256 c, bool stall) private view returns (uint256) {
        address a = _members[i];
        bool own = i + 1 == s;
        return _refund(_m[a], s, c, _paid[s][a] && !own, stall && !own);
    }

    /// @dev Penalty weights: a defaulter's `E − min(E, c)`; everyone else's `E` plus its pro-rata share of the
    ///      penalties. Emits `Defaulted` for each defaulter.
    function _weights(uint256[] memory e, uint256 defaulters, uint256 s, uint256 c)
        private
        returns (uint256[] memory w)
    {
        uint256 n = e.length;
        uint256 penaltyTotal;
        uint256 otherE;
        for (uint256 i; i < n; ++i) {
            uint256 ei = e[i];
            if ((defaulters >> i) & 1 == 1) penaltyTotal += ei < c ? ei : c;
            else otherE += ei;
        }
        if (otherE == 0) penaltyTotal = 0;
        w = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 ei = e[i];
            if ((defaulters >> i) & 1 == 1) {
                uint256 penalty = penaltyTotal == 0 ? 0 : (ei < c ? ei : c);
                w[i] = ei - penalty;
                emit Defaulted(_members[i], s, penalty);
            } else {
                w[i] = penaltyTotal == 0 ? ei : ei + penaltyTotal * ei / otherE;
            }
        }
    }

    /// @dev Security of a non-defaulter that backs no debt at a cancellation in settling round `s`, refunded at
    ///      par. Contributions to rounds after `s` (`paidRounds − (s − 1) − paid_s` of them, `c` each, sitting in
    ///      unsettled pots) are first returned to its security; on a stall a member that has not paid round `s` is
    ///      then covered for it from that security, exactly as `settleRound` would (it is not a defaulter, so
    ///      `sec ≥ c`). Before its payout a member owes nothing, so all of it is refunded; after it, the security
    ///      backing the rounds it still owes, `ceil(σ·(n − paidRounds)·c)`, stays in the pool. Audit R2-22: on a
    ///      Guardian or unjoined cancellation (`stall` false, nobody paid out) the cover only moves `c` between the
    ///      refund and E, so it changes the `netPosition` emitted in `ClaimAssigned` but never a claim; the ledger
    ///      must map claims from the `claim` field, not from E.
    function _refund(Member storage m, uint256 s, uint256 c, bool paidS, bool stall)
        private
        view
        returns (uint256)
    {
        uint256 paidTo = paidS ? s : s - 1; // rounds 1..paidTo are satisfied once later pots are returned
        uint256 sec = uint256(m.sec) + (uint256(m.paidRounds) - paidTo) * c;
        if (!paidS && stall && sec >= c) {
            sec -= c;
            ++paidTo;
        }
        if (!m.received) return sec;
        uint256 keep = _req(m.securityBps, totalRounds - paidTo, c);
        return sec > keep ? sec - keep : 0;
    }

    // ---------------------------------------------------------------- Internal: helpers

    function _checkConfig(RotatingConfig calldata cfg, uint256 n, uint256 sigmas) private view {
        if (
            cfg.circleId == bytes32(0) || n < K.MIN_MEMBERS || n > K.MAX_MEMBERS || cfg.totalRounds != n
                || sigmas != n || cfg.contribution < K.MIN_CONTRIBUTION
                || cfg.contribution > K.MAX_CONTRIBUTION || cfg.contribution % K.CENT != 0
                || cfg.feeBps > K.MAX_ROTATING_FEE_BPS || cfg.roundDuration < K.MIN_ROUND
                || cfg.roundDuration > K.MAX_ROUND || cfg.grace < K.MIN_GRACE
                || cfg.grace >= cfg.roundDuration || cfg.cure < K.MIN_CURE || cfg.cure > K.MAX_CURE
                || cfg.joinDeadline <= block.timestamp
                || cfg.joinDeadline > block.timestamp + K.MAX_JOIN_WINDOW
                || cfg.plannedStart > uint256(cfg.joinDeadline) + K.MAX_START_DELAY
        ) revert BadConfig();
    }

    function _addCollateral(Member storage m, uint256 amount) private {
        m.sec = (uint256(m.sec) + amount).toUint80();
        m.cashIn = (uint256(m.cashIn) + amount).toUint80();
        secTotal += amount;
    }

    /// @dev `ceil(sigma·units·c / BPS)`. Cannot overflow: sigma ≤ 1e4, units ≤ 50, c ≤ 2^64.
    function _req(uint256 sigma, uint256 units, uint256 c) private pure returns (uint256) {
        return (sigma * units * c + K.BPS - 1) / K.BPS;
    }

    /// @dev Security member `a` must keep: `S_k` before its payout, `ceil(σ·(n − paidRounds)·c)` after it.
    ///      Audit R2-05: after its payout, while it has not paid round `nextSettle`, `ceil(σ·(n − paidRounds − 1)·c) +
    ///      c`: a full contribution for that round (the cover a stall cancellation takes from its security) on top of
    ///      the backing of its later rounds, so withdrawing first never takes out more than a cancellation would
    ///      refund (at σ < 100% the plain requirement holds back only σ·c for the open round). The same at σ = 100%.
    function _required(address a, Member storage m, uint256 c) private view returns (uint256) {
        uint256 n = totalRounds;
        if (!m.received) return _req(m.securityBps, n - m.slot, c);
        uint256 owes = n - m.paidRounds;
        if (owes != 0 && !_paid[nextSettle][a]) return _req(m.securityBps, owes - 1, c) + c;
        return _req(m.securityBps, owes, c);
    }

    /// @dev `draw = min(c, max(0, sec − reqAfter))` with `reqAfter = ceil(σ·(remaining − 1)·c)` once paid,
    ///      where `remaining = n − paidRounds` is the rounds this member still owes, or `S_k` before the payout.
    ///      Only called for an unpaid round, so `paidRounds < n`.
    function _draw(Member storage m, uint256 c) private view returns (uint256) {
        return _drawAt(m, m.sec, m.paidRounds, c);
    }

    /// @dev `_draw` with the member's security and paid rounds given as `have` and `paidRounds` (`amountDue`'s
    ///      simulation of `_catchUp`).
    function _drawAt(Member storage m, uint256 have, uint256 paidRounds, uint256 c)
        private
        view
        returns (uint256)
    {
        uint256 n = totalRounds;
        uint256 units = m.received ? n - paidRounds - 1 : n - m.slot;
        uint256 reqAfter = _req(m.securityBps, units, c);
        if (have <= reqAfter) return 0;
        uint256 spare = have - reqAfter;
        return spare < c ? spare : c;
    }

    function _deadline(uint256 round) private view returns (uint256) {
        return uint256(startTime) + round * roundDuration + extension;
    }

    function _graceEnd(uint256 round) private view returns (uint256) {
        return _deadline(round) + grace;
    }

    function _strikeAll(uint256 mask, uint256 round, IMHReputation.Reason reason) private {
        if (mask == 0) return;
        uint256 n = _members.length;
        for (uint256 i; i < n; ++i) {
            if ((mask >> i) & 1 == 1) _strike(_members[i], round, reason);
        }
    }

    function _pull(address from, uint256 amount) private {
        IERC20(address(USDC)).safeTransferFrom(from, address(this), amount);
    }
}
// forge-lint: disable-end(block-timestamp)
