// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMHCircle } from "./IMHCircle.sol";
import { CircleStatus, AccumulationParams } from "../MHCircleTypes.sol";

/// @title IMHAccumulationCircle
/// @notice Accumulation circle: members save `contribution` every round into a shared pool, optionally deposited
///         in an allowlisted Morpho Vault V2 (decision 14). At maturity every member takes their pool shares'
///         value. A member who paid every round (compliant) also shares what delinquent members forfeited: a
///         delinquent keeps at most their principal valued at maturity (plus the post-maturity yield on it), and any
///         value above it goes to the compliant members.
///         Implemented by `MHAccumulationCircle` (spec §4.2, §4.3, §4.5).
/// @dev Accounting is in internal pool shares over tracked counters, never `balanceOf`:
///      `NAV = idleAssets + vault.previewRedeem(vaultShares)` (once per transaction),
///      `toShares(a) = a·(T+1e6)/(NAV+1)` and `toAssets(s) = s·(NAV+1)/(T+1e6)` with `T = totalShares`.
///      Rounding always runs against the member leaving or the treasury: mint floor, burn ceil, payout and fee
///      floor, bonus and unwind floor, dust to residual. The fee is `feeBps` of positive earnings, charged only
///      at maturity: when a member that shares the forfeit pool settles (a compliant member, or anyone when nobody
///      is compliant), and on exit forfeits returned when nobody remains (audit round 1, R1-09 and R1-10).
interface IMHAccumulationCircle is IMHCircle {
    // ---------------------------------------------------------------- Types

    /// @notice Why a circle was cancelled.
    /// @dev Unjoined: not every member joined before `joinDeadline`. Guardian: the Guardian cancelled an Active or
    ///      Matured circle (`guardianCancel`). Expired: anyone cancelled an Active or Matured circle whose vault has
    ///      not valued its shares for `EXPIRY_DELAY` since `lastLive` and still cannot (`cancelExpired`, audit R2-09,
    ///      audit 2 R1-05..R1-07; not "after maturity"). Both cancellations charge no fee and turn every member
    ///      bucket into a claim. Indexers must decode all three values (audit 2 R2-11).
    enum CancelReason {
        Unjoined,
        Guardian,
        Expired
    }

    /// @notice Per-member state.
    /// @param principal USDC this member contributed (also their `cashIn`; there is no collateral).
    /// @param cashOut USDC paid or queued to this member (in-kind vault shares are reported in events only).
    /// @param accShares Pool shares accumulated (zero once settled, exited or cancelled).
    /// @param claimShares Pool shares claimable: after a cancellation (Guardian or Expired), or an exited member's
    ///        own returned forfeits once nobody was left to share them (audit R1-09/R2-02, audit 2 R2-11).
    /// @param paidRounds Rounds this member paid.
    /// @param exitRound First round the member no longer owes: `currentRound()` at its early exit, or
    ///        `totalRounds + 1` after the last deadline (audit 2 R2-07); 0 if not exited.
    /// @param slot 1-based position in `members()` (0 = not a member).
    /// @param joined Whether the member has joined.
    /// @param exited Whether the member exited early.
    /// @param settled Whether the member has been settled at maturity or exited.
    /// @param compliant Whether the member paid every round and did not exit.
    struct MemberState {
        uint256 principal;
        uint256 cashOut;
        uint256 accShares;
        uint256 claimShares;
        uint32 paidRounds;
        uint16 exitRound;
        uint8 slot;
        bool joined;
        bool exited;
        bool settled;
        bool compliant;
    }

    // ---------------------------------------------------------------- Errors

    /// @notice `pullFromVault` found no vault shares to redeem.
    error ZeroAmount();
    /// @notice The circle has no vault, or (for `deployIdle`) the Guardian switched yield off.
    error NoYield();
    /// @notice `deployIdle` while the registry does not allowlist the vault; nothing is latched in the circle, and
    ///         deposits resume once Gov allows the vault again (audit 2 R2-01, closing review).
    error VaultUnsafe();
    /// @notice `deployIdle` found less than `MIN_DEPLOY` idle USDC.
    error NothingToDeploy();
    /// @notice `claimOwedShares` by an address USDC still blacklists.
    error Blacklisted();
    /// @notice `cancelExpired` while the vault can still value the circle's shares: `finalize` and the settlements
    ///         apply instead (audit 2 R1-05, R1-06).
    error NavReadable();
    /// @notice `cancelExpired` was called with too little gas for its `previewRedeem` probe.
    error InsufficientGas();
    /// @notice `forceExit` with zero assets, more assets than the circle's position is worth, or an address that is
    ///         not one of the vault's adapters (audit 2 R1-01).
    error BadForceExit();

    // ---------------------------------------------------------------- Events

    /// @notice A member accepted the terms and joined.
    event Joined(address indexed member);
    /// @notice The last member joined; round 1 opens at `startTime`.
    event Activated(uint256 startTime);
    /// @notice The Guardian switched yield off for good (`emergencyExit` or `forceExit`). Idle USDC is never
    ///         deployed again. A vault the registry does not consider safe only pauses deposits (audit 2 R2-01).
    event YieldDisabled();
    /// @notice A member paid round `round` from their wallet. Same shape as the rotating circle's event so one
    ///         indexer decoder serves both; `fromSecurity` is always 0 and `late` always false here (the window
    ///         closes at grace, so a payment is never late).
    event Contributed(
        address indexed member, uint256 indexed round, uint256 fromWallet, uint256 fromSecurity, bool late
    );
    /// @notice Idle USDC was deposited in the vault.
    event IdleDeployed(uint256 assets, uint256 vaultShares);
    /// @notice The Guardian switched yield off and redeemed one chunk of vault shares into idle USDC.
    event EmergencyExited(uint256 vaultShares, uint256 assets);
    /// @notice Anyone redeemed a chunk of vault shares into idle USDC, after the Guardian switched yield off or
    ///         while the registry did not consider the vault safe.
    event PulledFromVault(address indexed caller, uint256 vaultShares, uint256 assets);
    /// @notice The Guardian force-deallocated `assets` from `adapter` into the vault's idle USDC and redeemed
    ///         `vaultShares` (after `penaltyShares` taken by the vault) into `received` idle USDC (audit 2 R1-01).
    event ForceExited(
        address indexed adapter, uint256 assets, uint256 penaltyShares, uint256 vaultShares, uint256 received
    );
    /// @notice A member left before maturity, taking `amount = min(principal, value)` with no fee and
    ///         forfeiting `forfeitedShares` to the compliant members.
    event ExitedEarly(address indexed member, uint256 principal, uint256 amount, uint256 forfeitedShares);
    /// @notice Round `round` was checked after grace; `missed` members got a MISSED strike.
    event RoundFlagged(uint256 indexed round, uint256 missed);
    /// @notice At maturity a delinquent member's value above principal (`shares`) moved to forfeit.
    event Forfeited(address indexed member, uint256 shares);
    /// @notice The circle matured: snapshots taken at `nav`.
    event Finalized(uint256 nav, uint256 forfeitSnap, uint256 compliantSnap);
    /// @notice A member was settled in USDC: `gross − fee` to the member, `fee` (on positive earnings only) to
    ///         the treasury. `gross − principal` is the member's yield (negative after a loss).
    event MemberSettled(
        address indexed member, uint256 principal, uint256 gross, uint256 fee, bool compliant
    );
    /// @notice A member was settled in kind: `assets` USDC and `vaultShares` vault shares to the member, the fee
    ///         taken pro rata from both.
    event MemberSettledInKind(
        address indexed member,
        uint256 principal,
        uint256 assets,
        uint256 vaultShares,
        uint256 feeAssets,
        uint256 feeVaultShares
    );
    /// @notice Every member is settled (or exited).
    event CircleClosed();
    /// @notice On a cancellation (Guardian or Expired): `member`'s accumulated shares and the claim assigned
    ///         (accumulated plus its part of the forfeit pool). Also when an exited member's own forfeited shares are
    ///         returned as a claim (audit R1-09/R2-02): `accShares` is then the forfeited shares and `claimShares`
    ///         what is returned (less the fee at `finalize`).
    event ClaimAssigned(address indexed member, uint256 accShares, uint256 claimShares);
    /// @notice The circle was cancelled; `claimShares` became claims and `residualShares` is the rounding dust.
    event CircleCancelled(CancelReason indexed reason, uint256 claimShares, uint256 residualShares);
    /// @notice A member claimed their post-cancellation claim in USDC.
    event Claimed(address indexed member, uint256 amount);
    /// @notice A member claimed their post-cancellation claim in kind.
    event ClaimedInKind(address indexed member, uint256 assets, uint256 vaultShares);
    /// @notice The Guardian pushed every round deadline back by `by` seconds; `totalExtension` is the new total.
    event DeadlineExtended(uint256 by, uint256 totalExtension);
    /// @notice Untracked USDC and vault shares (donations; queued `owedShares` are tracked) were sent to the
    ///         treasury.
    event DonationsSwept(address indexed treasury, uint256 assets, uint256 vaultShares);
    /// @notice Everything left after every member bucket reached zero was sent to the treasury.
    event ResidualSwept(address indexed treasury, uint256 assets, uint256 vaultShares);
    /// @notice Vault shares bound for a USDC-blacklisted address were queued in `owedShares` instead (audit
    ///         R1-14).
    event SharesQueued(address indexed to, uint256 vaultShares);
    /// @notice Queued vault shares were sent to their owner.
    event OwedSharesClaimed(address indexed to, uint256 vaultShares);
    /// @notice At maturity with nobody left to share the forfeit pool, the fee on the exited members' returned
    ///         forfeits was paid to the treasury in kind (audit R1-09).
    event FeePaidInKind(address indexed treasury, uint256 assets, uint256 vaultShares);

    // ---------------------------------------------------------------- Initialization

    /// @notice Initializes a fresh clone. Called by the factory in the same transaction as the clone, so nobody
    ///         can front-run it; the implementation itself has initializers disabled.
    /// @dev Checks `circleId != 0`, every §4.1 bound, members unique and non-zero, `vault == 0 ||
    ///      (REGISTRY.vaultSafe(vault) && vault.asset() == USDC)`, and that the factory registered this clone as a
    ///      reporter (audit 2 R1-17), then stores `termsHash` (see `MHCircleTerms.accumulation`). Reverts `BadConfig`
    ///      otherwise.
    /// @param p Terms (including vault and lock) and members.
    function initialize(AccumulationParams calldata p) external;

    // ---------------------------------------------------------------- Member actions

    /// @notice Joins the circle, accepting `terms`. The last join activates the circle with
    ///         `startTime = max(now, plannedStart)`. Nothing about the vault is latched here: `deployIdle` checks the
    ///         registry before every deposit (audit 2 R2-01).
    /// @dev Same signature as the rotating circle. Accumulation circles take no collateral, so a non-zero
    ///      `collateral` reverts `BadTerms`. Also reverts `NotPending`, `JoinClosed`, `NotMember`,
    ///      `AlreadyJoined`, `BadTerms`.
    /// @param terms Must equal `termsHash()`.
    /// @param collateral Must be zero.
    function join(bytes32 terms, uint256 collateral) external;

    /// @notice Pays the caller's round-`round` contribution from their wallet and mints pool shares (floor)
    ///         against the current NAV. The USDC stays idle until someone calls `deployIdle`.
    /// @dev Window: the current round, or an earlier round until its deadline + grace (with no extension that is
    ///      exactly the previous round while its grace lasts), and never a round already flagged. Reverts
    ///      `NotActive`, `NotMember`, `AlreadySettled` (exited), `BadRound`, `AlreadyPaid`, `ExceedsMaxPull`.
    /// @param round The round to pay.
    /// @param maxPull Upper bound on the wallet pull (the client batches an exact approval).
    /// @return shares The pool shares minted.
    function contribute(uint256 round, uint256 maxPull) external returns (uint256 shares);

    /// @notice Leaves before maturity: pays `min(principal, value)` with no fee; the rest of the caller's shares
    ///         go to forfeit for the compliant members. Takes the pro-rata part of idle USDC and withdraws the rest
    ///         from the vault (audit R2-06); reverts if the vault cannot pay. There is no in-kind early exit: while
    ///         the vault is illiquid an early exit waits for liquidity, even when idle USDC would cover it (closing
    ///         review, acknowledged). Rounds before `exitRound` stay owed (`flagRound`); after the last round's
    ///         deadline that includes the last round (audit 2 R2-07).
    /// @dev Active only. Reverts `Locked` (`lockUntilMaturity`), `NotActive`, `NotMember`, `AlreadySettled`.
    /// @return amount The USDC paid (or queued in `owed`).
    function exitEarly() external returns (uint256 amount);

    /// @notice Pays the caller's post-cancellation claim in USDC (`toAssets(claimShares)`, floor): the claim's
    ///         pro-rata part of idle USDC, the rest withdrawn from the vault (audit R2-06).
    /// @dev Reverts `NothingToClaim`, or with the vault's error when it cannot pay (use `claimInKind`).
    /// @return amount The USDC paid (or queued in `owed`).
    function claim() external returns (uint256 amount);

    /// @notice Pays the caller's claim in kind: their pro-rata (floor) part of idle USDC and of the circle's vault
    ///         shares. Works while the vault is illiquid or cannot value its shares. Vault shares for a
    ///         USDC-blacklisted caller are queued in `owedShares`.
    /// @dev Reverts `NothingToClaim`.
    /// @return assets The USDC paid (or queued in `owed`).
    /// @return vShares The vault shares transferred.
    function claimInKind() external returns (uint256 assets, uint256 vShares);

    /// @notice Settles the caller at maturity in kind (idle USDC plus vault shares, pro rata, fee taken pro rata
    ///         from both). For when the vault is too illiquid for `settleMember`. Vault shares for a USDC-blacklisted
    ///         member (or treasury) are queued in `owedShares`.
    /// @dev Only `member` itself may call it, so nobody can force vault shares on a member. Reverts
    ///      `NotMember` (caller is not `member` or not a member), `NotMatured`, `AlreadySettled`.
    /// @param member The member to settle; must be `msg.sender`.
    function settleMemberInKind(address member) external;

    /// @notice Sends the caller the vault shares queued for it while it was USDC-blacklisted.
    /// @dev Reverts `NothingOwed`, `Blacklisted` (still blacklisted).
    /// @return vShares The vault shares sent.
    function claimOwedShares() external returns (uint256 vShares);

    // ---------------------------------------------------------------- Permissionless transitions

    /// @notice Deposits every idle USDC unit in the vault (exact approval, reverts on failure). Never called by
    ///         `contribute`. Audit 2 R1-09/R2-01: only while the registry allowlists the vault and it passes the live
    ///         check. Closing review: it first calls `REGISTRY.revalidateVault`, so an allowlisted vault that fails
    ///         the live check is delisted (sticky until Gov's reviewed `allowVault`) and the call returns without
    ///         depositing; a vault already delisted reverts `VaultUnsafe`. Nothing is latched in the circle
    ///         (`syncVault` was removed with the latch), and a curator restoring the checked state cannot resume
    ///         deposits on its own.
    /// @dev Active only. Reverts `NotActive`, `NoYield` (no vault, or the Guardian switched yield off),
    ///      `VaultUnsafe`, `NothingToDeploy` (idle below `MIN_DEPLOY`), or with the vault's error; with too little
    ///      gas for the registry's bounded adapter reads, `InsufficientGas` (never a delisting).
    function deployIdle() external;

    /// @notice Records a MISSED strike for every member that did not pay round `round`, once, after its
    ///         deadline + grace + cure (audit 2 R1-08: the cure is the Guardian's window to extend after an outage
    ///         that spanned the grace end; an extension reopens a round that is not flagged yet). A member who
    ///         exited early is only flagged for rounds before their exit round.
    /// @dev Allowed once every member has joined (Active, Matured or Closed). Reverts `NotActive`, `BadRound`
    ///      (out of range, grace + cure not over, or already flagged), `UsdcPaused`, and while Active with the vault's
    ///      error when the vault cannot value its shares (nobody could pay then; audit R1-03).
    /// @param round The round to check.
    function flagRound(uint256 round) external;

    /// @notice Matures the circle after the last round's deadline + grace + cure (audit 2 R1-08), or as soon as every
    ///         member has exited early (audit 2 R2-06: nothing is left to pay). Compliant = paid
    ///         every round and did not exit. A delinquent member whose value exceeds principal keeps `toShares(principal)` (floor) and
    ///         forfeits the rest; this is the only cap. Snapshots `forfeitSnap` and `compliantSnap`. If nobody is
    ///         compliant, nothing is capped and the forfeit pool (from early exits) is shared by every remaining
    ///         member. If nobody remains at all, each exited member gets its own forfeited shares back as a claim,
    ///         less the fee on those earnings, paid to the treasury in kind (audit R1-09).
    /// @dev Reverts `NotActive`, `NotMatured` (too early), `UsdcPaused`.
    function finalize() external;

    /// @notice Settles `member` at maturity in USDC; anyone may call, and only `member` is paid. The USDC is the
    ///         settlement's pro-rata part of idle USDC plus a withdrawal from the vault for the rest (audit R2-06: the
    ///         first cash settlers can no longer drain the idle USDC the Guardian pulled out under stress).
    ///         Compliant: `toAssets(acc + floor(forfeitSnap·acc/compliantSnap))` minus the fee on earnings.
    ///         Delinquent: `toAssets(acc)` of the shares `finalize` left it (capped once, at maturity), with no fee;
    ///         those shares earn post-maturity yield like every other bucket (audit R1-11).
    ///         Everyone delinquent: `toAssets(acc + pro-rata forfeit)`, uncapped, minus the fee on earnings (audit
    ///         R1-10).
    /// @dev Reverts `NotMatured`, `NotMember`, `AlreadySettled`, or with the vault's error when it cannot pay
    ///      (use `settleMemberInKind`).
    /// @param member The member to settle.
    function settleMember(address member) external;

    /// @notice Anyone: redeems up to `maxVaultShares` of the circle's vault shares into idle USDC, once the
    ///         Guardian switched yield off, or while the registry does not consider the vault safe (delisted or
    ///         failing a live check: keepers protect every circle on such a vault without the Guardian, audit 2
    ///         R1-09/R2-01). Closing review: with yield on it first calls `REGISTRY.revalidateVault`, so a vault
    ///         failing the live check is delisted in the same call, and `deployIdle` puts the USDC back only after
    ///         Gov allows the vault again (a revert, e.g. an illiquid vault, also undoes the delisting: keepers call
    ///         `revalidateVault` directly first).
    /// @dev Any status. Reverts `YieldOn` (yield on and the vault safe), `ZeroAmount` (nothing to redeem), or with
    ///      the vault's error.
    /// @param maxVaultShares Maximum vault shares to redeem (a chunk; never a `max*` call).
    function pullFromVault(uint256 maxVaultShares) external;

    /// @notice Cancels a Pending circle after `joinDeadline`. No money is held before activation, so nothing is
    ///         refunded and nobody is struck.
    /// @dev Reverts `NotPending`, `NotStalled` (deadline not passed), `UsdcPaused`.
    function cancelUnjoined() external;

    /// @notice Sends untracked USDC and untracked vault shares (donations) to the treasury.
    /// @dev Reverts `NothingToClaim`.
    function sweepDonations() external;

    /// @notice Once every member bucket is zero (Closed, or Cancelled with every claim taken), sends everything
    ///         left (rounding residual) to the treasury: idle USDC as USDC, vault shares in kind.
    /// @dev Reverts `NotEnded`, `NothingToClaim`.
    function sweepResidual() external;

    // ---------------------------------------------------------------- Guardian

    /// @notice Guardian: switches yield off for good and redeems up to `maxVaultShares` into idle USDC (one
    ///         chunk; call again for more). `maxVaultShares = 0` only switches yield off, which works even when the
    ///         vault is fully illiquid (R3).
    /// @dev Any status. Reverts `NotGuardian`, `NoYield` (no vault), or with the vault's error.
    /// @param maxVaultShares Maximum vault shares to redeem.
    function emergencyExit(uint256 maxVaultShares) external;

    /// @notice Guardian: switches yield off for good and, in one call, `vault.forceDeallocate(adapter, data, assets,
    ///         circle)` then redeems at most `assets` of the circle's vault shares into idle USDC (all of them when
    ///         they are worth no more). Audit 2 R1-01: an exit that does not depend on the vault's liquidity adapter,
    ///         which any allocator can point at an empty market instantly, and that no allocator can undo between
    ///         two transactions. The vault's force-deallocation penalty (at most 2%, Vault V2's cap) is taken from
    ///         the circle's shares; `assets` is bounded by the position's value, so over any number of calls the
    ///         penalty is at most that share of the position.
    /// @dev Any status. Reverts `NotGuardian`, `NoYield` (no vault), `BadForceExit` (zero assets, more than the
    ///      circle's position is worth, or not one of the vault's adapters), or with the vault's error.
    /// @param adapter One of the vault's adapters holding liquidity (Morpho market adapter).
    /// @param data The adapter's deallocation data (for a Morpho market adapter, the encoded market params).
    /// @param assets USDC to free and redeem.
    function forceExit(address adapter, bytes calldata data, uint256 assets) external;

    /// @notice Guardian: cancels an Active or Matured circle, with no fee. Active: every remaining member's claim
    ///         is their shares plus a pro-rata (floor) part of the forfeit pool; if no remaining member holds any
    ///         shares, each exited member's own forfeited shares become its claim instead (audit R2-02). Matured
    ///         (audit R1-03, the NAV-free exit when the vault cannot value its shares): the finalize outcomes stand,
    ///         so each unsettled member's claim is its (capped) shares plus exactly the bonus `settleMember` would
    ///         give it. Only rounding dust (at most one share per member) goes to residual; claims are paid by
    ///         `claim` or, without any NAV, by `claimInKind`.
    /// @dev Reverts `NotGuardian`, `NotActive`.
    function guardianCancel() external;

    /// @notice Anyone: the same cancellation as `guardianCancel` (reason `Expired`) of an Active or Matured circle
    ///         whose vault cannot value its shares, once `EXPIRY_DELAY` (90 days) has passed since the vault last
    ///         valued them (`lastLive`). Audit R2-09 (spec §4.7 invariant 7): with such a vault every other exit
    ///         reverts, so this permissionless, NAV-free path guarantees a claim without the Guardian. Audit 2
    ///         R1-05/R1-06/R1-07: the gate follows the outage, not the schedule; while the vault can value the
    ///         shares (a bounded `previewRedeem` probe) `finalize` and the settlements apply instead, so this path
    ///         never skips the delinquent cap, the compliant-only forfeit routing or the fee; and it reverts while
    ///         USDC is paused or blacklists the circle, like every timer-driven transition.
    /// @dev Reverts `NotActive`, `NotStalled` (too early), `UsdcPaused`, `CircleBlacklisted`, `InsufficientGas`
    ///      (less than `NAV_PROBE_MIN_GAS` left for the probe), `NavReadable` (the vault can value its shares).
    function cancelExpired() external;

    /// @notice Guardian: pushes every round deadline (and so every grace gate and maturity) back by `by`.
    /// @dev Active only. Reverts `NotGuardian`, `NotActive`, `ExtensionLimit` (zero, more than 7 days per call,
    ///      or more than 30 days in total).
    /// @param by Seconds to add.
    function extendDeadline(uint256 by) external;

    // ---------------------------------------------------------------- Views: terms

    /// @notice Per-round contribution in USDC base units.
    function contribution() external view returns (uint256);

    /// @notice Fee in bps of positive earnings, charged at maturity when a member that shares the forfeit pool
    ///         settles (compliant, or anyone when nobody is compliant, audit R1-10) and on exit forfeits returned
    ///         when nobody remains (audit R1-09); never on a cancellation or a delinquent's capped value.
    function feeBps() external view returns (uint16);

    /// @notice Seconds per round.
    function roundDuration() external view returns (uint64);

    /// @notice Seconds after a round deadline during which it can still be paid.
    function grace() external view returns (uint64);

    /// @notice Cure period after a round's grace: `flagRound(r)` opens after `graceEnd(r) + cure` and `finalize`
    ///         after `graceEnd(totalRounds) + cure` (audit 2 R1-08), the Guardian's window to extend after an outage.
    function cure() external view returns (uint64);

    /// @notice Last timestamp at which members can join.
    function joinDeadline() external view returns (uint64);

    /// @notice Earliest start.
    function plannedStart() external view returns (uint64);

    /// @notice Number of rounds.
    function totalRounds() external view returns (uint32);

    /// @notice When the vault last valued the circle's shares in a state-changing call (activation, a
    ///         contribution, exit, claim, deposit, flag, finalize or settlement). `cancelExpired` opens
    ///         `EXPIRY_DELAY` after it (audit 2 R1-07).
    function lastLive() external view returns (uint64);

    /// @notice The Morpho Vault V2 (address(0) = no yield).
    function vault() external view returns (address);

    /// @notice Whether `exitEarly` is disabled.
    function lockUntilMaturity() external view returns (bool);

    // ---------------------------------------------------------------- Views: lifecycle and pool

    /// @notice Lifecycle status.
    function status() external view returns (CircleStatus);

    /// @notice When round 1 opened (0 until Active).
    function startTime() external view returns (uint64);

    /// @notice Total Guardian extension, in seconds, added to every round deadline.
    function extension() external view returns (uint64);

    /// @notice Members that have joined.
    function joinedCount() external view returns (uint8);

    /// @notice Members settled at maturity or exited early.
    function settledCount() external view returns (uint8);

    /// @notice Whether the Guardian switched yield off (one-way: `emergencyExit`, `forceExit`). A vault the registry
    ///         does not consider safe only pauses deposits (until Gov allows it again) and opens `pullFromVault` (audit
    ///         2 R2-01, closing review).
    function yieldOff() external view returns (bool);

    /// @notice USDC held idle by the circle (tracked; donations excluded).
    function idleAssets() external view returns (uint256);

    /// @notice Vault shares held by the circle (tracked; donations excluded).
    function vaultShares() external view returns (uint256);

    /// @notice Pool shares outstanding: `accTotal + claimTotal + forfeitShares + residualShares`.
    function totalShares() external view returns (uint256);

    /// @notice Sum of every member's accumulated shares.
    function accTotal() external view returns (uint256);

    /// @notice Sum of every unclaimed post-cancellation claim, in pool shares.
    function claimTotal() external view returns (uint256);

    /// @notice Pool shares forfeited (early exits, delinquent caps) and not yet paid as bonus.
    function forfeitShares() external view returns (uint256);

    /// @notice Forfeit pool at maturity, shared among the compliant members (every remaining member when nobody is
    ///         compliant, by `bonusBase`); 0 when nobody remained and the forfeits were returned to the exited
    ///         members (audit R1-09).
    function forfeitSnap() external view returns (uint256);

    /// @notice Accumulated shares of compliant members at maturity.
    function compliantSnap() external view returns (uint256);

    /// @notice Denominator of the bonus split: `compliantSnap`, or every remaining member's shares when nobody is
    ///         compliant.
    function bonusBase() external view returns (uint256);

    /// @notice Pool shares owed to the treasury as rounding residual.
    function residualShares() external view returns (uint256);

    /// @notice Vault shares queued for `account` while it was USDC-blacklisted (audit R1-14).
    /// @param account The address.
    function owedShares(address account) external view returns (uint256);

    /// @notice Sum of every queued vault-share entry.
    function owedSharesTotal() external view returns (uint256);

    /// @notice Whether `round` has been flagged.
    /// @param round The round.
    function roundFlagged(uint256 round) external view returns (bool);

    /// @notice Net asset value: `idleAssets + vault.previewRedeem(vaultShares)`.
    function nav() external view returns (uint256);

    /// @notice Current value of `member`'s accumulated shares, `toAssets(accShares)` at the current NAV (before
    ///         forfeits, bonus and fee).
    /// @param member The member.
    function memberValue(address member) external view returns (uint256);

    // ---------------------------------------------------------------- Views: members and rounds

    /// @notice Whether `member` paid round `round`.
    /// @param round The round.
    /// @param member The member.
    function paid(uint256 round, address member) external view returns (bool);

    /// @notice Members in creation order.
    function members() external view returns (address[] memory);

    /// @notice 1-based position of `account` in `members()` (0 = not a member).
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

    /// @notice The exact wallet pull `contribute(round, …)` would make for `member` now: `contribution`, or 0
    ///         when the round cannot be paid by `member` now.
    /// @param member The member.
    /// @param round The round.
    function amountDue(address member, uint256 round) external view returns (uint256);
}
