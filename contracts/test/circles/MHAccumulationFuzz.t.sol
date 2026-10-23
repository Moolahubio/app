// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { MHCircleConstants as K } from "../../src/circles/MHCircleConstants.sol";
import { IMHAccumulationCircle } from "../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleStatus, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.7 fuzz for the accumulation circle over whole paths: n, rounds, c, fee, payment timing (the
///         current round or the previous one within its grace), missed rounds, early exits, a Guardian extension,
///         a yield/loss path applied round by round (none, yield only, or yield and loss), and cash or in-kind
///         settlement with the vault liquid or fully illiquid. Asserts:
///         - buckets, balances and Σ toAssets ≤ NAV after every step;
///         - MISSED strikes exactly for unpaid rounds (not for rounds after an early exit), never a LATE strike;
///         - every settlement against the spec formula (as amended in audit round 1) evaluated just before it: the
///           fee is exactly floor(max(0, gross − P)·fee) for a compliant member, and for everyone when nobody is
///           compliant (R1-10), 0 for a delinquent member, who gets at most its principal (capped once at finalize;
///           R1-11), an in-kind settlement is worth no more than its cash equivalent, Σ bonus ≤ forfeitSnap;
///         - an early exit pays at most principal and charges no fee;
///         - with a non-decreasing share price, a compliant member gets at least as much per dollar as a
///           delinquent one; with no yield and no loss nobody gains or loses beyond vault rounding dust;
///         - the circle always ends empty, with only fees (bounded by the circle's own fee on earnings) and
///           rounding dust at the treasury; if every member exited, each gets its forfeited yield back less the fee
///           (R1-09).
contract MHAccumulationFuzzTest is AccumulationFixture {
    struct Run {
        uint256 n;
        uint256 rounds;
        uint256 c;
        uint16 fee;
        uint256 move; // 0: none, 1: yield only, 2: yield and loss
        bool lock;
        uint256 seed;
    }

    struct Expect {
        bool compliant;
        uint256 principal;
        uint256 gross;
        uint256 fee;
        uint256 bonus;
    }

    Run internal run;
    mapping(uint256 index => uint256 round) internal exitAt;
    mapping(address member => mapping(uint256 round => bool done)) internal paidOk;
    /// @dev The first round a member no longer owes, computed here from the exit time (audit 2 R2-07: the oracle used
    ///      to read the contract's own `exitRound`, so it could not see that the last round was never owed).
    mapping(address member => uint256 round) internal expectedExitRound;
    uint256 internal feesSeen;
    uint256 internal residualAllowance;
    uint256 internal bonusSum;
    uint256[] internal principals;
    uint256[] internal values;
    bool[] internal compliants;

    function testFuzz_accumulation_paths(
        uint256 nSeed,
        uint256 roundsSeed,
        uint256 cSeed,
        uint16 feeSeed,
        uint256 seed
    ) public {
        run.n = bound(nSeed, 2, 8);
        run.rounds = bound(roundsSeed, 1, 10);
        run.c = bound(cSeed, K.MIN_CONTRIBUTION / K.CENT, 100_000) * K.CENT; // $1 … $1,000
        run.fee = uint16(bound(feeSeed, 0, K.MAX_ACCUMULATION_FEE_BPS));
        run.move = seed % 3;
        run.lock = (seed >> 2) % 4 == 0;
        run.seed = seed;
        _setUpRun();
        for (uint256 r = 1; r <= run.rounds; ++r) {
            _playRound(r);
            _assertBuckets();
        }
        _latePhase(run.rounds); // late payments of the last round, within its grace
        // Audit 2 R2-07: some members exit after the last deadline (in its grace); the last round stays owed.
        for (uint256 i; i < run.n; ++i) {
            if (!run.lock && _h("lateExit", i) % 5 == 0 && !circle.memberState(people[i]).exited) _exit(i);
        }
        _mature();
        _flagAll();
        uint256 forfeitValue = _toAssets(circle.forfeitShares());
        uint256 tBefore = _treasuryValue();
        circle.finalize();
        // Everyone exited (or nobody left holds shares): audit R1-09, each exited member gets its own forfeited
        // shares back as a claim, and the treasury only the fee on those earnings. Only rounding dust is residual.
        uint256 finalizeFee = _treasuryValue() - tBefore;
        assertLe(finalizeFee, forfeitValue * run.fee / K.BPS + 2, "finalize: at most the fee on forfeits");
        feesSeen += finalizeFee;
        _assertBuckets();
        _settleEveryone();
        _claimReturnedForfeits();
        _finish();
    }

    function _treasuryValue() internal view returns (uint256) {
        return usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury));
    }

    /// @dev Audit R1-09: exited members claim their returned forfeits (in kind when the vault is illiquid).
    function _claimReturnedForfeits() internal {
        for (uint256 i; i < run.n; ++i) {
            address m = people[i];
            if (circle.memberState(m).claimShares == 0) continue;
            assertTrue(circle.memberState(m).exited, "returned forfeits go to exited members only");
            vm.prank(m);
            circle.claimInKind();
            _assertBuckets();
        }
    }

    // ================================================================ Setup

    function _setUpRun() internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        AccumulationParams memory p = _params(run.n, uint32(run.rounds), run.fee, address(morpho), run.lock);
        p.config.contribution = run.c;
        _create(p);
        for (uint256 i; i < run.n; ++i) {
            _join(people[i]);
            if (!run.lock && _h("exit", i) % 6 == 0) exitAt[i] = bound(_h("exitAt", i), 1, run.rounds);
        }
        vm.warp(circle.startTime());
    }

    // ================================================================ One round

    function _playRound(uint256 r) internal {
        _openRound(r);
        // Payments happen at a random moment within the previous round's grace (always after the opening).
        uint256 t = block.timestamp + bound(_h("t", r), 0, GRACE - 1);
        vm.warp(t);
        if (r > 1) _payPhase(r - 1, true);
        if (_h("extend", r) % 5 == 0 && circle.extension() == 0) {
            vm.prank(guardian);
            circle.extendDeadline(bound(_h("by", r), 1 hours, 7 days));
        }
        for (uint256 i; i < run.n; ++i) {
            if (exitAt[i] == r && !circle.memberState(people[i]).exited) _exit(i);
        }
        _payPhase(r, false);
        _deploy();
        _move(r);
    }

    /// @dev Members pay round `r`: on time (`late == false`) or, for a sixth of payments, during the next round
    ///      while round `r`'s grace lasts. An unreliable member (one in four) skips a third of its rounds.
    function _payPhase(uint256 r, bool late) internal {
        for (uint256 i; i < run.n; ++i) {
            address m = people[i];
            bool isLate = _h("late", i * 1000 + r) % 6 == 0;
            if (isLate != late) continue;
            if (_h("unreliable", i) % 4 == 0 && _h("skip", i * 1000 + r) % 3 == 0) continue;
            if (circle.amountDue(m, r) == 0) continue;
            _fund(m, run.c);
            vm.prank(m);
            circle.contribute(r, run.c);
            paidOk[m][r] = true;
        }
    }

    function _latePhase(uint256 r) internal {
        uint256 t = circle.roundDeadline(r) + bound(_h("lastLate", r), 0, GRACE - 1);
        // forge-lint: disable-next-line(block-timestamp)
        if (t > block.timestamp) vm.warp(t);
        _payPhase(r, true);
        _deploy();
    }

    /// @dev An early exit pays at most principal and never charges a fee. Its exit round, from the spec rule: the
    ///      current round (rounds before it are owed), or `totalRounds + 1` once the last deadline has passed.
    function _exit(uint256 i) internal {
        address m = people[i];
        uint256 start = circle.startTime();
        uint256 expected;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= start) {
            expected = (block.timestamp - start) / ROUND + 1;
            if (expected > run.rounds) expected = run.rounds;
            // forge-lint: disable-next-line(block-timestamp)
            if (expected == run.rounds && block.timestamp > circle.roundDeadline(run.rounds)) expected += 1;
        }
        expectedExitRound[m] = expected;
        uint256 principal = circle.memberState(m).principal;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 before = usdc.balanceOf(m);
        vm.prank(m);
        circle.exitEarly();
        assertEq(circle.memberState(m).exitRound, expected, "exit round");
        assertLe(usdc.balanceOf(m) - before, principal, "exit pays at most principal");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "no fee on an exit");
        _assertBuckets();
    }

    /// @dev The vault's return for this round: none, a gain of up to 2%, or anything from −3% to +3%.
    function _move(uint256 r) internal {
        uint256 ta = morpho.totalAssets();
        if (run.move == 0 || ta == 0) return;
        uint256 h = _h("move", r);
        if (run.move == 1 || h % 2 == 0) {
            morpho.mockYield(ta * bound(h >> 8, 0, 200) / 10_000);
        } else {
            morpho.mockLoss(ta * bound(h >> 8, 0, 300) / 10_000);
        }
    }

    // ================================================================ Maturity

    /// @dev Flags every round and checks MISSED strikes exactly; no accumulation payment is ever LATE.
    function _flagAll() internal {
        for (uint256 r = 1; r <= run.rounds; ++r) {
            circle.flagRound(r);
            for (uint256 i; i < run.n; ++i) {
                address m = people[i];
                IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
                bool exemptAfterExit = st.exited && r >= expectedExitRound[m];
                bool expected = !paidOk[m][r] && !exemptAfterExit;
                assertEq(
                    reputation.struck(m, address(circle), r, IMHReputation.Reason.MISSED), expected, "MISSED"
                );
                assertFalse(reputation.struck(m, address(circle), r, IMHReputation.Reason.LATE), "never LATE");
            }
        }
    }

    /// @dev Cash settlement by the keeper, or in kind by the member when the vault is made fully illiquid.
    function _settleEveryone() internal {
        bool illiquid = (run.seed >> 4) % 3 == 0 && circle.vaultShares() != 0;
        if (illiquid) morpho.mockSetLiquidity(0);
        for (uint256 i; i < run.n; ++i) {
            address m = people[i];
            if (circle.memberState(m).settled) continue;
            Expect memory e = _expectSettle(m);
            bool inKind = illiquid && circle.idleAssets() < e.gross;
            (uint256 got, uint256 fee) = inKind ? _settleInKind(m) : _settleCash(m);
            if (inKind) {
                assertLe(fee, e.fee + 1, "in kind: fee only on earnings");
                assertLe(got + fee, e.gross + 1, "in kind: worth no more than cash");
            } else {
                assertEq(fee, e.fee, "fee == floor(max(0, gross - P) * fee)");
                assertEq(got, e.gross - e.fee, "payout == gross - fee");
            }
            if (!e.compliant && circle.compliantSnap() != 0) {
                // Capped once at finalize; between finalize and now the share price only moved by rounding.
                assertLe(got, e.principal + run.n + 2, "a delinquent member gets at most its principal");
            }
            bonusSum += e.bonus;
            feesSeen += fee;
            principals.push(e.principal);
            values.push(got);
            compliants.push(e.compliant);
            _assertBuckets();
        }
        assertLe(bonusSum, circle.forfeitSnap(), "sum of bonuses <= forfeitSnap");
        if (illiquid) morpho.mockSetLiquidity(type(uint256).max);
    }

    function _settleCash(address m) internal returns (uint256 got, uint256 fee) {
        uint256 b = usdc.balanceOf(m);
        uint256 t = usdc.balanceOf(treasury);
        circle.settleMember(m);
        got = usdc.balanceOf(m) - b;
        fee = usdc.balanceOf(treasury) - t;
    }

    /// @dev Values the vault shares received at the circle's own price for that transaction.
    function _settleInKind(address m) internal returns (uint256 got, uint256 fee) {
        uint256 held = circle.vaultShares();
        uint256 vaultPart = circle.nav() - circle.idleAssets();
        uint256 b = usdc.balanceOf(m);
        uint256 bs = morpho.balanceOf(m);
        uint256 t = usdc.balanceOf(treasury);
        uint256 ts = morpho.balanceOf(treasury);
        vm.prank(m);
        circle.settleMemberInKind(m);
        got = usdc.balanceOf(m) - b;
        fee = usdc.balanceOf(treasury) - t;
        if (held != 0) {
            got += Math.mulDiv(morpho.balanceOf(m) - bs, vaultPart, held);
            fee += Math.mulDiv(morpho.balanceOf(treasury) - ts, vaultPart, held);
        }
    }

    /// @dev Spec §4.5, evaluated independently at the current NAV.
    function _expectSettle(address m) internal view returns (Expect memory e) {
        IMHAccumulationCircle.MemberState memory st = circle.memberState(m);
        uint256 nav = circle.nav();
        uint256 total = circle.totalShares();
        e.principal = st.principal;
        e.compliant = st.paidRounds == run.rounds;
        bool sharesForfeit = e.compliant || circle.compliantSnap() == 0;
        if (sharesForfeit) {
            uint256 base = circle.bonusBase();
            if (base != 0) e.bonus = Math.mulDiv(circle.forfeitSnap(), st.accShares, base);
        }
        e.gross = Math.mulDiv(st.accShares + e.bonus, nav + 1, total + VS);
        if (sharesForfeit && e.gross > e.principal) e.fee = (e.gross - e.principal) * run.fee / K.BPS;
    }

    // ================================================================ End

    function _finish() internal {
        assertEq(uint8(circle.status()), uint8(CircleStatus.Closed), "closed");
        uint256 feesAtTreasury = usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury));
        if (circle.idleAssets() != 0 || circle.vaultShares() != 0) circle.sweepResidual();
        assertEq(usdc.balanceOf(address(circle)), 0, "no USDC left");
        assertEq(morpho.balanceOf(address(circle)), 0, "no vault share left");
        uint256 residual =
            usdc.balanceOf(treasury) + morpho.convertToAssets(morpho.balanceOf(treasury)) - feesAtTreasury;
        assertLe(residual, residualAllowance + run.n + run.rounds + 2, "residual is rounding dust");
        // Audit R1-31: the treasury's fees are bounded by the circle's own fee on the members' earnings.
        uint256 earnings;
        for (uint256 i; i < run.n; ++i) {
            int256 net = _net(people[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (net > 0) earnings += uint256(net);
        }
        assertLe(
            feesSeen * (K.BPS - run.fee), (earnings + run.n + 2) * run.fee, "fees above feeBps of earnings"
        );
        if (run.move == 0) {
            assertEq(feesSeen, 0, "no earnings, no fee");
            for (uint256 i; i < run.n; ++i) {
                assertGe(_net(people[i]), -int256(run.rounds + 2), "no move: nobody loses beyond dust");
                assertLe(_net(people[i]), int256(run.n), "no move: nobody gains beyond dust");
            }
        }
        if (run.move != 2 && circle.compliantSnap() != 0) _checkPerDollar();
    }

    function _checkPerDollar() internal view {
        for (uint256 i; i < principals.length; ++i) {
            if (!compliants[i] || principals[i] == 0) continue;
            for (uint256 j; j < principals.length; ++j) {
                if (compliants[j] || principals[j] == 0) continue;
                assertGe(
                    (values[i] + run.rounds + 2) * principals[j],
                    values[j] * principals[i],
                    "compliant per dollar >= delinquent per dollar"
                );
            }
        }
    }

    function _h(string memory tag, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(run.seed, tag, i)));
    }
}
