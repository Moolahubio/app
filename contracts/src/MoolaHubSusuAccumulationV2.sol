// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMoolaHubReputation} from "./interfaces/IMoolaHubReputation.sol";
import {IYieldAdapter} from "./adapters/IYieldAdapter.sol";

/// @title MoolaHubSusuAccumulationV2
/// @notice Yield-bearing accumulation-mode Susu circle (one EIP-1167 clone per
///         circle). Members save on a shared schedule; each member withdraws only
///         the current value of THEIR OWN shares — principal + their pro-rata
///         share of the yield earned while pooled (or less after a lender loss).
///         No member ever receives another member's principal.
///
/// @dev V2 of MoolaHubSusuAccumulation: balances are share-based (ERC-4626 style)
///      and idle USDC is routed through a swappable IYieldAdapter. Each clone is
///      its own small vault, so it carries the virtual-shares inflation defense
///      (offset 1e6, plan §5.8I). Forfeiture of a delinquent member's yield is a
///      LATER milestone (M5) — here a member simply redeems their own shares.
///
///      Roles: the per-circle `guardian` may only pause / cancel (never moves
///      funds). The protocol `configurer` (the factory / multisig) sets and swaps
///      the yield adapter — asset-pinned and only through the vault's own redeem
///      path, so there is no admin path to user principal.
contract MoolaHubSusuAccumulationV2 is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint16 public constant MAX_FEE_BPS = 500; // 5% cap; MoolaHub uses 200 (2%)
    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_MEMBERS = 50; // bound the flagRound loop (Monad bills on gas limit)
    uint256 public constant MAX_ROUNDS = 1_000_000; // bound so maturity() can never overflow
    uint64 public constant MIN_ROUND_DURATION = 60; // floor vs sub-second/shared-timestamp rounds
    uint256 private constant VIRTUAL_SHARES = 1e6; // first-depositor inflation defense (OZ pattern)

    enum Status {
        Active,
        Cancelled
    }

    struct InitConfig {
        address usdc;
        uint256 contributionAmount;
        uint16 feeBps;
        address treasury;
        uint64 roundDuration;
        uint64 gracePeriod;
        uint256 totalRounds;
        address guardian; // pause / cancel only
        address configurer; // sets/swaps the yield adapter (factory / protocol multisig)
        address reputation; // optional (address(0) disables strike reporting)
        bytes32 circleId;
        bool lockUntilMaturity;
    }

    // Config (set once in initialize; effectively immutable per clone).
    IERC20 public usdc;
    uint256 public contributionAmount;
    uint16 public feeBps;
    address public treasury;
    uint64 public startTime;
    uint64 public roundDuration;
    uint64 public gracePeriod;
    uint256 public totalRounds;
    address public guardian;
    address public configurer;
    IMoolaHubReputation public reputation;
    bytes32 public circleId;
    bool public lockUntilMaturity;

    IYieldAdapter public adapter;

    address[] private _members;
    mapping(address => bool) public isMember;

    Status public status;
    bool public paused;

    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;
    mapping(address => uint256) public principalOf; // contributed cost basis per member
    mapping(address => uint256) public roundsContributedOf; // # rounds contributed (compliance)
    mapping(uint256 => mapping(address => bool)) public contributed; // round => member => paid
    mapping(uint256 => bool) public roundFlagged;

    event Contributed(address indexed member, uint256 indexed round, uint256 amount);
    event AccumulationSettled(
        address indexed member, uint256 principal, uint256 payout, uint256 fee, uint256 yieldForfeited
    );
    event DelinquentsFlagged(uint256 indexed round, uint256 count);
    event CircleCancelled(address indexed by);
    event ExcessSwept(uint256 amount);
    event AdapterSet(address indexed adapter);

    error NotMember();
    error NotActive();
    error AlreadyContributed();
    error NotInWindow();
    error NothingSaved();
    error Locked();
    error NotGuardian();
    error NotConfigurer();
    error BadRound();
    error RoundNotClosed();
    error NoExcess();
    error BadConfig();
    error NoAdapter();
    error AssetMismatch();
    error AdapterNotLiquid();

    constructor() {
        _disableInitializers();
    }

    function initialize(InitConfig calldata cfg, address[] calldata members_) external initializer {
        if (cfg.usdc == address(0) || cfg.treasury == address(0) || cfg.configurer == address(0)) {
            revert BadConfig();
        }
        if (members_.length < 2 || members_.length > MAX_MEMBERS) revert BadConfig();
        if (cfg.contributionAmount == 0) revert BadConfig();
        if (cfg.feeBps > MAX_FEE_BPS) revert BadConfig();
        if (cfg.roundDuration < MIN_ROUND_DURATION) revert BadConfig();
        if (cfg.totalRounds == 0 || cfg.totalRounds > MAX_ROUNDS) revert BadConfig();

        usdc = IERC20(cfg.usdc);
        contributionAmount = cfg.contributionAmount;
        feeBps = cfg.feeBps;
        treasury = cfg.treasury;
        startTime = uint64(block.timestamp);
        roundDuration = cfg.roundDuration;
        gracePeriod = cfg.gracePeriod;
        totalRounds = cfg.totalRounds;
        guardian = cfg.guardian;
        configurer = cfg.configurer;
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

    // --- Share math (OZ ERC-4626 virtual-shares pattern) ---------------------

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

    // --- Contributions -------------------------------------------------------

    /// @notice Contribute the fixed round amount. Caller must have approved this
    ///         clone for `contributionAmount` USDC.
    function contribute() external nonReentrant {
        if (status != Status.Active || paused) revert NotActive();
        if (!isMember[msg.sender]) revert NotMember();
        if (address(adapter) == address(0)) revert NoAdapter();
        uint256 round = currentRound();
        if (round < 1) revert NotInWindow();
        if (contributed[round][msg.sender]) revert AlreadyContributed();

        uint256 sh = _toShares(contributionAmount, Math.Rounding.Floor);
        if (sh == 0) revert NothingSaved(); // dust below one share (should not happen for a real amount)

        // Effects (CEI).
        contributed[round][msg.sender] = true;
        roundsContributedOf[msg.sender] += 1; // compliance: contributed every round => == totalRounds
        sharesOf[msg.sender] += sh;
        totalShares += sh;
        principalOf[msg.sender] += contributionAmount;
        emit Contributed(msg.sender, round, contributionAmount);

        // Interactions.
        usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);
        usdc.forceApprove(address(adapter), contributionAmount);
        adapter.deposit(contributionAmount);
    }

    // --- Withdrawals ---------------------------------------------------------

    /// @notice Withdraw your own shares. Forfeiture rules (plan §5.8), judged at
    ///         maturity from the on-chain contribution record:
    ///         - COMPLIANT (contributed every round): receive share value
    ///           (principal + your yield) minus the 2% fee on that amount.
    ///         - DELINQUENT (missed any round): receive only principal (capped at
    ///           the redeemable value if a loss occurred) minus the 2% fee on that
    ///           amount; your accrued YIELD is forfeited. It stays in the vault and
    ///           lifts the exchange rate for the remaining (compliant) savers —
    ///           no loop, no extra gas, redistributed pro-rata to their holdings
    ///           (which, since compliant members save the same schedule, is ~equal).
    ///         - CANCELLED circle: fee-free, full share value, no forfeiture.
    ///         - Unlocked circle, withdrawn before maturity: full share value minus
    ///           the fee (compliance is not yet determinable, so no forfeiture).
    ///         If the LAST shares are burned and forfeited yield remains with no
    ///         compliant saver to receive it (all-delinquent), it goes to the
    ///         treasury (§5.8B) so it can never be stranded.
    ///
    ///         SETTLEMENT ORDER (operational, §5.8G): forfeited yield only reaches
    ///         savers STILL in the vault when the delinquent withdraws. The backend
    ///         keeper MUST settle delinquent members before compliant ones at
    ///         maturity; otherwise a compliant saver who exits first loses their
    ///         share of the redistribution (it falls through to the treasury).
    function withdraw() external nonReentrant {
        bool cancelled = status == Status.Cancelled;
        bool matured = isMatured();
        if (!cancelled && lockUntilMaturity && !matured) revert Locked();

        uint256 shares = sharesOf[msg.sender];
        if (shares == 0) revert NothingSaved();
        uint256 principal = principalOf[msg.sender];
        uint256 gross = _toAssets(shares, Math.Rounding.Floor); // current value of the member's shares

        // Effects: burn ALL the member's shares and clear their cost basis.
        sharesOf[msg.sender] = 0;
        totalShares -= shares;
        principalOf[msg.sender] = 0;

        // `settleBase` is the amount that actually leaves the vault for this member
        // (payout + fee). For a delinquent member it is capped at principal, so the
        // forfeited yield (gross - settleBase) stays deployed and accrues to the
        // remaining savers via the exchange rate.
        uint256 settleBase;
        uint256 fee;
        if (cancelled) {
            settleBase = gross; // fee-free, full value
        } else if (matured && roundsContributedOf[msg.sender] < totalRounds) {
            settleBase = principal < gross ? principal : gross; // min(principal, redeemable)
            fee = (settleBase * feeBps) / BPS;
        } else {
            settleBase = gross; // compliant at maturity, or an unlocked early exit
            fee = (settleBase * feeBps) / BPS;
        }

        uint256 payout = settleBase - fee;
        uint256 forfeited = gross - settleBase; // 0 except for a delinquent member
        emit AccumulationSettled(msg.sender, principal, payout, fee, forfeited);

        // Interactions: pull only `settleBase`; the forfeited remainder stays
        // deployed (redistributing via the exchange rate). Idle-first.
        uint256 idle = usdc.balanceOf(address(this));
        if (settleBase > idle) adapter.withdraw(settleBase - idle, address(this));
        if (fee > 0) usdc.safeTransfer(treasury, fee);
        usdc.safeTransfer(msg.sender, payout); // only ever to the owner of the funds

        // All-delinquent / last-out: once no shares remain, route any residual
        // (orphaned forfeited yield + dust) to the treasury so nothing is stranded.
        if (totalShares == 0) {
            uint256 deployed = address(adapter) == address(0) ? 0 : adapter.maxWithdraw();
            if (deployed > 0) adapter.withdraw(deployed, address(this));
            uint256 residual = usdc.balanceOf(address(this));
            if (residual > 0) usdc.safeTransfer(treasury, residual);
        }
    }

    /// @notice True if `member` contributed in every round (judged any time, but
    ///         only final once the circle has matured).
    function isCompliant(address member) external view returns (bool) {
        return roundsContributedOf[member] == totalRounds;
    }

    // --- Delinquency / admin -------------------------------------------------

    /// @notice Flag members who missed `round` once its window has closed.
    ///         Permissionless. Idempotent per round. Loop bounded by MAX_MEMBERS.
    function flagRound(uint256 round) external nonReentrant {
        if (round < 1 || round > totalRounds) revert BadRound();
        // slither-disable-next-line timestamp
        if (block.timestamp <= uint256(startTime) + round * roundDuration + gracePeriod) revert RoundNotClosed();
        if (roundFlagged[round]) return;
        roundFlagged[round] = true;

        if (address(reputation) == address(0)) {
            emit DelinquentsFlagged(round, 0);
            return;
        }
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
    ///         member's own shares. Cannot move funds to the guardian.
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

    /// @notice Send only USDC sitting idle in THIS clone (accidental direct
    ///         transfers) to the treasury. Member funds live in the adapter as
    ///         shares and are never touched; the adapter's surplus accrues to
    ///         members via the exchange rate, not here.
    function sweepExcess() external nonReentrant {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal == 0) revert NoExcess();
        usdc.safeTransfer(treasury, bal);
        emit ExcessSwept(bal);
    }

    // --- Adapter (configurer only; asset-pinned; via the redeem path) --------

    function setAdapter(IYieldAdapter newAdapter) external nonReentrant {
        if (msg.sender != configurer) revert NotConfigurer();
        _setAdapter(newAdapter);
    }

    /// @notice Circuit breaker: move all funds back to a no-yield Passthrough.
    function emergencyExitToPassthrough(IYieldAdapter passthrough) external nonReentrant {
        if (msg.sender != configurer) revert NotConfigurer();
        _setAdapter(passthrough);
    }

    function _setAdapter(IYieldAdapter newAdapter) private {
        if (address(newAdapter) == address(0)) revert AssetMismatch();
        if (newAdapter.asset() != address(usdc)) revert AssetMismatch();

        IYieldAdapter old = adapter;
        adapter = newAdapter;

        if (address(old) != address(0)) {
            uint256 amt = old.maxWithdraw();
            if (amt > 0) old.withdraw(amt, address(this));
            if (old.totalAssets() > 1) revert AdapterNotLiquid();
        }
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) {
            uint256 newBefore = newAdapter.totalAssets();
            usdc.forceApprove(address(newAdapter), bal);
            newAdapter.deposit(bal);
            if (newAdapter.totalAssets() + bal / 1e6 + 10 < newBefore + bal) revert AdapterNotLiquid();
        }
        emit AdapterSet(address(newAdapter));
    }

    // --- Views ---------------------------------------------------------------

    /// @notice Current redeemable value of a member's shares (principal + yield,
    ///         or less after a loss).
    function balanceOf(address member) public view returns (uint256) {
        return _toAssets(sharesOf[member], Math.Rounding.Floor);
    }

    /// @notice The currently open round (1..totalRounds), or 0 outside the schedule.
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
        if (sharesOf[member] == 0) return false;
        if (status == Status.Cancelled) return true;
        // slither-disable-next-line timestamp
        return !lockUntilMaturity || isMatured();
    }

    function getMembers() external view returns (address[] memory) {
        return _members;
    }
}
