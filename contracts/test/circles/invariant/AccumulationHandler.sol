// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { MHAccumulationCircle } from "../../../src/circles/MHAccumulationCircle.sol";
import { MHCircleFactory } from "../../../src/circles/MHCircleFactory.sol";
import { MHCircleRegistry } from "../../../src/circles/MHCircleRegistry.sol";
import { MHCircleConstants as K } from "../../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../../src/circles/interfaces/IMHCircle.sol";
import { IMHAccumulationCircle } from "../../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IVaultV2 } from "../../../src/circles/interfaces/IVaultV2.sol";
import { CircleStatus, AccumulationConfig, AccumulationParams } from "../../../src/circles/MHCircleTypes.sol";

import { MockUSDC } from "../../mocks/MockUSDC.sol";
import { MockVaultV2 } from "../../mocks/MockVaultV2.sol";

/// @notice Invariant handler for one `MHAccumulationCircle` per run (spec §4.7), against a mock Vault V2 that can
///         toggle yield, loss, illiquidity, deposit/exit gates and a drifting (discounted) `previewRedeem`. The
///         first call of a run creates the circle from its seed (n, rounds, c, fee, vault or none, lock, who is
///         unreliable). Actors: the members, the Gov Safe, the Timelock, the Guardian, the operator, the treasury
///         and an attacker. Every circle call goes through `_call`, which attributes treasury inflow (USDC and vault
///         shares) to fees, residual or donations, tracks the largest gas used, and checks each settlement against
///         an independent evaluation of the spec formula made just before the call (fee only on earnings, a
///         delinquent member at most its principal, Σ bonus ≤ forfeitSnap). Violations are recorded, not reverted,
///         so the invariant names them.
contract AccumulationHandler is Test {
    uint256 internal constant POOL = 6;
    uint256 internal constant VS = 1e6; // circle virtual shares

    MockUSDC public immutable usdc;
    MockVaultV2 public immutable morpho;
    /// @dev The vault's market adapter (the `forceExit` target, audit 2 R1-01).
    address public immutable adapter;
    MHCircleFactory public immutable factory;
    MHCircleRegistry public immutable registry;
    address public immutable gov;
    address public immutable timelock;
    address public immutable guardian;
    address public immutable operator;
    address public immutable treasury;
    address public immutable attacker;

    MHAccumulationCircle public circle;
    address[] internal _pool;
    address[] internal _admins;

    // ---------------------------------------------------------------- Run parameters

    uint256 public n;
    uint256 public rounds;
    uint256 public feeBps;
    bool public hasVault;
    /// @dev Bitmap over member indices: members that skip rounds (each round with probability 1/3).
    uint256 public unreliable;
    uint256 internal _skipSalt;
    address public blacklisted;

    // ---------------------------------------------------------------- Ghost ledger

    uint256 public ghostDonatedUsdc;
    uint256 public ghostDonatedShares;
    uint256 public ghostDonSweptUsdc;
    uint256 public ghostDonSweptShares;
    uint256 public ghostFeeUsdc;
    uint256 public ghostFeeShares;
    uint256 public ghostResidualUsdc;
    uint256 public ghostResidualShares;
    uint256 public ghostUnexpectedUsdc;
    uint256 public ghostUnexpectedShares;
    uint256 public ghostBonusSum;
    uint256 public ghostMaxGas;
    bytes4 public ghostMaxGasSelector;
    /// @dev Set once NAV can have fallen (a vault loss or a preview discount): per-dollar fairness between
    ///      compliant and delinquent members is only claimed for non-decreasing share prices.
    bool public ghostLossSeen;
    /// @dev First violated per-call property, empty if none.
    string public ghostViolation;
    mapping(bytes4 selector => uint256 count) public successes;

    /// @dev Settlement outcomes for the per-dollar comparison: principal and the pool shares the settlement was
    ///      worth (acc + bonus, from the independent evaluation; timing-independent since audit R1-11).
    uint256[] internal _settledPrincipal;
    uint256[] internal _settledValue;
    bool[] internal _settledCompliant;

    /// @dev Audit R1-31: finalize checked independently. The share price at finalize and each delinquent member's
    ///      expected retained shares, recomputed from public state just before the call.
    uint256 public navAtFinalize;
    uint256 public totalAtFinalize;
    /// @dev `finalize` succeeded once (a Matured circle can later be cancelled by the Guardian, R1-03).
    bool public finalizedOnce;
    mapping(address member => uint256 shares) internal _expectedAcc;
    /// @dev Audit R1-09: the most the treasury may receive from `finalize` (the fee on returned exit forfeits).
    uint256 internal _finalizeFeeCap;
    /// @dev The circle's own valuation of its vault shares just before `finalize` (the fee is checked on the same
    ///      basis as the cap: a discounted `previewRedeem` understates both).
    uint256 internal _finalizeVaultPart;
    uint256 internal _finalizeHeld;

    /// @dev Value of one settlement made just before the call (the spec formula, evaluated independently).
    struct Expect {
        bool active;
        bool compliant;
        uint256 principal;
        uint256 gross;
        uint256 fee;
        uint256 bonus;
        uint256 shares;
        uint256 navVaultPart;
        uint256 heldShares;
        uint256 nav;
        uint256 total;
    }

    Expect internal _expect;

    constructor(
        MockUSDC usdc_,
        MockVaultV2 morpho_,
        MHCircleFactory factory_,
        MHCircleRegistry registry_,
        address[6] memory roles // gov, timelock, guardian, operator, treasury, attacker
    ) {
        usdc = usdc_;
        morpho = morpho_;
        adapter = morpho_.adapters(0);
        factory = factory_;
        registry = registry_;
        gov = roles[0];
        timelock = roles[1];
        guardian = roles[2];
        operator = roles[3];
        treasury = roles[4];
        attacker = roles[5];
        for (uint256 i; i < POOL; ++i) {
            _pool.push(makeAddr(string.concat("accMember", vm.toString(i))));
        }
        for (uint256 i; i < 6; ++i) {
            _admins.push(roles[i]);
        }
    }

    // ================================================================ Views for the invariant contract

    function admins() external view returns (address[] memory) {
        return _admins;
    }

    function settlements() external view returns (uint256[] memory p, uint256[] memory v, bool[] memory c) {
        return (_settledPrincipal, _settledValue, _settledCompliant);
    }

    // ================================================================ Member actions

    function joinAll(uint256 seed) external {
        if (!_ensure(seed)) return;
        for (uint256 i; i < n; ++i) {
            _join(_pool[i]);
        }
    }

    function join(uint256 who) external {
        if (!_ensure(who)) return;
        _join(_member(who));
    }

    function contribute(uint256 who, uint256 roundSeed) external {
        if (!_ensure(who)) return;
        uint256 last = circle.currentRound();
        if (last == 0) return;
        _payRound(_member(who), _bound(roundSeed, 1, last));
    }

    /// @dev Every member pays every payable round, except an unreliable member's skipped rounds.
    function payReliable(uint256 seed) external {
        if (!_ensure(seed)) return;
        _payReliable();
    }

    function exitEarly(uint256 who) external {
        if (!_ensure(who)) return;
        who = _h(who);
        if (who % 3 != 0) return; // exits are rarer than other actions
        address m = _member(who >> 2);
        _expectExit(m);
        _call(m, abi.encodeCall(MHAccumulationCircle.exitEarly, ()));
    }

    function settleMemberInKind(uint256 who) external {
        if (!_ensure(who)) return;
        address m = _member(who);
        _expectSettle(m);
        _call(m, abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (m)));
    }

    function claim(uint256 who) external {
        if (!_ensure(who)) return;
        _call(_member(who), abi.encodeCall(MHAccumulationCircle.claim, ()));
    }

    function claimInKind(uint256 who) external {
        if (!_ensure(who)) return;
        _call(_member(who), abi.encodeCall(MHAccumulationCircle.claimInKind, ()));
    }

    /// @dev Audit R1-14: vault shares queued for a member or the treasury while it was blacklisted.
    function claimOwedShares(uint256 who) external {
        if (!_ensure(who)) return;
        address a = who % (n + 1) == n ? treasury : _member(who);
        _call(a, abi.encodeCall(MHAccumulationCircle.claimOwedShares, ()));
    }

    // ================================================================ Permissionless actions

    /// @dev Audit 2 R2-01 oracle: a deposit never reaches a vault the registry does not consider safe. Closing
    ///      review: a call that finds an allowlisted vault failing the live check succeeds only by delisting it, with
    ///      nothing deposited.
    function deployIdle(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        bool safe = hasVault && registry.vaultSafe(address(morpho));
        uint256 shares = circle.vaultShares();
        bool ok = _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.deployIdle, ()));
        if (ok && !safe && (circle.vaultShares() != shares || registry.isAllowedVault(address(morpho)))) {
            _violate("deployIdle deposited into, or left allowlisted, an unsafe vault");
        }
        if (ok && circle.yieldOff()) _violate("deployIdle after the Guardian switched yield off");
    }

    function flagRound(uint256 actorSeed, uint256 roundSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(
            _anyone(actorSeed),
            abi.encodeCall(MHAccumulationCircle.flagRound, (_bound(roundSeed, 0, rounds + 1)))
        );
    }

    function finalize(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _finalize(_anyone(actorSeed));
    }

    function settleMember(uint256 actorSeed, uint256 who) external {
        if (!_ensure(actorSeed)) return;
        address m = _member(who);
        _expectSettle(m);
        _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.settleMember, (m)));
    }

    function claimOwed(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(IMHCircle.claimOwed, ()));
    }

    /// @dev Audit 2 R2-01 oracle: anyone may pull only once the Guardian switched yield off or while the registry does
    ///      not consider the vault safe.
    ///      Closing review: a pull while yield is on and the vault fails the live check leaves it delisted.
    function pullFromVault(uint256 actorSeed, uint256 shares) external {
        if (!_ensure(actorSeed)) return;
        bool open = circle.yieldOff() || !(hasVault && registry.vaultSafe(address(morpho)));
        bool yieldOn = !circle.yieldOff();
        bool ok = _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.pullFromVault, (shares)));
        if (ok && !open) _violate("pullFromVault while yield on and the vault safe");
        if (ok && yieldOn && registry.isAllowedVault(address(morpho))) {
            _violate("pullFromVault left an unsafe vault allowlisted");
        }
    }

    function cancelUnjoined(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.cancelUnjoined, ()));
    }

    function sweepDonations(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.sweepDonations, ()));
    }

    function sweepResidual(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHAccumulationCircle.sweepResidual, ()));
    }

    /// @dev Audit R2-09 / audit 2 R1-05..R1-07: the permissionless NAV-free cancel. Sometimes the vault first stops
    ///      valuing shares for longer than the outage gate (`lastLive + EXPIRY_DELAY`), so the cancel can open (the
    ///      next `vaultBreak` repairs the vault); otherwise it is tried as things are (and must then revert).
    function cancelExpired(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        if (actorSeed % 3 == 0 && hasVault) {
            morpho.mockSetNavBroken(true);
            uint256 gate = uint256(circle.lastLive()) + K.EXPIRY_DELAY + 1;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < gate) vm.warp(gate);
        }
        _call(_anyone(actorSeed >> 2), abi.encodeCall(MHAccumulationCircle.cancelExpired, ()));
    }

    /// @dev Audit 2 R2-01: Gov re-allows the vault (through the Timelock) after a precautionary delisting; live
    ///      circles deposit again unless the Guardian switched their yield off.
    function reallowVault(uint256 seed) external {
        if (!hasVault || _h(seed) % 3 != 0 || registry.isAllowedVault(address(morpho))) return;
        vm.prank(timelock);
        (bool ok,) = address(registry).call(abi.encodeCall(MHCircleRegistry.allowVault, (address(morpho))));
        ok; // the mock vault's checks pass unless a run weakened them
    }

    /// @dev Closing review: the vault's curator lowers a checked timelock (a matured `decreaseTimelock`) or restores
    ///      it (`increaseTimelock`, instant). While lowered the vault fails the live check; restoring it never
    ///      re-enables deposits once a circle call has delisted the vault (only `reallowVault`, Gov, does: the
    ///      `deployIdle` oracle above).
    function curatorTimelock(uint256 seed) external {
        if (!hasVault || _h(seed) % 2 != 0) return;
        bytes4 sel = IVaultV2.increaseAbsoluteCap.selector;
        morpho.mockSetTimelock(sel, morpho.timelock(sel) == 0 ? 3 days : 0);
    }

    // ================================================================ Guardian

    function emergencyExit(uint256 actorSeed, uint256 maxShares) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 6 == 0 ? guardian : _notGuardian(actorSeed >> 3);
        uint256 held = circle.vaultShares();
        maxShares = maxShares % 3 == 0 ? 0 : _bound(maxShares, 0, held + 1);
        _call(actor, abi.encodeCall(MHAccumulationCircle.emergencyExit, (maxShares)));
    }

    /// @dev Audit 2 R1-01: the Guardian (or someone else, which must fail) force-exits up to the circle's position,
    ///      sometimes with a non-zero force-deallocation penalty (at most 2%) or against an allocator that just
    ///      pointed the liquidity adapter at an empty market.
    function forceExit(uint256 actorSeed, uint256 assets) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 4 != 0 ? guardian : _notGuardian(actorSeed >> 2);
        if ((actorSeed >> 8) % 3 == 0) {
            morpho.mockSetForceDeallocatePenalty(adapter, _bound(assets, 0, 0.02e18));
        }
        if ((actorSeed >> 10) % 3 == 0) morpho.mockSetLiquidity(0);
        uint256 held = circle.vaultShares();
        uint256 value = held == 0 || morpho.navBroken() ? 0 : morpho.previewRedeem(held);
        assets = (actorSeed >> 12) % 3 == 0 ? value : _bound(assets, 0, value + 1);
        uint256 navBefore = morpho.navBroken() ? 0 : circle.nav();
        bool ok = _call(actor, abi.encodeCall(MHAccumulationCircle.forceExit, (adapter, "", assets)));
        if (!ok) return;
        if (actor != guardian) _violate("forceExit by someone other than the Guardian");
        if (!circle.yieldOff()) _violate("forceExit left yield on");
        // The circle pays at most the vault's 2% penalty on `assets` (rounding aside).
        if (circle.nav() + assets / 50 + 2 < navBefore) _violate("forceExit cost more than the 2% penalty");
    }

    /// @dev An allocator moves the idle USDC freed by a force deallocation back into a market (instant).
    function vaultReallocate(uint256 seed) external {
        if (_h(seed) % 2 == 0) morpho.mockReallocate();
    }

    function guardianCancel(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 16 == 0 ? guardian : _notGuardian(actorSeed >> 4);
        _call(actor, abi.encodeCall(MHAccumulationCircle.guardianCancel, ()));
    }

    function extendDeadline(uint256 actorSeed, uint256 by) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 2 == 0 ? guardian : _anyone(actorSeed >> 1);
        _call(actor, abi.encodeCall(MHAccumulationCircle.extendDeadline, (_bound(by, 0, 8 days))));
    }

    /// @dev The Guardian delists the vault (new circles only; a live circle keeps it).
    function disallowVault(uint256 seed) external {
        if (_h(seed) % 4 != 0) return;
        vm.prank(guardian);
        registry.disallowVault(address(morpho));
    }

    // ================================================================ Time

    /// @dev The app and the keeper at work, then time moves on: members usually pay what is payable, the keeper
    ///      often deploys idle USDC, then time jumps to the next gate that matters.
    function advance(uint256 seed) external {
        if (!_ensure(seed)) return;
        seed = _h(seed);
        if (seed % 4 != 0) _payReliable();
        if ((seed >> 2) % 2 == 0) _call(attacker, abi.encodeCall(MHAccumulationCircle.deployIdle, ()));
        uint256 pick = (seed >> 3) % 20;
        uint256 t;
        CircleStatus st = circle.status();
        if (st == CircleStatus.Pending) {
            t = circle.joinDeadline() + 1;
        } else if (st == CircleStatus.Active) {
            uint256 r = circle.currentRound();
            uint256 start = circle.startTime();
            if (r == 0) t = start;
            else if (pick < 12) t = start + r * circle.roundDuration(); // the next round opens
            else if (pick < 15) t = circle.roundDeadline(r) + circle.grace() + 1; // grace of round r ends
            else if (pick < 18) t = circle.roundDeadline(r) + circle.grace() + circle.cure() + 1; // its cure ends
            else t = circle.roundDeadline(rounds) + circle.grace() + circle.cure() + 1; // maturity (R1-08)
        } else {
            t = block.timestamp + 1 days;
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (t > block.timestamp) vm.warp(t);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + _bound(secs, 1 minutes, 12 days));
    }

    // ================================================================ Vault, USDC and outside actors

    function vaultYield(uint256 amount) external {
        uint256 ta = morpho.totalAssets();
        if (ta == 0 || usdc.paused()) return;
        morpho.mockYield(_bound(amount, 1, ta / 20 + 1)); // up to ~5%
    }

    function vaultLoss(uint256 amount) external {
        uint256 ta = morpho.totalAssets();
        if (ta < 20 || usdc.paused() || _h(amount) % 12 != 0) return;
        morpho.mockLoss(_bound(amount, 1, ta / 20)); // up to 5%
        ghostLossSeen = true;
    }

    function vaultLiquidity(uint256 seed) external {
        seed = _h(seed);
        uint256 pick = seed % 4;
        if (pick == 0) morpho.mockSetLiquidity(0);
        else if (pick == 1) morpho.mockSetLiquidity(_bound(seed >> 2, 1, morpho.totalAssets() + 1));
        else morpho.mockSetLiquidity(type(uint256).max);
    }

    function vaultPreviewDiscount(uint256 amount) external {
        if (_h(amount) % 12 != 0) {
            morpho.mockSetPreviewRedeemDiscount(0);
        } else {
            morpho.mockSetPreviewRedeemDiscount(_bound(amount, 1, 5e6));
            ghostLossSeen = true;
        }
    }

    function vaultGates(uint256 seed) external {
        seed = _h(seed);
        morpho.mockSetDepositsBlocked(seed % 4 == 0);
        morpho.mockSetExitsBlocked((seed >> 2) % 4 == 0);
    }

    /// @dev Audit R1-03: an adapter's `realAssets` reverts now and then, so the vault cannot value, take or return
    ///      anything (share transfers still work); the curator repairs it on the next call.
    function vaultBreak(uint256 seed) external {
        if (morpho.navBroken()) morpho.mockSetNavBroken(false);
        else if (_h(seed) % 8 == 0) morpho.mockSetNavBroken(true);
    }

    /// @dev NAV as the invariant checks see it: the circle's own while the vault works, else the true value.
    function navOf() external view returns (uint256) {
        if (!morpho.navBroken()) return circle.nav();
        uint256 held = circle.vaultShares();
        return circle.idleAssets() + (held == 0 ? 0 : morpho.convertToAssets(held));
    }

    /// @dev Someone sends USDC straight to the circle.
    function donate(uint256 amount) external {
        if (address(circle) == address(0) || usdc.paused()) return;
        amount = _bound(amount, 1, 1_000e6);
        address donor = makeAddr("donor");
        usdc.mint(donor, amount);
        vm.prank(donor);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(address(circle), amount);
        ghostDonatedUsdc += amount;
    }

    /// @dev Someone deposits into the vault and sends the vault shares to the circle. Only for a circle that uses
    ///      this vault: any other token sent to a circle is out of scope (no rescue function, by design).
    function donateShares(uint256 amount) external {
        if (
            address(circle) == address(0) || !hasVault || usdc.paused() || morpho.depositsBlocked()
                || morpho.navBroken()
        ) return;
        amount = _bound(amount, 1e6, 1_000e6);
        address donor = makeAddr("donor");
        usdc.mint(donor, amount);
        vm.startPrank(donor);
        usdc.approve(address(morpho), amount);
        uint256 shares = morpho.deposit(amount, donor);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        morpho.transfer(address(circle), shares);
        vm.stopPrank();
        ghostDonatedShares += shares;
    }

    /// @dev Circle (the USDC issuer) pauses USDC now and then, and unpauses it on the next call.
    function toggleUsdcPause(uint256 seed) external {
        if (usdc.paused()) usdc.unpause();
        else if (_h(seed) % 4 == 0) usdc.pause();
    }

    /// @dev Circle (the USDC issuer) blacklists a member or the treasury now and then; the next call lifts it.
    function toggleBlacklist(uint256 who) external {
        if (address(circle) == address(0)) return;
        if (blacklisted != address(0)) {
            usdc.setBlacklisted(blacklisted, false);
            blacklisted = address(0);
            return;
        }
        who = _h(who);
        if (who % 3 != 0) return;
        blacklisted = (who >> 2) % 5 == 0 ? treasury : _member(who >> 4);
        usdc.setBlacklisted(blacklisted, true);
    }

    /// @dev An admin or the attacker calls any circle function with arbitrary arguments (§4.7 invariant 4).
    function adminPoke(uint256 actorSeed, uint256 fnSeed, uint256 arg) external {
        if (!_ensure(actorSeed)) return;
        address actor = _admins[actorSeed % _admins.length];
        uint256 pick = fnSeed % 21;
        if (actor == guardian && (pick == 2 || pick == 0)) pick = 3; // real Guardian powers have their own actions
        address target = _pool[arg % POOL];
        bytes memory data;
        if (pick == 0) {
            data = abi.encodeCall(MHAccumulationCircle.emergencyExit, (arg % 2e20));
        } else if (pick == 1) {
            data = abi.encodeCall(MHAccumulationCircle.extendDeadline, (arg % 8 days));
        } else if (pick == 2) {
            data = abi.encodeCall(MHAccumulationCircle.guardianCancel, ());
        } else if (pick == 3) {
            data = abi.encodeCall(MHAccumulationCircle.pullFromVault, (arg % 2e20));
        } else if (pick == 4) {
            data = abi.encodeCall(MHAccumulationCircle.deployIdle, ());
        } else if (pick == 5) {
            data = abi.encodeCall(MHAccumulationCircle.flagRound, (arg % 10));
        } else if (pick == 6) {
            _finalize(actor);
            return;
        } else if (pick == 7) {
            data = abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (target));
        } else if (pick == 8) {
            data = abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (actor));
        } else if (pick == 9) {
            data = abi.encodeCall(MHAccumulationCircle.sweepDonations, ());
        } else if (pick == 10) {
            data = abi.encodeCall(MHAccumulationCircle.sweepResidual, ());
        } else if (pick == 11) {
            data = abi.encodeCall(MHAccumulationCircle.claim, ());
        } else if (pick == 12) {
            data = abi.encodeCall(MHAccumulationCircle.claimInKind, ());
        } else if (pick == 13) {
            data = abi.encodeCall(MHAccumulationCircle.exitEarly, ());
        } else if (pick == 14) {
            data = abi.encodeCall(MHAccumulationCircle.contribute, (arg % 10, type(uint256).max));
        } else if (pick == 15) {
            data = abi.encodeCall(MHAccumulationCircle.join, (circle.termsHash(), 0));
        } else if (pick == 16) {
            data = abi.encodeCall(MHAccumulationCircle.initialize, (_paramsFrom(arg)));
        } else if (pick == 18) {
            data = abi.encodeCall(MHAccumulationCircle.cancelExpired, ());
        } else if (pick == 19) {
            data = abi.encodeCall(MHAccumulationCircle.pullFromVault, (arg % 2e20));
        } else if (pick == 20) {
            if (actor == guardian) actor = attacker; // the Guardian's own forceExit has its own action
            data = abi.encodeCall(MHAccumulationCircle.forceExit, (adapter, "", arg % 2e9));
        } else {
            data = abi.encodeCall(IMHCircle.claimOwed, ());
        }
        if (pick == 7 || pick == 8) _expectSettle(pick == 7 ? target : actor);
        _call(actor, data);
    }

    // ================================================================ End-of-run drive (liveness, §4.7 inv. 7)

    /// @notice From whatever state the run left, reaches an end state using only time, permissionless calls and
    ///         members acting for themselves, with the vault left as it is (possibly illiquid, gated, discounted or
    ///         unable to value its shares): cash settlement where liquidity allows, in kind otherwise. Then pays
    ///         every claim and sweeps. Asserts each step that must succeed. Not a fuzz target. Audit 2 R1-12: the
    ///         broken-vault state is resolved with the permissionless `cancelExpired` (spec §4.7 invariant 7 as
    ///         written), not the Guardian.
    function driveToEnd() external {
        if (address(circle) == address(0)) return;
        if (usdc.paused()) usdc.unpause(); // the issuer eventually unpauses; timer functions need it
        bool broken = morpho.navBroken();
        CircleStatus st = circle.status();
        if (st == CircleStatus.Pending) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= circle.joinDeadline()) vm.warp(uint256(circle.joinDeadline()) + 1);
            _must(attacker, abi.encodeCall(MHAccumulationCircle.cancelUnjoined, ()), "cancelUnjoined");
        } else if (
            broken && circle.vaultShares() != 0 && (st == CircleStatus.Active || st == CircleStatus.Matured)
        ) {
            // Audit R1-03 / R2-09: the vault cannot value its shares; once it has not for `EXPIRY_DELAY`, anyone's
            // NAV-free cancel (Active or Matured) is the exit, then every claim is paid in kind.
            uint256 gate = uint256(circle.lastLive()) + K.EXPIRY_DELAY + 1;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < gate) vm.warp(gate);
            _must(
                attacker, abi.encodeCall(MHAccumulationCircle.cancelExpired, ()), "cancelExpired (NAV broken)"
            );
        } else if (st == CircleStatus.Active) {
            uint256 maturity = circle.roundDeadline(rounds) + circle.grace() + circle.cure() + 1;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < maturity) vm.warp(maturity);
            assertTrue(_finalize(attacker), "finalize");
        }
        for (uint256 i; i < n; ++i) {
            _endMember(_pool[i]);
        }
        st = circle.status();
        assertTrue(st == CircleStatus.Closed || st == CircleStatus.Cancelled, "ended");
        if (circle.idleAssets() != 0 || circle.vaultShares() != 0) {
            _must(attacker, abi.encodeCall(MHAccumulationCircle.sweepResidual, ()), "sweepResidual");
        }
        for (uint256 i; i <= n; ++i) {
            address a = i == n ? treasury : _pool[i];
            if (usdc.isBlacklisted(a)) usdc.setBlacklisted(a, false);
            if (circle.owed(a) != 0) _must(a, abi.encodeCall(IMHCircle.claimOwed, ()), "claimOwed");
            if (circle.owedShares(a) != 0) {
                _must(a, abi.encodeCall(MHAccumulationCircle.claimOwedShares, ()), "claimOwedShares");
            }
        }
        bool surplusUsdc = usdc.balanceOf(address(circle)) != 0;
        bool surplusShares = hasVault && morpho.balanceOf(address(circle)) != 0;
        if (surplusUsdc || surplusShares) {
            _must(attacker, abi.encodeCall(MHAccumulationCircle.sweepDonations, ()), "sweepDonations");
        }
        assertEq(usdc.balanceOf(address(circle)), 0, "every USDC unit paid out");
        assertEq(morpho.balanceOf(address(circle)), 0, "every vault share paid out");
        assertEq(circle.totalShares(), circle.residualShares(), "only worthless residual shares may be left");
        assertEq(circle.owedTotal(), 0, "no queued payout left");
        assertEq(circle.owedSharesTotal(), 0, "no queued vault shares left");
        if (broken) morpho.mockSetNavBroken(false); // the curator repairs the vault after the circle has ended
    }

    /// @dev `finalize` with an independent check of its outcome (audit R1-31): every delinquent member keeps
    ///      exactly `min(acc, floor(toShares(principal)))` when someone is compliant, and the treasury gets at most
    ///      the fee on returned exit forfeits (audit R1-09).
    function _finalize(address actor) internal returns (bool ok) {
        bool expectable = circle.status() == CircleStatus.Active
            && !(morpho.navBroken() && circle.vaultShares() != 0) && !usdc.paused()
            // Audit 2 R2-06: or as soon as every member has exited early.
            // forge-lint: disable-next-line(block-timestamp)
            && (block.timestamp > circle.roundDeadline(rounds) + circle.grace() + circle.cure()
                || circle.settledCount() == n);
        uint256 nav;
        uint256 total;
        bool anyCompliant;
        uint256 remaining;
        uint256 expectedForfeit;
        uint256 residualBefore = circle.residualShares();
        if (expectable) {
            nav = circle.nav();
            total = circle.totalShares();
            for (uint256 i; i < n; ++i) {
                IMHAccumulationCircle.MemberState memory st = circle.memberState(_pool[i]);
                if (st.exited) continue;
                remaining += st.accShares;
                if (st.paidRounds == rounds) anyCompliant = true;
            }
            for (uint256 i; i < n; ++i) {
                IMHAccumulationCircle.MemberState memory st = circle.memberState(_pool[i]);
                uint256 keep = st.accShares;
                if (anyCompliant && !st.exited && st.paidRounds != rounds) {
                    if (Math.mulDiv(keep, nav + 1, total + VS) > st.principal) {
                        keep = Math.mulDiv(st.principal, total + VS, nav + 1);
                    }
                }
                _expectedAcc[_pool[i]] = keep;
                expectedForfeit += st.accShares - keep;
            }
            // Every capped share joins the forfeit pool; with nobody left it is returned as claims (R1-09).
            expectedForfeit = remaining == 0 ? 0 : expectedForfeit + circle.forfeitShares();
            _finalizeFeeCap = remaining == 0
                ? Math.mulDiv(circle.forfeitShares(), nav + 1, total + VS) * feeBps / K.BPS + 2
                : 0;
            _finalizeVaultPart = nav - circle.idleAssets();
            _finalizeHeld = circle.vaultShares();
        }
        ok = _call(actor, abi.encodeCall(MHAccumulationCircle.finalize, ()));
        if (!ok) return false;
        if (!expectable) {
            _violate("finalize succeeded outside its window or with a broken vault");
            return true;
        }
        finalizedOnce = true;
        navAtFinalize = nav;
        totalAtFinalize = total;
        for (uint256 i; i < n; ++i) {
            if (circle.memberState(_pool[i]).accShares != _expectedAcc[_pool[i]]) {
                _violate("finalize retained shares != independent cap");
            }
        }
        if (circle.forfeitSnap() != expectedForfeit) _violate("finalize forfeit pool != independent sum");
        if (circle.residualShares() != residualBefore) _violate("finalize moved shares to residual");
    }

    function _endMember(address m) internal {
        IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
        if (circle.status() == CircleStatus.Matured && !st.settled) {
            _expectSettle(m);
            if (_call(attacker, abi.encodeCall(MHAccumulationCircle.settleMember, (m)))) return;
            _expectSettle(m);
            _must(m, abi.encodeCall(MHAccumulationCircle.settleMemberInKind, (m)), "settleMemberInKind");
        } else if (st.claimShares != 0) {
            if (_call(m, abi.encodeCall(MHAccumulationCircle.claim, ()))) return;
            _must(m, abi.encodeCall(MHAccumulationCircle.claimInKind, ()), "claimInKind");
        }
    }

    // ================================================================ Internal: setup

    function _ensure(uint256 seed) internal returns (bool) {
        if (address(circle) != address(0)) return true;
        seed = _h(seed);
        AccumulationParams memory p = _paramsFrom(seed);
        vm.prank(operator);
        circle = MHAccumulationCircle(factory.createAccumulation(p));
        usdc.watch(address(circle));
        morpho.watch(address(circle));
        n = p.members.length;
        rounds = p.config.totalRounds;
        feeBps = p.config.feeBps;
        hasVault = p.config.vault != address(0);
        // forge-lint: disable-next-line(incorrect-shift)
        unreliable = (seed >> 200) & (seed >> 210) & ((1 << n) - 1); // each member with probability ~1/4
        _skipSalt = seed;
        if ((seed >> 220) % 4 != 0) {
            for (uint256 i; i < n; ++i) {
                _join(_pool[i]);
            }
        }
        return true;
    }

    function _paramsFrom(uint256 seed) internal view returns (AccumulationParams memory p) {
        uint256 count = _bound(seed, 2, POOL);
        uint64 round = uint64(_bound(seed >> 64, 7 days, 14 days));
        uint64 joinBy = uint64(block.timestamp + _bound(seed >> 160, 1 hours, 10 days));
        p.config = AccumulationConfig({
            circleId: keccak256(abi.encode("accumulation-invariant", seed)),
            contribution: _bound(seed >> 8, 100, 50_000) * K.CENT, // $1 … $500
            feeBps: uint16(_bound(seed >> 32, 0, K.MAX_ACCUMULATION_FEE_BPS)),
            roundDuration: round,
            grace: uint64(_bound(seed >> 96, K.MIN_GRACE, round - 1)),
            cure: uint64(_bound(seed >> 128, K.MIN_CURE, 10 days)),
            joinDeadline: joinBy,
            plannedStart: uint64(_bound(seed >> 176, block.timestamp, uint256(joinBy) + 10 days)),
            totalRounds: uint32(_bound(seed >> 48, 1, 8)),
            vault: (seed >> 230) % 4 == 0 || !registry.isAllowedVault(address(morpho))
                ? address(0)
                : address(morpho),
            lockUntilMaturity: (seed >> 240) % 4 == 0
        });
        p.members = new address[](count);
        for (uint256 i; i < count; ++i) {
            p.members[i] = _pool[i];
        }
    }

    // ================================================================ Internal: actions

    function _h(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    function _member(uint256 who) internal view returns (address) {
        return _pool[who % n];
    }

    function _anyone(uint256 seed) internal view returns (address) {
        uint256 k = seed % (n + _admins.length);
        return k < n ? _pool[k] : _admins[k - n];
    }

    function _notGuardian(uint256 seed) internal view returns (address a) {
        a = _anyone(seed);
        if (a == guardian) a = attacker;
    }

    function _join(address m) internal {
        if (circle.status() != CircleStatus.Pending) return;
        _call(m, abi.encodeCall(MHAccumulationCircle.join, (circle.termsHash(), 0)));
    }

    function _payReliable() internal {
        if (circle.status() != CircleStatus.Active) return;
        uint256 last = circle.currentRound();
        uint256 first = last > 1 ? last - 1 : 1;
        for (uint256 r = first; r <= last && last != 0; ++r) {
            for (uint256 i; i < n; ++i) {
                bool skips =
                    (unreliable >> i) & 1 == 1 && uint256(keccak256(abi.encode(_skipSalt, i, r))) % 3 == 0;
                if (!skips) _payRound(_pool[i], r);
            }
        }
    }

    /// @dev As the app does it: approve exactly the contribution, then `contribute(round, contribution)`.
    function _payRound(address m, uint256 round) internal {
        uint256 due = circle.amountDue(m, round);
        if (due == 0 || !_fund(m, due)) return;
        _call(m, abi.encodeCall(MHAccumulationCircle.contribute, (round, due)));
    }

    function _fund(address m, uint256 amount) internal returns (bool) {
        if (usdc.paused() || usdc.isBlacklisted(m)) return false;
        usdc.mint(m, amount);
        vm.prank(m);
        usdc.approve(address(circle), amount);
        return true;
    }

    function _must(address actor, bytes memory data, string memory what) internal {
        assertTrue(_call(actor, data), what);
    }

    // ================================================================ Internal: expectations (spec formula)

    /// @dev Values `m`'s settlement at this NAV exactly as spec §4.5 states it (independent evaluation).
    function _expectSettle(address m) internal {
        delete _expect;
        if (circle.status() != CircleStatus.Matured) return;
        IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
        if (st.slot == 0 || st.settled) return;
        if (morpho.navBroken() && circle.vaultShares() != 0) return; // any settlement must revert
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        Expect memory e;
        e.active = true;
        e.principal = st.principal;
        e.compliant = st.paidRounds == rounds;
        e.heldShares = circle.vaultShares();
        e.navVaultPart = nav - circle.idleAssets();
        e.nav = nav;
        e.total = total;
        // Spec §4.5 as amended in audit round 1: the bonus and the fee on earnings apply to compliant members and,
        // when nobody is compliant, to everyone (R1-10); a delinquent member is paid its retained shares' value
        // with no fee and no second cap (R1-11).
        e.shares = st.accShares;
        bool sharesForfeit = e.compliant || circle.compliantSnap() == 0;
        if (sharesForfeit) {
            uint256 base = circle.bonusBase();
            if (base != 0) e.bonus = Math.mulDiv(circle.forfeitSnap(), st.accShares, base);
            e.shares += e.bonus;
        }
        e.gross = Math.mulDiv(e.shares, nav + 1, total + VS);
        if (sharesForfeit && e.gross > e.principal) e.fee = (e.gross - e.principal) * feeBps / K.BPS;
        _expect = e;
    }

    function _expectExit(address m) internal {
        delete _expect;
        IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
        _expect.principal = st.principal;
    }

    function _violate(string memory what) internal {
        if (bytes(ghostViolation).length == 0) ghostViolation = what;
    }

    // ================================================================ Internal: the call wrapper

    struct Flows {
        uint256 tUsdc;
        uint256 tShares;
        uint256 mUsdc;
        uint256 mShares;
    }

    function _flows(address m) internal view returns (Flows memory f) {
        address c = address(circle);
        f.tUsdc = usdc.sent(c, treasury) + circle.owed(treasury);
        f.tShares = morpho.sent(c, treasury) + circle.owedShares(treasury);
        if (m != address(0)) {
            f.mUsdc = usdc.sent(c, m) + circle.owed(m);
            f.mShares = morpho.sent(c, m) + circle.owedShares(m);
        }
    }

    /// @dev Every circle call: prank, measure gas, attribute treasury inflow, check a settlement or an exit against
    ///      the expectation recorded just before it.
    function _call(address actor, bytes memory data) internal returns (bool ok) {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        address subject = _subject(actor, selector, data);
        Flows memory before = _flows(subject);
        bool activeBroken =
            circle.status() == CircleStatus.Active && morpho.navBroken() && circle.vaultShares() != 0;
        bool navUnreadable = morpho.navBroken() && circle.vaultShares() != 0;
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = block.timestamp > uint256(circle.lastLive()) + K.EXPIRY_DELAY;
        vm.prank(actor);
        uint256 g = gasleft();
        (ok,) = address(circle).call(data);
        g -= gasleft();
        if (!ok) return false;
        if (activeBroken && selector == MHAccumulationCircle.flagRound.selector) {
            _violate("a strike was recorded while the vault could not value shares (R1-03)");
        }
        if (selector == MHAccumulationCircle.cancelExpired.selector && (!navUnreadable || !expired)) {
            _violate("cancelExpired outside a 90-day vault outage (audit 2 R1-05..R1-07)");
        }
        successes[selector] += 1;
        if (g > ghostMaxGas) {
            ghostMaxGas = g;
            ghostMaxGasSelector = selector;
        }
        Flows memory afterF = _flows(subject);
        uint256 dUsdc = afterF.tUsdc - before.tUsdc;
        uint256 dShares = afterF.tShares - before.tShares;
        if (selector == MHAccumulationCircle.sweepResidual.selector) {
            ghostResidualUsdc += dUsdc;
            ghostResidualShares += dShares;
        } else if (selector == MHAccumulationCircle.sweepDonations.selector) {
            ghostDonSweptUsdc += dUsdc;
            ghostDonSweptShares += dShares;
        } else if (selector == MHAccumulationCircle.finalize.selector) {
            // Audit R1-09: the fee on exit forfeits returned when nobody remains, paid in kind.
            ghostFeeUsdc += dUsdc;
            ghostFeeShares += dShares;
            uint256 sharesValue = dShares == 0 ? 0 : Math.mulDiv(dShares, _finalizeVaultPart, _finalizeHeld);
            if (dUsdc + sharesValue > _finalizeFeeCap) {
                _violate("finalize fee above the fee on forfeits");
            }
        } else if (
            selector == MHAccumulationCircle.settleMember.selector
                || selector == MHAccumulationCircle.settleMemberInKind.selector
        ) {
            ghostFeeUsdc += dUsdc;
            ghostFeeShares += dShares;
            _checkSettlement(selector, before, afterF);
        } else {
            ghostUnexpectedUsdc += dUsdc;
            ghostUnexpectedShares += dShares;
            if (selector == MHAccumulationCircle.exitEarly.selector) {
                if (afterF.mUsdc - before.mUsdc > _expect.principal) {
                    _violate("exitEarly paid above principal");
                }
            }
        }
    }

    function _subject(address actor, bytes4 selector, bytes memory data) internal pure returns (address) {
        if (
            selector == MHAccumulationCircle.settleMember.selector
                || selector == MHAccumulationCircle.settleMemberInKind.selector
        ) {
            bytes memory args = new bytes(data.length - 4);
            for (uint256 i; i < args.length; ++i) {
                args[i] = data[i + 4];
            }
            return abi.decode(args, (address));
        }
        if (selector == MHAccumulationCircle.exitEarly.selector) return actor;
        return address(0);
    }

    /// @dev §4.7 invariant 6 per settlement: the fee is charged only on earnings, a delinquent member gets at most
    ///      its principal, Σ bonus ≤ forfeitSnap; a cash settlement matches the spec formula exactly.
    function _checkSettlement(bytes4 selector, Flows memory b, Flows memory a) internal {
        Expect memory e = _expect;
        if (!e.active) {
            _violate("settlement without expectation");
            return;
        }
        ghostBonusSum += e.bonus;
        uint256 feeUsdc = a.tUsdc - b.tUsdc;
        uint256 feeShares = a.tShares - b.tShares;
        uint256 gotUsdc = a.mUsdc - b.mUsdc;
        uint256 gotShares = a.mShares - b.mShares;
        uint256 value;
        if (selector == MHAccumulationCircle.settleMember.selector) {
            if (feeShares != 0 || gotShares != 0) _violate("cash settlement moved vault shares");
            if (feeUsdc != e.fee) _violate("cash settlement fee != spec fee");
            if (gotUsdc != e.gross - e.fee) _violate("cash settlement payout != spec payout");
            value = gotUsdc;
        } else {
            // In kind: value vault shares at the circle's own NAV price for this transaction.
            uint256 feeValue = feeUsdc + _shareValue(feeShares, e);
            value = gotUsdc + _shareValue(gotShares, e);
            if (feeValue > e.fee + 1) _violate("in-kind fee above the fee on earnings");
            if (value + feeValue > e.gross + 1) {
                _violate("in-kind settlement worth more than its cash value");
            }
        }
        // A delinquent member gets at most its principal at the finalize price, scaled by the share price's move
        // since (audit R1-11: its retained shares earn post-maturity yield; the cap applied once, at finalize).
        if (!e.compliant && circle.compliantSnap() != 0) {
            uint256 bound = Math.mulDiv(
                e.principal + 1, (e.nav + 1) * (totalAtFinalize + VS), (e.total + VS) * (navAtFinalize + 1)
            );
            if (value > bound + 1) {
                _violate("a delinquent member got more than its principal (at the finalize price)");
            }
        }
        _settledPrincipal.push(e.principal);
        _settledValue.push(e.shares);
        _settledCompliant.push(e.compliant);
    }

    function _shareValue(uint256 shares, Expect memory e) internal pure returns (uint256) {
        if (shares == 0 || e.heldShares == 0) return 0;
        return Math.mulDiv(shares, e.navVaultPart, e.heldShares);
    }
}
