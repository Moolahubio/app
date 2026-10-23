// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MHCircleBase } from "./MHCircleBase.sol";
import { MHCircleConstants as K } from "./MHCircleConstants.sol";
import { IMHCircle } from "./interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "./interfaces/IMHAccumulationCircle.sol";
import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "./interfaces/IMHReputation.sol";
import { IUSDC } from "./interfaces/IUSDC.sol";
import { IVaultV2 } from "./interfaces/IVaultV2.sol";
import { CircleMode, CircleStatus, AccumulationConfig, AccumulationParams } from "./MHCircleTypes.sol";

// Every time gate is days long (rounds ≥ 7 days, grace ≥ 48h): a few seconds of sequencer timestamp drift cannot
// change an outcome that matters.
// forge-lint: disable-start(block-timestamp)

/// @title MHAccumulationCircle
/// @notice Accumulation savings circle (spec §4.2, §4.3, §4.5). Members pay `contribution` each round into a pool
///         that can sit in an allowlisted Morpho Vault V2. At maturity a compliant member (every round paid, no
///         early exit) takes their shares' value plus a share of what delinquent members forfeited, minus a fee
///         on positive earnings only; a delinquent member takes at most their principal valued at maturity (plus
///         the post-maturity yield on it), with no fee.
/// @dev EIP-1167 clone of an immutable implementation (initializers disabled in the base constructor).
///      Accounting uses tracked counters only (`idleAssets`, `vaultShares`, `totalShares`), never `balanceOf`, so
///      donations change nothing. NAV is `idleAssets + vault.previewRedeem(vaultShares)`, read once per
///      transaction. Pool shares convert with a 1e6 virtual-share offset (inflation resistance):
///      `toShares(a) = a·(T+1e6)/(NAV+1)`, `toAssets(s) = s·(NAV+1)/(T+1e6)`.
///      Rounding (spec §4.3): mint floor, burn ceil, payout and fee floor, bonus and unwind floor, dust to
///      residual. Funds move into the vault only through the permissionless `deployIdle` (exact approval) and out
///      only through `withdraw` of an exact shortfall or `redeem` of a bounded chunk; `max*` is never called
///      (Vault V2 returns 0) and vault reverts bubble up, with in-kind paths for illiquidity.
///      No admin, owner, Guardian, operator or treasury path to member principal. The Guardian can (audit 2 R2-10,
///      the full list): switch yield off for good and move vault shares back to idle USDC inside the circle
///      (`emergencyExit`; `forceExit`, where it picks the adapter, the market data and the amount, and the vault's
///      force-deallocation penalty, at most 2% of what is freed, is borne by the circle), cancel into claims with
///      no fee (Active: by shares, no delinquent cap; Matured: the finalize outcomes), and extend deadlines (30 days
///      per circle); through the registry it can delist the vault, which pauses deposits (audit 2 R2-01). The
///      treasury receives only fees on earnings, residual after every member bucket is zero, and donations. Every
///      loop is over the members (≤ 50); nothing loops over rounds.
contract MHAccumulationCircle is MHCircleBase, IMHAccumulationCircle {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Storage layout of a member: two slots. Shares fit 128 bits (≈1e12 shares per USDC); amounts fit
    ///      88 bits (3e20 USDC). Every write is range-checked.
    struct Member {
        // slot 0
        uint128 acc;
        uint128 claim;
        // slot 1
        uint88 principal;
        uint88 cashOut;
        uint32 paidRounds;
        uint16 exitRound;
        uint8 slot;
        bool joined;
        bool exited;
        bool settled;
    }

    /// @dev A member's settlement valued at one NAV: `shares` leave the pool worth `gross`, of which `fee` goes to
    ///      the treasury; `bonus` comes out of the forfeit pool.
    struct Settlement {
        uint256 shares;
        uint256 bonus;
        uint256 gross;
        uint256 fee;
        bool compliant;
    }

    // ---------------------------------------------------------------- Config (written once in `initialize`)

    /// @inheritdoc IMHCircle
    bytes32 public circleId;
    /// @inheritdoc IMHCircle
    bytes32 public termsHash;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public contribution;
    /// @inheritdoc IMHAccumulationCircle
    address public vault;
    /// @inheritdoc IMHAccumulationCircle
    uint16 public feeBps;
    /// @inheritdoc IMHAccumulationCircle
    bool public lockUntilMaturity;

    // ---------------------------------------------------------------- Lifecycle

    /// @inheritdoc IMHAccumulationCircle
    CircleStatus public status;
    /// @inheritdoc IMHAccumulationCircle
    uint8 public joinedCount;
    /// @inheritdoc IMHAccumulationCircle
    uint8 public settledCount;
    /// @inheritdoc IMHAccumulationCircle
    bool public yieldOff;

    /// @inheritdoc IMHAccumulationCircle
    uint64 public roundDuration;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public grace;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public cure;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public joinDeadline;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public plannedStart;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public startTime;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public extension;
    /// @inheritdoc IMHAccumulationCircle
    uint32 public totalRounds;
    /// @inheritdoc IMHAccumulationCircle
    uint64 public lastLive;

    // ---------------------------------------------------------------- Pool (tracked counters)

    /// @inheritdoc IMHAccumulationCircle
    uint256 public idleAssets;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public vaultShares;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public totalShares;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public accTotal;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public claimTotal;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public forfeitShares;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public forfeitSnap;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public compliantSnap;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public bonusBase;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public residualShares;
    /// @inheritdoc IMHAccumulationCircle
    mapping(uint256 round => bool flagged) public roundFlagged;

    /// @inheritdoc IMHAccumulationCircle
    mapping(address account => uint256 shares) public owedShares;
    /// @inheritdoc IMHAccumulationCircle
    uint256 public owedSharesTotal;

    address[] private _members;
    mapping(address account => Member state) private _m;
    /// @dev Paid rounds per member as a bitmap: word `round >> 8`, bit `round & 255`.
    mapping(address member => mapping(uint256 word => uint256 bits)) private _paidBits;
    /// @dev Pool shares each member forfeited on `exitEarly` (audit R1-09: returned if nobody is left at maturity).
    mapping(address member => uint256 shares) private _exitForfeit;

    /// @param usdc USDC on this chain.
    /// @param registry The circle registry (Guardian, treasury and the vault allowlist are read from it).
    /// @param reputation The strike register.
    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation)
        MHCircleBase(usdc, registry, reputation)
    { }

    // ---------------------------------------------------------------- Initialization

    /// @inheritdoc IMHCircle
    function circleMode() external pure returns (CircleMode) {
        return CircleMode.Accumulation;
    }

    /// @inheritdoc IMHAccumulationCircle
    function initialize(AccumulationParams calldata p) external initializer {
        AccumulationConfig calldata cfg = p.config;
        uint256 n = p.members.length;
        _checkConfig(cfg, n);
        // Audit 2 R1-17: only a factory clone (registered as a reporter before `initialize`) can become a circle;
        // any other clone could never record a strike, so its strike paths would revert and trap funds.
        if (!REPUTATION.isReporter(address(this))) revert BadConfig();
        for (uint256 i; i < n; ++i) {
            address a = p.members[i];
            if (a == address(0)) revert BadConfig();
            Member storage m = _m[a];
            if (m.slot != 0) revert BadConfig(); // duplicate member
            // forge-lint: disable-next-line(unsafe-typecast)
            m.slot = uint8(i + 1); // i < MAX_MEMBERS = 50
            _members.push(a);
        }
        circleId = cfg.circleId;
        contribution = cfg.contribution;
        vault = cfg.vault;
        feeBps = cfg.feeBps;
        lockUntilMaturity = cfg.lockUntilMaturity;
        roundDuration = cfg.roundDuration;
        grace = cfg.grace;
        cure = cfg.cure;
        joinDeadline = cfg.joinDeadline;
        plannedStart = cfg.plannedStart;
        totalRounds = cfg.totalRounds;
        termsHash = _accumulationTermsHash(cfg, p.members);
    }

    // ---------------------------------------------------------------- Member actions

    /// @inheritdoc IMHAccumulationCircle
    function join(bytes32 terms, uint256 collateral) external nonReentrant {
        if (status != CircleStatus.Pending) revert NotPending();
        if (block.timestamp > joinDeadline) revert JoinClosed();
        Member storage m = _m[msg.sender];
        if (m.slot == 0) revert NotMember();
        if (m.joined) revert AlreadyJoined();
        if (terms != termsHash || collateral != 0) revert BadTerms();

        m.joined = true;
        uint8 joined = joinedCount + 1;
        joinedCount = joined;
        emit Joined(msg.sender);
        if (joined == _members.length) {
            uint64 start = block.timestamp > plannedStart ? uint64(block.timestamp) : plannedStart;
            startTime = start;
            lastLive = uint64(block.timestamp);
            status = CircleStatus.Active;
            // Audit R1-12 / audit 2 R2-01: nothing is latched here; `deployIdle` re-checks the vault in the
            // registry (`revalidateVault`, closing review) before every deposit.
            emit Activated(start);
        }
    }

    /// @inheritdoc IMHAccumulationCircle
    function contribute(uint256 round, uint256 maxPull) external nonReentrant returns (uint256 shares) {
        if (status != CircleStatus.Active) revert NotActive();
        Member storage m = _m[msg.sender];
        if (m.slot == 0) revert NotMember();
        if (m.exited) revert AlreadySettled();
        if (!_payable(round)) revert BadRound();
        (uint256 word, uint256 bit) = _bit(round);
        uint256 bits = _paidBits[msg.sender][word];
        if (bits & bit != 0) revert AlreadyPaid();
        uint256 c = contribution;
        if (c > maxPull) revert ExceedsMaxPull();

        uint256 total = totalShares;
        shares = _toShares(c, _liveNav(), total);
        _paidBits[msg.sender][word] = bits | bit;
        m.paidRounds += 1;
        m.principal = (uint256(m.principal) + c).toUint88();
        m.acc = (uint256(m.acc) + shares).toUint128();
        accTotal += shares;
        totalShares = total + shares;
        idleAssets += c;
        emit Contributed(msg.sender, round, c, 0, false);
        IERC20(address(USDC)).safeTransferFrom(msg.sender, address(this), c);
    }

    /// @inheritdoc IMHAccumulationCircle
    function exitEarly() external nonReentrant returns (uint256 amount) {
        if (lockUntilMaturity) revert Locked();
        if (status != CircleStatus.Active) revert NotActive();
        Member storage m = _m[msg.sender];
        if (m.slot == 0) revert NotMember();
        if (m.exited) revert AlreadySettled();

        uint256 nav_ = _liveNav();
        uint256 total = totalShares;
        uint256 acc = m.acc;
        uint256 principal = m.principal;
        uint256 value = _toAssets(acc, nav_, total);
        amount = value < principal ? value : principal;
        // amount ≤ floor(acc·(NAV+1)/(T+1e6)), so the ceil burn never exceeds acc.
        uint256 burn = Math.mulDiv(amount, total + K.VIRTUAL_SHARES, nav_ + 1, Math.Rounding.Ceil);
        uint256 forfeited = acc - burn;

        m.acc = 0;
        m.exited = true;
        m.settled = true;
        // Rounds before `exitRound` are owed (`flagRound`). Audit 2 R2-07: `currentRound` stops at `totalRounds`, so
        // after the last deadline the last round is owed too and skipping it then exiting cannot dodge its strike.
        uint256 r = currentRound();
        if (block.timestamp > _deadline(r)) ++r;
        // forge-lint: disable-next-line(unsafe-typecast)
        m.exitRound = uint16(r); // ≤ MAX_ROUNDS + 1 = 521
        m.cashOut = (uint256(m.cashOut) + amount).toUint88();
        accTotal -= acc;
        forfeitShares += forfeited;
        if (forfeited != 0) _exitForfeit[msg.sender] = forfeited;
        totalShares = total - burn;
        settledCount += 1;
        emit ExitedEarly(msg.sender, principal, amount, forfeited);
        _takeCash(amount, burn, total, nav_);
        _pay(msg.sender, amount);
    }

    /// @inheritdoc IMHAccumulationCircle
    function claim() external nonReentrant returns (uint256 amount) {
        Member storage m = _m[msg.sender];
        uint256 shares = m.claim;
        if (shares == 0) revert NothingToClaim();
        uint256 total = totalShares;
        uint256 nav_ = _liveNav();
        amount = _toAssets(shares, nav_, total);

        m.claim = 0;
        m.cashOut = (uint256(m.cashOut) + amount).toUint88();
        claimTotal -= shares;
        totalShares = total - shares;
        emit Claimed(msg.sender, amount);
        _takeCash(amount, shares, total, nav_);
        _pay(msg.sender, amount);
    }

    /// @inheritdoc IMHAccumulationCircle
    function claimInKind() external nonReentrant returns (uint256 assets, uint256 vShares) {
        Member storage m = _m[msg.sender];
        uint256 shares = m.claim;
        if (shares == 0) revert NothingToClaim();
        uint256 total = totalShares;
        (assets, vShares) = _inKind(shares, total);

        m.claim = 0;
        m.cashOut = (uint256(m.cashOut) + assets).toUint88();
        claimTotal -= shares;
        totalShares = total - shares;
        emit ClaimedInKind(msg.sender, assets, vShares);
        _pay(msg.sender, assets);
        _sendShares(msg.sender, vShares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function claimOwedShares() external nonReentrant returns (uint256 shares) {
        shares = owedShares[msg.sender];
        if (shares == 0) revert NothingOwed();
        if (USDC.isBlacklisted(msg.sender)) revert Blacklisted();
        owedShares[msg.sender] = 0;
        owedSharesTotal -= shares;
        emit OwedSharesClaimed(msg.sender, shares);
        IERC20(vault).safeTransfer(msg.sender, shares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function settleMemberInKind(address member) external nonReentrant {
        if (msg.sender != member) revert NotMember();
        (Member storage m, uint256 nav_, uint256 total) = _settleable(member);
        Settlement memory s = _value(m, nav_, total);
        (uint256 assets, uint256 vShares) = _inKind(s.shares, total);
        uint256 feeAssets;
        uint256 feeShares;
        if (s.fee != 0) {
            // gross > fee > 0. The fee is taken pro rata from both parts, rounded down (against the treasury).
            feeAssets = assets * s.fee / s.gross;
            feeShares = vShares * s.fee / s.gross;
        }
        assets -= feeAssets;
        vShares -= feeShares;

        emit MemberSettledInKind(member, m.principal, assets, vShares, feeAssets, feeShares);
        _close(m, s, total, assets);
        _pay(member, assets);
        _sendShares(member, vShares);
        if (s.fee != 0) {
            address treasury = REGISTRY.treasury();
            _pay(treasury, feeAssets);
            _sendShares(treasury, feeShares);
        }
    }

    // ---------------------------------------------------------------- Permissionless transitions

    /// @inheritdoc IMHAccumulationCircle
    function deployIdle() external nonReentrant {
        if (status != CircleStatus.Active) revert NotActive();
        address v = vault;
        if (v == address(0) || yieldOff) revert NoYield();
        // Audit 2 R1-09: never into a vault the registry no longer allowlists or considers safe. Audit 2 R2-01: and
        // nothing is latched in the circle; only the Guardian switches yield off permanently. Closing review: a
        // failed live check delists the vault in the registry (`revalidateVault`), and this call then returns
        // without depositing so the delisting persists. Deposits resume only after Gov's reviewed `allowVault`, never
        // because the vault's curator restored the checked state (e.g. `increaseTimelock`) on its own.
        (bool delisted, bool safe) = _recheck(v);
        if (delisted) return;
        if (!safe) revert VaultUnsafe();
        uint256 amount = idleAssets;
        if (amount < K.MIN_DEPLOY) revert NothingToDeploy();

        idleAssets = 0;
        lastLive = uint64(block.timestamp);
        IERC20(address(USDC)).forceApprove(v, amount);
        uint256 shares = IVaultV2(v).deposit(amount, address(this));
        vaultShares += shares;
        emit IdleDeployed(amount, shares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function flagRound(uint256 round) external nonReentrant {
        CircleStatus st = status;
        if (st != CircleStatus.Active && st != CircleStatus.Matured && st != CircleStatus.Closed) {
            revert NotActive();
        }
        // Audit 2 R1-08: the cure period after grace is the Guardian's window to extend (which reopens an unflagged
        // round) after an outage that spanned the grace end, before anyone can flag.
        if (
            round == 0 || round > totalRounds || block.timestamp <= _graceEnd(round) + cure
                || roundFlagged[round]
        ) revert BadRound();
        _requireUsdcLive();
        // Audit R1-03: `contribute` values shares, so while the vault cannot value them nobody can pay; no strike
        // may be recorded then either (it reverts with the vault's error until the vault is repaired).
        if (st == CircleStatus.Active) _liveNav();

        roundFlagged[round] = true;
        (uint256 word, uint256 bit) = _bit(round);
        uint256 n = _members.length;
        uint256 missed;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            if (_paidBits[a][word] & bit != 0) continue;
            Member storage m = _m[a];
            if (m.exited && round >= m.exitRound) continue;
            // forge-lint: disable-next-line(incorrect-shift)
            missed |= 1 << i; // bit i = member index i
            ++count;
        }
        emit RoundFlagged(round, count);
        for (uint256 i; i < n; ++i) {
            if ((missed >> i) & 1 == 1) _strike(_members[i], round, IMHReputation.Reason.MISSED);
        }
    }

    /// @inheritdoc IMHAccumulationCircle
    function finalize() external nonReentrant {
        if (status != CircleStatus.Active) revert NotActive();
        // Audit 2 R1-08: after the last round's grace + cure, as for `flagRound`. Audit 2 R2-06: or once every member
        // has exited (nobody is left to pay, so nothing can change), so the exits' forfeits return without waiting
        // for the end of the schedule.
        if (block.timestamp <= _graceEnd(totalRounds) + cure && settledCount != _members.length) {
            revert NotMatured();
        }
        _requireUsdcLive();

        uint256 nav_ = _liveNav();
        uint256 total = totalShares;
        uint256 rounds = totalRounds;
        uint256 n = _members.length;
        uint256 compliantAcc;
        uint256 remainingAcc;
        for (uint256 i; i < n; ++i) {
            Member storage m = _m[_members[i]];
            if (m.exited) continue;
            uint256 acc = m.acc;
            remainingAcc += acc;
            if (m.paidRounds == rounds) compliantAcc += acc;
        }

        uint256 forfeit = forfeitShares;
        // Delinquent members are capped at principal only when someone can receive the forfeit; otherwise every
        // member keeps its full value (the all-delinquent rule).
        if (compliantAcc != 0) {
            uint256 capped;
            for (uint256 i; i < n; ++i) {
                address a = _members[i];
                Member storage m = _m[a];
                if (m.exited || m.paidRounds == rounds) continue;
                uint256 acc = m.acc;
                uint256 principal = m.principal;
                if (_toAssets(acc, nav_, total) <= principal) continue;
                // value > principal implies toShares(principal) < acc.
                uint256 keep = _toShares(principal, nav_, total);
                m.acc = keep.toUint128();
                capped += acc - keep;
                emit Forfeited(a, acc - keep);
            }
            accTotal -= capped;
            forfeit += capped;
            remainingAcc = compliantAcc;
        }

        compliantSnap = compliantAcc;
        bonusBase = remainingAcc;
        uint256 feeShares;
        if (remainingAcc == 0 && forfeit != 0) {
            // Audit R1-09: nobody is left to share the forfeit pool (every member exited, or every remaining member
            // holds nothing; then nothing was capped, so the pool is exactly the exits' forfeits). Each exited member
            // gets its own forfeited shares back as a claim, less the fee on those earnings; the fee is paid now.
            uint256 claims;
            (claims, feeShares) = _returnForfeits(n, feeBps);
            claimTotal += claims;
            total -= feeShares;
            totalShares = total;
            forfeit = 0;
        }
        forfeitShares = forfeit;
        forfeitSnap = forfeit;
        if (settledCount == n) {
            status = CircleStatus.Closed;
            emit Finalized(nav_, forfeit, compliantAcc);
            emit CircleClosed();
        } else {
            status = CircleStatus.Matured;
            emit Finalized(nav_, forfeit, compliantAcc);
        }
        if (feeShares != 0) _payFeeInKind(feeShares, total + feeShares);
    }

    /// @dev Audit R1-09 (finalize) and R2-02 (cancellation): assigns each exited member's forfeited shares back to
    ///      it as a claim, less `floor(forfeited·fee/BPS)` (the fee on those earnings; 0 on a cancellation). Returns
    ///      the claims and the fee shares; the caller adds the claims to `claimTotal`.
    function _returnForfeits(uint256 n, uint256 fee) private returns (uint256 claims, uint256 feeShares) {
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            uint256 f = _exitForfeit[a];
            if (f == 0) continue;
            uint256 cut = f * fee / K.BPS;
            uint256 shares = f - cut;
            _m[a].claim = shares.toUint128();
            claims += shares;
            feeShares += cut;
            emit ClaimAssigned(a, f, shares);
        }
    }

    /// @dev Removes `shares` pool shares (out of `total` before removal) and pays their pro-rata idle USDC and vault
    ///      shares to the treasury as a fee.
    function _payFeeInKind(uint256 shares, uint256 total) private {
        (uint256 assets, uint256 vShares) = _inKind(shares, total);
        address treasury = REGISTRY.treasury();
        emit FeePaidInKind(treasury, assets, vShares);
        _pay(treasury, assets);
        _sendShares(treasury, vShares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function settleMember(address member) external nonReentrant {
        (Member storage m, uint256 nav_, uint256 total) = _settleable(member);
        Settlement memory s = _value(m, nav_, total);
        uint256 net = s.gross - s.fee;

        emit MemberSettled(member, m.principal, s.gross, s.fee, s.compliant);
        _close(m, s, total, net);
        _takeCash(s.gross, s.shares, total, nav_);
        _pay(member, net);
        if (s.fee != 0) _pay(REGISTRY.treasury(), s.fee);
    }

    /// @inheritdoc IMHAccumulationCircle
    function pullFromVault(uint256 shares) external nonReentrant {
        // Audit 2 R1-09 / R2-01: anyone, once the Guardian switched yield off, or while the registry does not consider
        // the vault safe (keepers protect every circle on a delisted vault without the Guardian). Closing review: a
        // vault that fails the live check is delisted here (`revalidateVault`), so the pull cannot be undone by
        // the curator restoring the check; only Gov's `allowVault` re-enables deposits.
        if (!yieldOff) {
            (, bool safe) = _recheck(vault);
            if (safe) revert YieldOn();
        }
        uint256 held = vaultShares;
        if (shares > held) shares = held;
        if (shares == 0) revert ZeroAmount();
        uint256 assets = _redeem(shares);
        emit PulledFromVault(msg.sender, shares, assets);
    }

    /// @inheritdoc IMHAccumulationCircle
    function cancelUnjoined() external nonReentrant {
        if (status != CircleStatus.Pending) revert NotPending();
        if (block.timestamp <= joinDeadline) revert NotStalled();
        _requireUsdcLive();
        status = CircleStatus.Cancelled;
        emit CircleCancelled(CancelReason.Unjoined, 0, 0);
    }

    /// @inheritdoc IMHAccumulationCircle
    function sweepDonations() external nonReentrant {
        uint256 held = idleAssets + owedTotal;
        uint256 balance = USDC.balanceOf(address(this));
        uint256 assets = balance > held ? balance - held : 0;
        uint256 shares;
        address v = vault;
        if (v != address(0)) {
            uint256 vBalance = IERC20(v).balanceOf(address(this));
            uint256 vHeld = vaultShares + owedSharesTotal;
            if (vBalance > vHeld) shares = vBalance - vHeld;
        }
        if (assets == 0 && shares == 0) revert NothingToClaim();
        address treasury = REGISTRY.treasury();
        emit DonationsSwept(treasury, assets, shares);
        _pay(treasury, assets);
        _sendShares(treasury, shares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function sweepResidual() external nonReentrant {
        CircleStatus st = status;
        if ((st != CircleStatus.Closed && st != CircleStatus.Cancelled) || accTotal != 0 || claimTotal != 0) {
            revert NotEnded();
        }
        // Every member bucket is zero (and so is the forfeit pool), so the treasury is the only claimant left:
        // residual shares plus the virtual-share dust the last leaver could not take.
        uint256 assets = idleAssets;
        uint256 shares = vaultShares;
        if (assets == 0 && shares == 0) revert NothingToClaim();
        idleAssets = 0;
        vaultShares = 0;
        residualShares = 0;
        totalShares = 0;
        address treasury = REGISTRY.treasury();
        emit ResidualSwept(treasury, assets, shares);
        _pay(treasury, assets);
        _sendShares(treasury, shares);
    }

    // ---------------------------------------------------------------- Guardian

    /// @inheritdoc IMHAccumulationCircle
    function emergencyExit(uint256 maxVaultShares) external nonReentrant {
        _onlyGuardian();
        if (vault == address(0)) revert NoYield();
        if (!yieldOff) _disableYield();
        uint256 held = vaultShares;
        uint256 shares = maxVaultShares < held ? maxVaultShares : held;
        uint256 assets = shares == 0 ? 0 : _redeem(shares);
        emit EmergencyExited(shares, assets);
    }

    /// @inheritdoc IMHAccumulationCircle
    function forceExit(address adapter, bytes calldata data, uint256 assets) external nonReentrant {
        _onlyGuardian();
        IVaultV2 v = IVaultV2(vault);
        if (address(v) == address(0)) revert NoYield();
        uint256 held = vaultShares;
        // Bounded by the circle's own position, so the penalty (Vault V2 caps it at 2%) is at most that share of
        // what the circle holds, over any number of calls.
        if (assets == 0 || assets > v.previewRedeem(held) || !v.isAdapter(adapter)) revert BadForceExit();
        if (!yieldOff) _disableYield();
        // Audit 2 R1-01: frees `assets` from `adapter`'s market into the vault's idle USDC (no allocator, liquidity
        // adapter or caller allowance involved; the penalty is taken from the circle's shares) and, in the same
        // call, redeems at most that much, so the exit never deallocates through the liquidity adapter and no
        // allocator can move the freed USDC back in between.
        uint256 penalty = v.forceDeallocate(adapter, data, assets, address(this));
        held -= penalty;
        // At most `assets` leaves the vault, all of it from the idle USDC just freed: every remaining share when they
        // are worth no more, else exactly `assets`.
        uint256 burned = held;
        uint256 received;
        if (v.previewRedeem(held) <= assets) {
            received = v.redeem(held, address(this), address(this));
        } else {
            received = assets;
            burned = v.withdraw(assets, address(this), address(this));
        }
        vaultShares = held - burned;
        idleAssets += received;
        emit ForceExited(adapter, assets, penalty, burned, received);
    }

    /// @inheritdoc IMHAccumulationCircle
    function guardianCancel() external nonReentrant {
        _onlyGuardian();
        _cancel(CancelReason.Guardian);
    }

    /// @inheritdoc IMHAccumulationCircle
    function cancelExpired() external nonReentrant {
        // Audit R2-09 (spec §4.7 invariant 7): the permissionless twin of `guardianCancel`, the one exit that reads
        // no NAV, for a vault that cannot value its shares and an unavailable Guardian. Audit 2 R1-05/R1-06/R1-07:
        // it opens `EXPIRY_DELAY` after the vault last valued the circle's shares (not after the schedule ends), and
        // only while the vault still cannot value them and USDC is live. Whenever the NAV is readable, `finalize`
        // and the settlements (with the delinquent cap, compliant-only forfeits and the fee) are the only way out.
        CircleStatus st = status;
        if (st != CircleStatus.Active && st != CircleStatus.Matured) revert NotActive();
        if (block.timestamp <= uint256(lastLive) + K.EXPIRY_DELAY) revert NotStalled();
        _requireUsdcLive();
        if (_navReadable()) revert NavReadable();
        _cancel(CancelReason.Expired);
    }

    /// @dev Cancels an Active or Matured circle into claims, with no fee and no NAV read. Active: the forfeit pool
    ///      is shared by shares. Matured (audit R1-03): the finalize outcomes stand. Delinquent members keep their
    ///      capped shares, and exactly the members `settleMember` would give a bonus get it, from the same snapshot.
    function _cancel(CancelReason reason) private {
        CircleStatus st = status;
        if (st != CircleStatus.Active && st != CircleStatus.Matured) revert NotActive();
        uint256 sumAcc = accTotal;
        uint256 forfeit = forfeitShares;
        bool matured = st == CircleStatus.Matured;
        uint256 pool = matured ? forfeitSnap : forfeit;
        uint256 base = matured ? bonusBase : sumAcc;
        uint256 n = _members.length;
        uint256 assigned;
        if (!matured && base == 0) {
            // Audit R2-02: nobody holds pool shares to share the forfeit pool (every member exited, or the members
            // left hold nothing), which in an Active circle is exactly the exits' forfeits. As at `finalize`
            // (R1-09), each exited member gets its own forfeited shares back as a claim, here with no fee. (A
            // Matured circle with `bonusBase == 0` already returned them at finalize: its `forfeitSnap` is 0.)
            (assigned,) = _returnForfeits(n, 0);
        } else {
            bool everyone = !matured || compliantSnap == 0;
            for (uint256 i; i < n; ++i) {
                address a = _members[i];
                Member storage m = _m[a];
                uint256 acc = m.acc;
                if (acc == 0) continue; // base > 0 whenever some acc > 0 is eligible
                uint256 bonus = everyone || m.paidRounds == totalRounds ? Math.mulDiv(pool, acc, base) : 0;
                uint256 shares = acc + bonus;
                m.acc = 0;
                m.claim = shares.toUint128();
                assigned += bonus;
                emit ClaimAssigned(a, acc, shares);
            }
        }
        uint256 dust = forfeit - assigned;
        uint256 claims = sumAcc + assigned;
        residualShares += dust;
        // Added, not set: a Matured circle may already hold claims (exit forfeits returned at finalize, R1-09).
        claimTotal += claims;
        accTotal = 0;
        forfeitShares = 0;
        status = CircleStatus.Cancelled;
        emit CircleCancelled(reason, claims, dust);
    }

    /// @inheritdoc IMHAccumulationCircle
    function extendDeadline(uint256 by) external nonReentrant {
        _onlyGuardian();
        if (status != CircleStatus.Active) revert NotActive();
        if (by == 0 || by > K.MAX_EXTENSION_PER_CALL) revert ExtensionLimit();
        uint256 total = extension + by;
        if (total > K.MAX_EXTENSION_TOTAL) revert ExtensionLimit();
        // forge-lint: disable-next-line(unsafe-typecast)
        extension = uint64(total); // ≤ 30 days
        emit DeadlineExtended(by, total);
    }

    // ---------------------------------------------------------------- Views

    /// @inheritdoc IMHAccumulationCircle
    function nav() external view returns (uint256) {
        return _nav();
    }

    /// @inheritdoc IMHAccumulationCircle
    function memberValue(address member) external view returns (uint256) {
        return _toAssets(_m[member].acc, _nav(), totalShares);
    }

    /// @inheritdoc IMHAccumulationCircle
    function paid(uint256 round, address member) external view returns (bool) {
        (uint256 word, uint256 bit) = _bit(round);
        return _paidBits[member][word] & bit != 0;
    }

    /// @inheritdoc IMHAccumulationCircle
    function members() external view returns (address[] memory) {
        return _members;
    }

    /// @inheritdoc IMHAccumulationCircle
    function slotOf(address account) external view returns (uint256) {
        return _m[account].slot;
    }

    /// @inheritdoc IMHAccumulationCircle
    function memberState(address account) external view returns (MemberState memory st) {
        Member storage m = _m[account];
        st.principal = m.principal;
        st.cashOut = m.cashOut;
        st.accShares = m.acc;
        st.claimShares = m.claim;
        st.paidRounds = m.paidRounds;
        st.exitRound = m.exitRound;
        st.slot = m.slot;
        st.joined = m.joined;
        st.exited = m.exited;
        st.settled = m.settled;
        st.compliant = m.slot != 0 && !m.exited && m.paidRounds == totalRounds;
    }

    /// @inheritdoc IMHAccumulationCircle
    function currentRound() public view returns (uint256) {
        uint256 start = startTime;
        if (start == 0 || block.timestamp < start) return 0;
        uint256 r = (block.timestamp - start) / roundDuration + 1;
        uint256 n = totalRounds;
        return r > n ? n : r;
    }

    /// @inheritdoc IMHAccumulationCircle
    function roundDeadline(uint256 round) external view returns (uint256) {
        if (startTime == 0) return 0;
        return _deadline(round);
    }

    /// @inheritdoc IMHAccumulationCircle
    function amountDue(address member, uint256 round) external view returns (uint256) {
        Member storage m = _m[member];
        if (status != CircleStatus.Active || m.slot == 0 || m.exited || !_payable(round)) return 0;
        (uint256 word, uint256 bit) = _bit(round);
        if (_paidBits[member][word] & bit != 0) return 0;
        return contribution;
    }

    // ---------------------------------------------------------------- Internal: settlement

    /// @dev Common checks of `settleMember` / `settleMemberInKind`, plus this transaction's NAV and share supply.
    function _settleable(address member) private returns (Member storage m, uint256 nav_, uint256 total) {
        if (status != CircleStatus.Matured) {
            revert NotMatured();
        }
        m = _m[member];
        if (m.slot == 0) revert NotMember();
        if (m.settled) revert AlreadySettled();
        nav_ = _liveNav();
        total = totalShares;
    }

    /// @dev Values a member's settlement at maturity (spec §4.5, amended in audit round 1):
    ///      - compliant: `shares = acc + floor(forfeitSnap·acc/compliantSnap)`, `gross = toAssets(shares)` (floor),
    ///        `fee = floor(max(0, gross − principal)·feeBps)`;
    ///      - nobody compliant: the same split over every remaining member (`bonusBase`), uncapped, and the same
    ///        fee on earnings (audit R1-10: universal delinquency does not waive it);
    ///      - delinquent: `gross = toAssets(acc)`, no fee. `finalize` already capped `acc` at `toShares(principal)`
    ///        once; the retained shares keep earning after maturity like every other bucket (audit R1-11), so
    ///        nothing is re-capped here and no leftover goes to residual.
    function _value(Member storage m, uint256 nav_, uint256 total)
        private
        view
        returns (Settlement memory s)
    {
        uint256 acc = m.acc;
        s.compliant = m.paidRounds == totalRounds;
        s.shares = acc;
        bool shares_ = s.compliant || compliantSnap == 0;
        if (shares_) {
            uint256 base = bonusBase;
            if (base != 0) s.bonus = Math.mulDiv(forfeitSnap, acc, base);
            s.shares = acc + s.bonus;
        }
        s.gross = _toAssets(s.shares, nav_, total);
        uint256 principal = m.principal;
        if (shares_ && s.gross > principal) s.fee = (s.gross - principal) * feeBps / K.BPS;
    }

    /// @dev Effects of settling `member`: its shares leave the pool and the bonus leaves the forfeit pool. The last
    ///      settlement closes the circle and moves forfeit dust to residual.
    function _close(Member storage m, Settlement memory s, uint256 total, uint256 cash) private {
        accTotal -= m.acc;
        m.acc = 0;
        m.settled = true;
        m.cashOut = (uint256(m.cashOut) + cash).toUint88();
        uint256 forfeit = forfeitShares - s.bonus;
        totalShares = total - s.shares;
        uint8 settled = settledCount + 1;
        settledCount = settled;
        if (settled == _members.length) {
            residualShares += forfeit;
            forfeit = 0;
            status = CircleStatus.Closed;
            emit CircleClosed();
        }
        forfeitShares = forfeit;
    }

    /// @dev The pro-rata (floor) part of idle USDC and vault shares for `shares` pool shares, removed from the
    ///      tracked counters. Uses `T + VIRTUAL_SHARES` as the denominator, consistent with `toAssets`, so an
    ///      in-kind payout is never worth more than its cash equivalent.
    function _inKind(uint256 shares, uint256 total) private returns (uint256 assets, uint256 vShares) {
        uint256 denom = total + K.VIRTUAL_SHARES;
        uint256 idle = idleAssets;
        uint256 held = vaultShares;
        assets = Math.mulDiv(idle, shares, denom);
        vShares = Math.mulDiv(held, shares, denom);
        idleAssets = idle - assets;
        vaultShares = held - vShares;
    }

    // ---------------------------------------------------------------- Internal: vault

    /// @dev `idleAssets + vault.previewRedeem(vaultShares)`. One vault read; callers read it once per transaction.
    function _nav() private view returns (uint256) {
        uint256 held = vaultShares;
        if (held == 0) return idleAssets;
        return idleAssets + IVaultV2(vault).previewRedeem(held);
    }

    /// @dev `_nav()` in a state-changing call, also recording that the vault valued the circle's shares now
    ///      (audit 2 R1-07: `cancelExpired` opens `EXPIRY_DELAY` after the last such read).
    function _liveNav() private returns (uint256 nav_) {
        nav_ = _nav();
        lastLive = uint64(block.timestamp);
    }

    /// @dev Whether the vault can value the circle's shares now: a static call of `previewRedeem(vaultShares)`
    ///      with a fixed `NAV_PROBE_GAS` that must return a word (always true with no vault shares). Reverts
    ///      `InsufficientGas` unless the call is sure to get all of it (63/64 rule), so a caller can never make a
    ///      healthy vault look broken by sending too little gas. Uses only scratch space.
    function _navReadable() private view returns (bool ok) {
        uint256 held = vaultShares;
        if (held == 0) return true;
        if (gasleft() < K.NAV_PROBE_MIN_GAS) revert InsufficientGas();
        address v = vault;
        bytes4 selector = IVaultV2.previewRedeem.selector;
        uint256 probeGas = K.NAV_PROBE_GAS;
        assembly ("memory-safe") {
            // `previewRedeem(held)` built in scratch space (0x00-0x23); the one-word result lands over it, unread.
            mstore(0x00, selector)
            mstore(0x04, held)
            ok := staticcall(probeGas, v, 0x00, 0x24, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
        }
    }

    /// @dev Removes `x` USDC, the value at `nav_` of `shares` pool shares out of `total`, for a cash exit. Audit
    ///      R2-06: the idle part is pro rata, `floor(idle·shares/(total+1e6))` like the in-kind paths, and the rest is
    ///      withdrawn from the vault (spec `_ensureIdle`: exactly that amount; a vault revert bubbles up and the member
    ///      uses the in-kind path). So cash exits never drain the pooled idle USDC ahead of in-kind exits, and the
    ///      order of exits cannot shift a later realised loss. The vault part is capped at the vault's value
    ///      `nav_ − idle` (rounding), and `x ≤ nav_` keeps the idle part within `idle`. `max*` is never called.
    function _takeCash(uint256 x, uint256 shares, uint256 total, uint256 nav_) private {
        uint256 idle = idleAssets;
        uint256 fromIdle = x;
        if (vaultShares != 0) {
            fromIdle = Math.min(Math.mulDiv(idle, shares, total + K.VIRTUAL_SHARES), x);
            uint256 inVault = nav_ - idle;
            if (x - fromIdle > inVault) fromIdle = x - inVault;
        }
        idleAssets = idle - fromIdle;
        if (x != fromIdle) {
            vaultShares -= IVaultV2(vault).withdraw(x - fromIdle, address(this), address(this));
        }
    }

    /// @dev Redeems exactly `shares` vault shares into idle USDC (a bounded chunk; reverts bubble up).
    function _redeem(uint256 shares) private returns (uint256 assets) {
        vaultShares -= shares;
        assets = IVaultV2(vault).redeem(shares, address(this), address(this));
        idleAssets += assets;
    }

    /// @dev Transfers vault shares (in kind). Vault V2 share transfers do not touch USDC, and the allowlisted
    ///      vaults have their share gates at zero and abdicated. Audit R1-14: shares bound for a USDC-blacklisted
    ///      address are queued in `owedShares` instead, so the circle never hands a sanctioned address something it
    ///      can redeem to a clean one (the vault is the USDC sender on `redeem`).
    function _sendShares(address to, uint256 shares) private {
        if (shares == 0) return;
        if (USDC.isBlacklisted(to)) {
            owedShares[to] += shares;
            owedSharesTotal += shares;
            emit SharesQueued(to, shares);
        } else {
            IERC20(vault).safeTransfer(to, shares);
        }
    }

    /// @dev Closing review: re-checks `v` in the registry, where a failed live check delists it (`revalidateVault`,
    ///      sticky until Gov's reviewed `allowVault`), then reads whether it is still allowlisted. `delisted`: this
    ///      call delisted it; `safe`: allowlisted and passing every live check.
    function _recheck(address v) private returns (bool delisted, bool safe) {
        delisted = REGISTRY.revalidateVault(v);
        safe = !delisted && REGISTRY.isAllowedVault(v);
    }

    function _onlyGuardian() private view {
        if (msg.sender != REGISTRY.guardian()) revert NotGuardian();
    }

    function _disableYield() private {
        yieldOff = true;
        emit YieldDisabled();
    }

    // ---------------------------------------------------------------- Internal: helpers

    function _checkConfig(AccumulationConfig calldata cfg, uint256 n) private view {
        if (
            cfg.circleId == bytes32(0) || n < K.MIN_MEMBERS || n > K.MAX_MEMBERS || cfg.totalRounds == 0
                || cfg.totalRounds > K.MAX_ROUNDS || cfg.contribution < K.MIN_CONTRIBUTION
                || cfg.contribution > K.MAX_CONTRIBUTION || cfg.contribution % K.CENT != 0
                || cfg.feeBps > K.MAX_ACCUMULATION_FEE_BPS || cfg.roundDuration < K.MIN_ROUND
                || cfg.roundDuration > K.MAX_ROUND || cfg.grace < K.MIN_GRACE
                || cfg.grace >= cfg.roundDuration || cfg.cure < K.MIN_CURE || cfg.cure > K.MAX_CURE
                || cfg.joinDeadline <= block.timestamp
                || cfg.joinDeadline > block.timestamp + K.MAX_JOIN_WINDOW
                || cfg.plannedStart > uint256(cfg.joinDeadline) + K.MAX_START_DELAY
        ) revert BadConfig();
        address v = cfg.vault;
        if (v != address(0) && (!REGISTRY.vaultSafe(v) || IVaultV2(v).asset() != address(USDC))) {
            revert BadConfig();
        }
    }

    /// @dev Round `round` can be paid now: it has opened, its deadline + grace has not passed, and it has not been
    ///      flagged. With no extension this is exactly "the current round, or the previous one while its grace
    ///      lasts" (grace < roundDuration).
    function _payable(uint256 round) private view returns (bool) {
        return
            round != 0 && round <= currentRound() && block.timestamp <= _graceEnd(round)
                && !roundFlagged[round];
    }

    function _deadline(uint256 round) private view returns (uint256) {
        return uint256(startTime) + round * roundDuration + extension;
    }

    function _graceEnd(uint256 round) private view returns (uint256) {
        return _deadline(round) + grace;
    }

    function _bit(uint256 round) private pure returns (uint256 word, uint256 bit) {
        word = round >> 8;
        // forge-lint: disable-next-line(incorrect-shift)
        bit = 1 << (round & 0xff);
    }

    /// @dev Mint: `floor(a·(T+1e6)/(NAV+1))`.
    function _toShares(uint256 assets, uint256 nav_, uint256 total) private pure returns (uint256) {
        return Math.mulDiv(assets, total + K.VIRTUAL_SHARES, nav_ + 1);
    }

    /// @dev Payout: `floor(s·(NAV+1)/(T+1e6))`.
    function _toAssets(uint256 shares, uint256 nav_, uint256 total) private pure returns (uint256) {
        return Math.mulDiv(shares, nav_ + 1, total + K.VIRTUAL_SHARES);
    }
}
// forge-lint: disable-end(block-timestamp)
