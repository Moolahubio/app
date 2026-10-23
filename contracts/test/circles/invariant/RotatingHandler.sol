// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { MHRotatingCircle } from "../../../src/circles/MHRotatingCircle.sol";
import { MHCircleFactory } from "../../../src/circles/MHCircleFactory.sol";
import { MHCircleRegistry } from "../../../src/circles/MHCircleRegistry.sol";
import { MHCircleConstants as K } from "../../../src/circles/MHCircleConstants.sol";
import { IMHCircle } from "../../../src/circles/interfaces/IMHCircle.sol";
import { IMHRotatingCircle } from "../../../src/circles/interfaces/IMHRotatingCircle.sol";
import { CircleStatus, RotatingConfig, RotatingParams } from "../../../src/circles/MHCircleTypes.sol";

import { MockUSDC } from "../../mocks/MockUSDC.sol";

/// @notice Invariant handler for one `MHRotatingCircle` per run (spec §4.7). The first call of a run creates the
///         circle from its seed (n, c, fee, σ mode, timings and which members are unreliable all vary), so 10k runs
///         cover 10k parameter sets. Actors: the members, the Gov Safe, the Timelock, the Guardian, the operator,
///         the treasury and an attacker. Every circle call goes through `_call`, which keeps the ghost ledger:
///         what reached the treasury by category, the largest gas used, and the cancellation record (net positions,
///         defaulters, penalties) read from the logs. Circle reverts are expected and never fail the run.
contract RotatingHandler is Test {
    uint256 internal constant POOL = 8;

    MockUSDC public immutable usdc;
    MHCircleFactory public immutable factory;
    MHCircleRegistry public immutable registry;
    address public immutable gov;
    address public immutable timelock;
    address public immutable guardian;
    address public immutable operator;
    address public immutable treasury;
    address public immutable attacker;

    MHRotatingCircle public circle;
    address[] internal _pool;
    address[] internal _admins;

    // ---------------------------------------------------------------- Run parameters

    uint256 public n;
    uint256 public contribution;
    uint256 public feeEach;
    bool public allSigma100;
    /// @dev Bitmap over member indices: members that stop paying in `payReliable` and in the end-of-run drive,
    ///      from their `stopRound` on (D1–D4 style defaults).
    uint256 public unreliable;
    mapping(uint256 index => uint256 round) public stopRound;
    /// @dev At most one address is blacklisted at a time.
    address public blacklisted;

    // ---------------------------------------------------------------- Ghost ledger

    uint256 public ghostDonated;
    uint256 public ghostDonSwept;
    uint256 public ghostFees;
    uint256 public ghostResidual;
    /// @dev Anything that reached the treasury outside flushFees / sweepResidual / sweepDonations.
    uint256 public ghostUnexpected;
    uint256 public ghostMaxGas;
    bytes4 public ghostMaxGasSelector;
    mapping(bytes4 selector => uint256 count) public successes;

    // ---------------------------------------------------------------- Cancellation record (from the logs)

    bool public cancelled;
    uint8 public cancelReason;
    uint256 public penaltyTotal;
    mapping(address member => uint256 e) public cancelE;
    mapping(address member => bool d) public isDefaulter;
    /// @dev Audit R1-31: the defaulter set derived independently from public state just before each successful
    ///      `cancelStalled` (unpaid in the settling round, security below c, and not the recipient whose payout can
    ///      absorb its own part), and the number of mismatches with the circle's `Defaulted` events.
    mapping(address member => bool d) public expectedDefaulter;
    uint256 public defaulterMismatches;
    /// @dev Audit R2-11 / audit 2 R1-12: stall cancellations that succeeded while USDC blacklisted the circle.
    uint256 public blacklistedStalls;
    /// @dev Audit 2 R1-11: DEFAULT strikes on a member that had paid a round after the stalled one.
    uint256 public prepaidDefaulters;
    /// @dev Members that had been paid out when the circle was cancelled (each paid one fee).
    uint256 public paidOutAtCancel;

    constructor(
        MockUSDC usdc_,
        MHCircleFactory factory_,
        MHCircleRegistry registry_,
        address gov_,
        address timelock_,
        address guardian_,
        address operator_,
        address treasury_,
        address attacker_
    ) {
        usdc = usdc_;
        factory = factory_;
        registry = registry_;
        gov = gov_;
        timelock = timelock_;
        guardian = guardian_;
        operator = operator_;
        treasury = treasury_;
        attacker = attacker_;
        for (uint256 i; i < POOL; ++i) {
            _pool.push(makeAddr(string.concat("rotMember", vm.toString(i))));
        }
        _admins.push(gov_);
        _admins.push(timelock_);
        _admins.push(guardian_);
        _admins.push(operator_);
        _admins.push(treasury_);
        _admins.push(attacker_);
    }

    // ================================================================ Views for the invariant contract

    function admins() external view returns (address[] memory) {
        return _admins;
    }

    function sigmaOf(address m) external view returns (uint256) {
        return circle.memberState(m).securityBps;
    }

    // ================================================================ Actions

    function joinAll(uint256 seed) external {
        if (!_ensure(seed)) return;
        for (uint256 i; i < n; ++i) {
            _join(_pool[i], uint256(keccak256(abi.encode(seed, i))));
        }
    }

    function join(uint256 who, uint256 col) external {
        if (!_ensure(who)) return;
        _join(_member(who), col);
    }

    function depositCollateral(uint256 who, uint256 amount) external {
        if (!_ensure(who)) return;
        address m = _member(who);
        amount = _bound(amount, 1, 10 * contribution);
        if (!_fund(m, amount)) return;
        _call(m, abi.encodeCall(MHRotatingCircle.depositCollateral, (amount)));
    }

    function contribute(uint256 who, uint256 roundSeed) external {
        if (!_ensure(who)) return;
        uint256 last = circle.currentRound();
        uint256 first = circle.nextSettle();
        if (last < first) return;
        _payRound(_member(who), _bound(roundSeed, first, last));
    }

    /// @dev Every reliable member pays every open round it still owes.
    function payReliable(uint256 seed) external {
        if (!_ensure(seed)) return;
        _payReliable();
    }

    function withdrawSecurity(uint256 who, uint256 amount) external {
        if (!_ensure(who)) return;
        address m = _member(who);
        uint256 sec = circle.memberState(m).sec;
        if (sec == 0) return;
        _call(m, abi.encodeCall(MHRotatingCircle.withdrawSecurity, (_bound(amount, 1, sec))));
    }

    function claim(uint256 who) external {
        if (!_ensure(who)) return;
        _call(_member(who), abi.encodeCall(MHRotatingCircle.claim, ()));
    }

    function claimOwed(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(IMHCircle.claimOwed, ()));
    }

    function settleRound(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.settleRound, ()));
    }

    function cancelStalled(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.cancelStalled, ()));
    }

    function cancelUnjoined(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.cancelUnjoined, ()));
    }

    function flushFees(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.flushFees, ()));
    }

    function sweepDonations(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.sweepDonations, ()));
    }

    function sweepResidual(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        _call(_anyone(actorSeed), abi.encodeCall(MHRotatingCircle.sweepResidual, ()));
    }

    function guardianCancel(uint256 actorSeed) external {
        if (!_ensure(actorSeed)) return;
        // The real Guardian rarely acts, so most runs live long enough to settle rounds. Seeds are hashed because
        // the fuzzer favours edge values such as 0.
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 16 == 0 ? guardian : _notGuardian(actorSeed >> 4);
        _call(actor, abi.encodeCall(MHRotatingCircle.guardianCancel, ()));
    }

    function extendDeadline(uint256 actorSeed, uint256 by) external {
        if (!_ensure(actorSeed)) return;
        actorSeed = _h(actorSeed);
        address actor = actorSeed % 2 == 0 ? guardian : _anyone(actorSeed >> 1);
        _call(actor, abi.encodeCall(MHRotatingCircle.extendDeadline, (_bound(by, 0, 8 days))));
    }

    /// @dev The app and the keeper at work, then time moves on: reliable members usually pay what is open, the
    ///      keeper often settles, then time jumps to the next gate that matters (the join deadline, the next
    ///      round's opening, the end of the settling round's grace, or the end of its cure).
    function advance(uint256 seed) external {
        if (!_ensure(seed)) return;
        seed = _h(seed);
        if (seed % 4 != 0) _payReliable();
        if ((seed >> 2) % 2 == 0) _call(attacker, abi.encodeCall(MHRotatingCircle.settleRound, ()));
        seed = (seed >> 3) % 20; // gates: next opening 50%, grace end 35%, cure end 15%
        uint256 t;
        if (circle.status() == CircleStatus.Pending) {
            t = circle.joinDeadline() + 1;
        } else if (circle.status() == CircleStatus.Active) {
            uint256 s = circle.nextSettle();
            uint256 graceEnd = circle.roundDeadline(s) + circle.grace();
            uint256 open = circle.startTime() + (s - 1) * circle.roundDuration();
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < open) t = open; // the settling round opens first
            else if (seed < 10) t = open + circle.roundDuration(); // the next round opens
            else if (seed < 17) t = graceEnd + 1;
            else t = graceEnd + circle.cure() + 1;
        } else {
            t = block.timestamp + 1 days;
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (t > block.timestamp) vm.warp(t);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + _bound(secs, 1 minutes, 12 days));
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
        ghostDonated += amount;
    }

    /// @dev Circle (the USDC issuer) pauses USDC now and then, and unpauses it on the next call.
    function toggleUsdcPause(uint256 seed) external {
        if (usdc.paused()) usdc.unpause();
        else if (_h(seed) % 4 == 0) usdc.pause();
    }

    /// @dev Circle (the USDC issuer) blacklists a member, the treasury or (audit 2 R1-12) the circle itself now and
    ///      then; the next call lifts it. While the circle is blacklisted nobody can pay it, so no stall may run
    ///      (audit R2-11).
    function toggleBlacklist(uint256 who) external {
        if (address(circle) == address(0)) return;
        if (blacklisted != address(0)) {
            usdc.setBlacklisted(blacklisted, false);
            blacklisted = address(0);
            return;
        }
        who = _h(who);
        if (who % 3 != 0) return;
        uint256 pick = (who >> 2) % 6;
        blacklisted = pick == 0 ? treasury : pick == 1 ? address(circle) : _member(who >> 4);
        usdc.setBlacklisted(blacklisted, true);
    }

    /// @dev An admin or the attacker calls any circle function with arbitrary arguments (§4.7 invariant 4).
    function adminPoke(uint256 actorSeed, uint256 fnSeed, uint256 arg) external {
        if (!_ensure(actorSeed)) return;
        address actor = _admins[actorSeed % _admins.length];
        bytes memory data;
        uint256 pick = fnSeed % 15;
        if (pick == 7 && actor == guardian) pick = 8; // the real Guardian's cancel has its own action
        if (pick == 0) data = abi.encodeCall(MHRotatingCircle.withdrawSecurity, (arg % 1e12));
        else if (pick == 1) data = abi.encodeCall(MHRotatingCircle.claim, ());
        else if (pick == 2) data = abi.encodeCall(MHRotatingCircle.depositCollateral, (arg % 1e12));
        else if (pick == 3) data = abi.encodeCall(MHRotatingCircle.contribute, (arg % 10, type(uint256).max));
        else if (pick == 4) data = abi.encodeCall(MHRotatingCircle.join, (circle.termsHash(), arg % 1e9));
        else if (pick == 5) data = abi.encodeCall(MHRotatingCircle.settleRound, ());
        else if (pick == 6) data = abi.encodeCall(MHRotatingCircle.cancelStalled, ());
        else if (pick == 7) data = abi.encodeCall(MHRotatingCircle.guardianCancel, ());
        else if (pick == 8) data = abi.encodeCall(MHRotatingCircle.extendDeadline, (arg % 8 days));
        else if (pick == 9) data = abi.encodeCall(MHRotatingCircle.flushFees, ());
        else if (pick == 10) data = abi.encodeCall(MHRotatingCircle.sweepDonations, ());
        else if (pick == 11) data = abi.encodeCall(MHRotatingCircle.sweepResidual, ());
        else if (pick == 12) data = abi.encodeCall(IMHCircle.claimOwed, ());
        else if (pick == 13) data = abi.encodeCall(MHRotatingCircle.cancelUnjoined, ());
        else data = abi.encodeCall(MHRotatingCircle.initialize, (_paramsFrom(arg)));
        _call(actor, data);
    }

    // ================================================================ End-of-run drive (liveness, §4.7 inv. 7)

    /// @notice From whatever state the run left, reaches an end state using only time and permissionless calls
    ///         (plus members acting for themselves and reliable members keeping up their payments), then pays
    ///         every claim. Asserts each step that must succeed. Not a fuzz target.
    function driveToEnd() external {
        if (address(circle) == address(0)) return;
        if (usdc.paused()) usdc.unpause(); // the issuer eventually unpauses; strike timers need it
        if (usdc.isBlacklisted(address(circle))) usdc.setBlacklisted(address(circle), false); // and lifts this one
        if (circle.status() == CircleStatus.Pending) {
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp <= circle.joinDeadline()) vm.warp(uint256(circle.joinDeadline()) + 1);
            _must(_anyone(1), abi.encodeCall(MHRotatingCircle.cancelUnjoined, ()), "cancelUnjoined");
        }
        for (uint256 guard; guard <= n + 1 && circle.status() == CircleStatus.Active; ++guard) {
            _driveRound();
        }
        assertTrue(
            circle.status() == CircleStatus.Completed || circle.status() == CircleStatus.Cancelled, "ended"
        );
        _payOut();
    }

    function _driveRound() internal {
        uint256 s = circle.nextSettle();
        uint256 open = circle.startTime() + (s - 1) * circle.roundDuration();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < open) vm.warp(open);
        for (uint256 i; i < n; ++i) {
            if (s < stopRound[i]) _payRound(_pool[i], s);
        }
        if (_call(attacker, abi.encodeCall(MHRotatingCircle.settleRound, ()))) return;
        uint256 graceEnd = circle.roundDeadline(s) + circle.grace();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= graceEnd) vm.warp(graceEnd + 1);
        if (_call(attacker, abi.encodeCall(MHRotatingCircle.settleRound, ()))) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= graceEnd + circle.cure()) vm.warp(graceEnd + circle.cure() + 1);
        _must(attacker, abi.encodeCall(MHRotatingCircle.cancelStalled, ()), "a stalled round must cancel");
    }

    function _payOut() internal {
        for (uint256 i; i < n; ++i) {
            address m = _pool[i];
            IMHRotatingCircle.MemberState memory st = circle.memberState(m);
            if (st.sec != 0) {
                _must(m, abi.encodeCall(MHRotatingCircle.withdrawSecurity, (st.sec)), "withdraw");
            }
            if (st.claim != 0) _must(m, abi.encodeCall(MHRotatingCircle.claim, ()), "claim");
        }
        if (circle.feeEscrow() != 0) {
            _must(attacker, abi.encodeCall(MHRotatingCircle.flushFees, ()), "flushFees");
        }
        if (circle.residual() != 0) {
            _must(attacker, abi.encodeCall(MHRotatingCircle.sweepResidual, ()), "sweepResidual");
        }
        // The issuer lifts every blacklist; queued payouts can then be claimed by their owners.
        for (uint256 i; i <= n; ++i) {
            address a = i == n ? treasury : _pool[i];
            if (usdc.isBlacklisted(a)) usdc.setBlacklisted(a, false);
            if (circle.owed(a) != 0) _must(a, abi.encodeCall(IMHCircle.claimOwed, ()), "claimOwed");
        }
        if (usdc.balanceOf(address(circle)) != 0) {
            _must(attacker, abi.encodeCall(MHRotatingCircle.sweepDonations, ()), "sweepDonations");
        }
        assertEq(usdc.balanceOf(address(circle)), 0, "everything paid out");
        assertEq(circle.trackedAssets(), 0, "no bucket left");
        assertEq(circle.owedTotal(), 0, "no queued payout left");
    }

    // ================================================================ Internal

    /// @dev Creates the run's circle on first use. Returns false while the seed cannot make one (never: every
    ///      derived parameter is within bounds), true once it exists.
    function _ensure(uint256 seed) internal returns (bool) {
        if (address(circle) != address(0)) return true;
        seed = _h(seed);
        RotatingParams memory p = _paramsFrom(seed);
        vm.prank(operator);
        circle = MHRotatingCircle(factory.createRotating(p));
        usdc.watch(address(circle));
        n = p.members.length;
        contribution = p.config.contribution;
        feeEach = n * contribution * p.config.feeBps / K.BPS;
        allSigma100 = true;
        for (uint256 i; i < n; ++i) {
            if (p.securityBps[i] != K.MAX_SECURITY_BPS) allSigma100 = false;
        }
        // forge-lint: disable-next-line(incorrect-shift)
        unreliable = (seed >> 200) & (seed >> 210) & ((1 << n) - 1); // each member with probability ~1/4
        for (uint256 i; i < n; ++i) {
            stopRound[i] = (unreliable >> i) & 1 == 1
                ? _bound(uint256(keccak256(abi.encode(seed, "stop", i))), 1, n)
                : type(uint256).max;
        }
        // Usually everyone joins straight away (an unjoined circle just refunds; that path is covered too).
        if ((seed >> 220) % 4 != 0) {
            for (uint256 i; i < n; ++i) {
                _join(_pool[i], uint256(keccak256(abi.encode(seed, "col", i))));
            }
        }
        return true;
    }

    function _payReliable() internal {
        if (circle.status() != CircleStatus.Active) return;
        uint256 last = circle.currentRound();
        for (uint256 r = circle.nextSettle(); r <= last; ++r) {
            for (uint256 i; i < n; ++i) {
                if (r < stopRound[i]) _payRound(_pool[i], r);
            }
        }
    }

    function _paramsFrom(uint256 seed) internal view returns (RotatingParams memory p) {
        uint256 count = _bound(seed, 2, POOL);
        uint64 round = uint64(_bound(seed >> 64, 7 days, 14 days));
        uint64 joinBy = uint64(block.timestamp + _bound(seed >> 160, 1 hours, 10 days));
        p.config = RotatingConfig({
            circleId: keccak256(abi.encode("rotating-invariant", seed)),
            contribution: _bound(seed >> 8, 100, 50_000) * K.CENT, // $1 … $500
            feeBps: uint16(_bound(seed >> 32, 0, K.MAX_ROTATING_FEE_BPS)),
            roundDuration: round,
            grace: uint64(_bound(seed >> 96, K.MIN_GRACE, round - 1)),
            cure: uint64(_bound(seed >> 128, K.MIN_CURE, 10 days)),
            joinDeadline: joinBy,
            plannedStart: uint64(_bound(seed >> 176, block.timestamp, uint256(joinBy) + 10 days)),
            // forge-lint: disable-next-line(unsafe-typecast)
            totalRounds: uint32(count)
        });
        p.members = new address[](count);
        p.securityBps = new uint16[](count);
        uint256 mode = (seed >> 48) % 3;
        for (uint256 i; i < count; ++i) {
            p.members[i] = _pool[i];
            if (mode == 0) {
                p.securityBps[i] = uint16(K.MAX_SECURITY_BPS);
            } else if (mode == 1) {
                p.securityBps[i] = uint16(K.MIN_SECURITY_BPS);
            } else {
                p.securityBps[i] =
                    uint16(_bound(uint256(keccak256(abi.encode(seed, "sigma", i))), 5_000, 10_000));
            }
        }
    }

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

    function _join(address m, uint256 colSeed) internal {
        if (circle.status() != CircleStatus.Pending) return;
        uint256 col = colSeed % 3 == 0 ? _bound(colSeed >> 2, 0, n * contribution) : 0;
        if (col != 0 && !_fund(m, col)) col = 0;
        _call(m, abi.encodeCall(MHRotatingCircle.join, (circle.termsHash(), col)));
    }

    /// @dev As the app does it: approve exactly `amountDue`, then `contribute(round, due)`. Audit 2 R1-03/R1-19:
    ///      nothing is due on a recipient's own netted round; half the time it pays it anyway (a circular payment,
    ///      `maxPull = c`), so both flows reach `settleRound` and `cancelStalled`.
    function _payRound(address m, uint256 round) internal {
        if (circle.paid(round, m)) return;
        uint256 due = circle.amountDue(m, round);
        if (
            due == 0 && circle.slotOf(m) == round
                && uint256(keccak256(abi.encode(m, round, ghostMaxGas))) % 2 == 0
        ) {
            due = contribution;
        }
        if (due != 0 && !_fund(m, due)) return;
        _call(m, abi.encodeCall(MHRotatingCircle.contribute, (round, due)));
    }

    /// @dev Mints and approves exactly `amount`; false when USDC is paused or `m` is blacklisted.
    function _fund(address m, uint256 amount) internal returns (bool) {
        if (usdc.paused() || usdc.isBlacklisted(m)) return false;
        usdc.mint(m, amount);
        vm.prank(m);
        usdc.approve(address(circle), amount);
        return true;
    }

    function _treasuryIn() internal view returns (uint256) {
        return usdc.sent(address(circle), treasury) + circle.owed(treasury);
    }

    function _must(address actor, bytes memory data, string memory what) internal {
        assertTrue(_call(actor, data), what);
    }

    /// @dev Independent oracle (audit R1-31): which members a `cancelStalled` now should strike, from public views
    ///      only. Mirrors the spec rule, not the circle's internals: unpaid in round `s`, security below c, and not
    ///      the recipient whose payout n·c − fee − holdback can absorb its unpaid part.
    function _predictDefaulters() internal view returns (bool[] memory d) {
        d = new bool[](n);
        if (circle.status() != CircleStatus.Active) return d;
        uint256 s = circle.nextSettle();
        uint256 c = contribution;
        for (uint256 i; i < n; ++i) {
            address m = _pool[i];
            if (circle.paid(s, m)) continue;
            IMHRotatingCircle.MemberState memory st = circle.memberState(m);
            if (st.sec >= c) continue;
            if (i + 1 == s) {
                // The recipient's draw from public views (audit 2 R1-19: `amountDue` reports 0 for its own netted
                // round, so it cannot be used here): `min(c, sec − S_s)` above S_s, before the payout.
                uint256 need = circle.requiredSecurity(m); // S_s before the payout
                uint256 draw = st.sec > need ? st.sec - need : 0;
                if (draw > c) draw = c;
                uint256 left = st.sec - draw;
                uint256 holdback = left >= need ? 0 : need - left;
                if (n * c - feeEach - holdback >= c - draw) continue;
            }
            d[i] = true;
        }
    }

    /// @dev Every circle call: prank, measure gas, attribute treasury inflow, record a cancellation.
    function _call(address actor, bytes memory data) internal returns (bool ok) {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(data);
        uint256 before = _treasuryIn();
        bool wasCancelled = circle.status() == CircleStatus.Cancelled;
        bool[] memory predicted;
        uint256 paidOut;
        bool circleBlacklisted = usdc.isBlacklisted(address(circle));
        if (selector == MHRotatingCircle.cancelStalled.selector) predicted = _predictDefaulters();
        for (uint256 i; i < n && !wasCancelled; ++i) {
            if (circle.memberState(_pool[i]).received) ++paidOut;
        }
        vm.recordLogs();
        vm.prank(actor);
        uint256 g = gasleft();
        (ok,) = address(circle).call(data);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return false;
        successes[selector] += 1;
        if (g > ghostMaxGas) {
            ghostMaxGas = g;
            ghostMaxGasSelector = selector;
        }
        uint256 delta = _treasuryIn() - before;
        if (selector == MHRotatingCircle.flushFees.selector) ghostFees += delta;
        else if (selector == MHRotatingCircle.sweepResidual.selector) ghostResidual += delta;
        else if (selector == MHRotatingCircle.sweepDonations.selector) ghostDonSwept += delta;
        else ghostUnexpected += delta;
        if (!wasCancelled && circle.status() == CircleStatus.Cancelled) {
            paidOutAtCancel = paidOut;
            _recordCancel(logs);
            if (selector == MHRotatingCircle.cancelStalled.selector) {
                if (circleBlacklisted) ++blacklistedStalls;
                uint256 s = circle.nextSettle();
                for (uint256 i; i < n; ++i) {
                    expectedDefaulter[_pool[i]] = predicted[i];
                    if (predicted[i] != isDefaulter[_pool[i]]) ++defaulterMismatches;
                    // Rounds are paid in order, so a defaulter paid exactly the settled rounds before s.
                    if (isDefaulter[_pool[i]] && circle.memberState(_pool[i]).paidRounds != s - 1) {
                        ++prepaidDefaulters;
                    }
                }
            }
        }
    }

    function _recordCancel(Vm.Log[] memory logs) internal {
        cancelled = true;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(circle)) continue;
            bytes32 t0 = logs[i].topics[0];
            if (t0 == IMHRotatingCircle.ClaimAssigned.selector) {
                address m = address(uint160(uint256(logs[i].topics[1])));
                (uint256 e,) = abi.decode(logs[i].data, (uint256, uint256));
                cancelE[m] = e;
            } else if (t0 == IMHRotatingCircle.Defaulted.selector) {
                address m = address(uint160(uint256(logs[i].topics[1])));
                isDefaulter[m] = true;
                penaltyTotal += abi.decode(logs[i].data, (uint256));
            } else if (t0 == IMHRotatingCircle.CircleCancelled.selector) {
                // forge-lint: disable-next-line(unsafe-typecast)
                cancelReason = uint8(uint256(logs[i].topics[1]));
            }
        }
    }
}
