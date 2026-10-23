// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AccumulationFixture } from "../AccumulationFixture.sol";
import { AccumulationHandler } from "./AccumulationHandler.sol";
import { MHAccumulationCircle } from "../../../src/circles/MHAccumulationCircle.sol";
import { IMHAccumulationCircle } from "../../../src/circles/interfaces/IMHAccumulationCircle.sol";
import { CircleStatus } from "../../../src/circles/MHCircleTypes.sol";

/// @notice Spec §4.7 invariants 1–4 and 6–8 for the accumulation circle, handler-based with a ghost ledger, against
///         a mock Vault V2 that toggles yield, loss, illiquidity, gates and a drifting `previewRedeem`. Local runs
///         use the default profile; CI runs `FOUNDRY_PROFILE=ci` (10,000 runs at depth 200).
///         After every call: exact USDC and vault-share solvency, share-bucket sums, Σ toAssets(bucket) ≤ NAV,
///         per-member USDC flows equal `principal`/`cashOut`, USDC and vault shares only ever leave to members and
///         the treasury (and USDC to the vault itself), the treasury only receives settlement fees, residual and
///         donations, and every settlement satisfied invariant 6 when it happened. After every run: the circle is
///         driven to an end state with time, permissionless calls and members acting for themselves (with the
///         vault left illiquid or gated if it was), every claim is paid, and the circle ends empty (invariant 7);
///         with a non-decreasing share price, a compliant member got at least as much per dollar as a delinquent
///         one.
contract MHAccumulationInvariantTest is AccumulationFixture {
    uint256 internal constant GAS_CAP = 5_000_000;

    AccumulationHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AccumulationHandler(
            usdc, morpho, factory, registry, [gov, address(timelock), guardian, operator, treasury, attacker]
        );
        bytes4[] memory s = new bytes4[](40);
        s[0] = AccumulationHandler.joinAll.selector;
        s[1] = AccumulationHandler.join.selector;
        s[2] = AccumulationHandler.contribute.selector;
        s[3] = AccumulationHandler.payReliable.selector;
        s[4] = AccumulationHandler.exitEarly.selector;
        s[5] = AccumulationHandler.settleMemberInKind.selector;
        s[6] = AccumulationHandler.claim.selector;
        s[7] = AccumulationHandler.claimInKind.selector;
        s[8] = AccumulationHandler.deployIdle.selector;
        s[9] = AccumulationHandler.flagRound.selector;
        s[10] = AccumulationHandler.finalize.selector;
        s[11] = AccumulationHandler.settleMember.selector;
        s[12] = AccumulationHandler.claimOwed.selector;
        s[13] = AccumulationHandler.pullFromVault.selector;
        s[14] = AccumulationHandler.cancelUnjoined.selector;
        s[15] = AccumulationHandler.sweepDonations.selector;
        s[16] = AccumulationHandler.sweepResidual.selector;
        s[17] = AccumulationHandler.emergencyExit.selector;
        s[18] = AccumulationHandler.guardianCancel.selector;
        s[19] = AccumulationHandler.extendDeadline.selector;
        s[20] = AccumulationHandler.disallowVault.selector;
        s[21] = AccumulationHandler.advance.selector;
        s[22] = AccumulationHandler.warp.selector;
        s[23] = AccumulationHandler.vaultYield.selector;
        s[24] = AccumulationHandler.vaultLoss.selector;
        s[25] = AccumulationHandler.vaultLiquidity.selector;
        s[26] = AccumulationHandler.vaultPreviewDiscount.selector;
        s[27] = AccumulationHandler.vaultGates.selector;
        s[28] = AccumulationHandler.donate.selector;
        s[29] = AccumulationHandler.donateShares.selector;
        s[30] = AccumulationHandler.toggleUsdcPause.selector;
        s[31] = AccumulationHandler.toggleBlacklist.selector;
        s[32] = AccumulationHandler.adminPoke.selector;
        s[33] = AccumulationHandler.claimOwedShares.selector;
        s[34] = AccumulationHandler.vaultBreak.selector;
        s[35] = AccumulationHandler.cancelExpired.selector;
        s[36] = AccumulationHandler.reallowVault.selector;
        s[37] = AccumulationHandler.forceExit.selector;
        s[38] = AccumulationHandler.vaultReallocate.selector;
        s[39] = AccumulationHandler.curatorTimelock.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: s }));
    }

    function invariant_accumulation() public view {
        _check();
    }

    /// @dev Invariant 7 (liveness), every invariant again on the end state, then per-dollar fairness.
    function afterInvariant() public virtual {
        handler.driveToEnd();
        _check();
        _checkPerDollar();
    }

    // ================================================================ Checks

    function _check() internal view {
        MHAccumulationCircle c = handler.circle();
        if (address(c) == address(0)) return;
        _checkMembersAndBuckets(c);
        _checkBalances(c);
        _checkRecipients(c);
        _checkTreasury(c);
        assertEq(handler.ghostViolation(), "", "a settlement broke invariant 6");
        assertLt(handler.ghostMaxGas(), GAS_CAP, "a call used more than 5M gas");
    }

    /// @dev Invariants 2 and 3, and invariant 4 per member.
    function _checkMembersAndBuckets(MHAccumulationCircle c) internal view {
        address[] memory m = c.members();
        uint256 nav = handler.navOf();
        uint256 total = c.totalShares();
        uint256 acc;
        uint256 claims;
        uint256 valueSum;
        for (uint256 i; i < m.length; ++i) {
            IMHAccumulationCircle.MemberState memory st = c.memberState(m[i]);
            assertEq(
                usdc.received(address(c), m[i]), st.principal, "principal == USDC pulled from the member"
            );
            assertEq(usdc.sent(address(c), m[i]) + c.owed(m[i]), st.cashOut, "cashOut == USDC paid or queued");
            acc += st.accShares;
            claims += st.claimShares;
            valueSum += _toAssets(st.accShares, nav, total) + _toAssets(st.claimShares, nav, total);
        }
        valueSum += _toAssets(c.forfeitShares(), nav, total) + _toAssets(c.residualShares(), nav, total);
        assertEq(c.accTotal(), acc, "accTotal");
        assertEq(c.claimTotal(), claims, "claimTotal");
        assertEq(acc + claims + c.forfeitShares() + c.residualShares(), total, "share buckets");
        assertLe(valueSum, nav, "sum of toAssets(bucket) <= NAV");
        // Audit A-R2-20: the circle's NAV is itself an output of its counters, so the line above is a tautology once
        // the buckets add up. Invariant 3 against what the circle actually holds: USDC and vault shares (balances,
        // less queued payouts and unswept donations) valued at the vault's own price, independently of the circle.
        assertLe(valueSum, _heldValue(c), "sum of member buckets <= value of the holdings");
        assertLe(nav, _heldValue(c), "the circle never values its holdings above the vault's price");
        CircleStatus st_ = c.status();
        if (st_ == CircleStatus.Pending) assertEq(total, 0, "pending: no shares");
        if (st_ == CircleStatus.Cancelled) assertEq(acc + c.forfeitShares(), 0, "cancelled: claims only");
        if (st_ == CircleStatus.Closed) {
            assertEq(acc + c.forfeitShares(), 0, "closed: claims and residual only");
        }
        // Claims exist after a cancellation, or (audit R1-09) once nobody was left to share the exits' forfeits.
        if (st_ != CircleStatus.Cancelled && (st_ == CircleStatus.Active || c.bonusBase() != 0)) {
            assertEq(claims, 0, "claims only after a cancellation or returned forfeits");
        }
    }

    /// @dev Invariant 1, exactly: tracked counters equal balances, less unswept donations and queued payouts.
    function _checkBalances(MHAccumulationCircle c) internal view {
        assertEq(
            usdc.balanceOf(address(c)),
            c.idleAssets() + c.owedTotal() + handler.ghostDonatedUsdc() - handler.ghostDonSweptUsdc(),
            "USDC balance == idle + owed + unswept donations"
        );
        assertEq(
            morpho.balanceOf(address(c)),
            c.vaultShares() + c.owedSharesTotal() + handler.ghostDonatedShares()
                - handler.ghostDonSweptShares(),
            "vault shares == tracked + queued + unswept donations"
        );
    }

    /// @dev Invariant 4: USDC leaves only to members, the treasury and the vault (deposits); vault shares only to
    ///      members and the treasury (or are burned on redeem); no admin or attacker ever receives anything.
    function _checkRecipients(MHAccumulationCircle c) internal view {
        address[] memory rec = usdc.recipientsOf(address(c));
        for (uint256 i; i < rec.length; ++i) {
            assertTrue(
                c.slotOf(rec[i]) != 0 || rec[i] == treasury || rec[i] == address(morpho),
                "USDC left to a non-member"
            );
        }
        rec = morpho.recipientsOf(address(c));
        for (uint256 i; i < rec.length; ++i) {
            assertTrue(
                c.slotOf(rec[i]) != 0 || rec[i] == treasury || rec[i] == address(0),
                "vault shares left to a non-member"
            );
        }
        address[] memory admins = handler.admins();
        for (uint256 i; i < admins.length; ++i) {
            if (admins[i] == treasury) continue;
            assertEq(usdc.sent(address(c), admins[i]) + c.owed(admins[i]), 0, "an admin received USDC");
            assertEq(morpho.sent(address(c), admins[i]), 0, "an admin received vault shares");
        }
    }

    /// @dev Invariant 4 (treasury) and 6 (Σ bonus ≤ forfeitSnap): the treasury receives settlement fees, residual
    ///      and donations only, and fees only once the circle has matured.
    function _checkTreasury(MHAccumulationCircle c) internal view {
        assertEq(handler.ghostUnexpectedUsdc(), 0, "treasury USDC outside fees/residual/donations");
        assertEq(handler.ghostUnexpectedShares(), 0, "treasury vault shares outside fees/residual/donations");
        assertEq(
            usdc.sent(address(c), treasury) + c.owed(treasury),
            handler.ghostFeeUsdc() + handler.ghostResidualUsdc() + handler.ghostDonSweptUsdc(),
            "treasury USDC by category"
        );
        assertEq(
            morpho.sent(address(c), treasury) + c.owedShares(treasury),
            handler.ghostFeeShares() + handler.ghostResidualShares() + handler.ghostDonSweptShares(),
            "treasury vault shares by category"
        );
        assertLe(handler.ghostDonSweptUsdc(), handler.ghostDonatedUsdc(), "swept more USDC than was donated");
        assertLe(
            handler.ghostDonSweptShares(), handler.ghostDonatedShares(), "swept more shares than donated"
        );
        // Since audit R1-03 a Matured circle can be cancelled after some members settled (and paid fees).
        if (!handler.finalizedOnce()) {
            assertEq(handler.ghostFeeUsdc() + handler.ghostFeeShares(), 0, "fees only at maturity");
            assertEq(handler.ghostBonusSum(), 0, "no bonus before maturity");
        } else {
            assertLe(handler.ghostBonusSum(), c.forfeitSnap(), "sum of bonuses <= forfeitSnap");
        }
    }

    /// @dev Audit A-R2-20: USDC and vault shares the circle holds for its members (balances less queued payouts and
    ///      unswept donations), the shares valued with the vault's `convertToAssets` (works while `previewRedeem` is
    ///      broken), independently of the circle's counters.
    function _heldValue(MHAccumulationCircle c) internal view returns (uint256) {
        uint256 usdcHeld = usdc.balanceOf(address(c)) + handler.ghostDonSweptUsdc()
            - handler.ghostDonatedUsdc() - c.owedTotal();
        uint256 sharesHeld = morpho.balanceOf(address(c)) + handler.ghostDonSweptShares()
            - handler.ghostDonatedShares() - c.owedSharesTotal();
        return usdcHeld + (sharesHeld == 0 ? 0 : morpho.convertToAssets(sharesHeld));
    }

    /// @dev Invariant 6: with a non-decreasing share price, a compliant member got at least as many pool shares
    ///      per dollar as a delinquent one. Compared in pool shares, because since audit R1-11 a member settled later
    ///      keeps the post-maturity yield on its shares, whichever bucket. Audit A-R2-19 (the tolerance of 2 shares
    ///      failed on the audited code at CI scale): with `ρ = (T + 1e6)/(NAV + 1)` the shares per USDC unit
    ///      (≤ 1e6 while the price never fell), each of the compliant member's R mints loses < 1 share to the floor,
    ///      and the delinquent's cap `floor(P·ρ_f)` moves by about ρ per unit of NAV rounding (the vault's
    ///      `previewRedeem` floors), so `v_i·P_j + (R + 2)·P_j + 4e6·P_i ≥ v_j·P_i` (2 units of NAV rounding, ρ ≤ 2e6
    ///      allowing for the virtual offset). That is a few USDC base units per member, far below any unfairness.
    function _checkPerDollar() internal view {
        MHAccumulationCircle c = handler.circle();
        if (address(c) == address(0) || handler.ghostLossSeen() || c.compliantSnap() == 0) return;
        (uint256[] memory p, uint256[] memory v, bool[] memory compliant) = handler.settlements();
        for (uint256 i; i < p.length; ++i) {
            if (!compliant[i] || p[i] == 0) continue;
            for (uint256 j; j < p.length; ++j) {
                if (compliant[j] || p[j] == 0) continue;
                assertGe(
                    (v[i] + c.totalRounds() + 2) * p[j] + 4e6 * p[i],
                    v[j] * p[i],
                    "compliant per dollar >= delinquent per dollar"
                );
            }
        }
    }

    function _toAssets(uint256 shares, uint256 nav, uint256 total) internal pure returns (uint256) {
        return Math.mulDiv(shares, nav + 1, total + 1e6);
    }

    // ================================================================ Regressions (replayed counterexamples)

    /// @dev PR #36 CI (10,000 × 200) counterexample: the shrunk sequence call by call, then the end-of-run checks
    ///      as the campaign runs them. 4 members, 5 rounds, member 3 skips rounds 2 and 5; the
    ///      Guardian's `forceExit` (step 6) pays a 1.92% force-deallocation penalty that lowers the circle's share
    ///      price mid-schedule. Each member bears it pro rata to its exposure (spec §4.5), so member 3, which held
    ///      less before the fall and bought more after it, ends with more pool shares per dollar. Invariant 6
    ///      claims per-dollar fairness only for a non-decreasing price (IMPLEMENTATION_NOTES step 4, deviation 3);
    ///      the handler did not mark this fall, and `_checkPerDollar` failed ("compliant per dollar >= delinquent
    ///      per dollar": 2025115120760226818770000 < 2025854155637354572600000).
    function test_replay_pr36_forceExitPenaltyLowersSharePrice() public {
        _replay(abi.encodeCall(AccumulationHandler.advance, (519343290081960929839387)));
        _replay(
            abi.encodeCall(AccumulationHandler.advance, (14374565857871484625521209882910173306611545474068))
        );
        _replay(
            abi.encodeCall(
                AccumulationHandler.payReliable,
                (1136510775474845902050685514007540168531300002637520829246406098)
            )
        );
        _replay(
            abi.encodeCall(
                AccumulationHandler.deployIdle,
                (633269538831246341442658599225360337595558645438685438458919560809)
            )
        );
        _replay(abi.encodeCall(AccumulationHandler.donateShares, (12796)));
        uint256 navBefore = handler.circle().nav();
        _replay(
            abi.encodeCall(
                AccumulationHandler.forceExit,
                (1, 2362450178560002612735932329742868472891335079666595030055508858117144938225)
            )
        );
        assertLt(handler.circle().nav(), navBefore, "the forceExit penalty lowered the circle's NAV");
        _replay(
            abi.encodeCall(
                AccumulationHandler.advance, (778728842303265217725419288224013269226540299942222329949302)
            )
        );
        _replay(abi.encodeCall(AccumulationHandler.advance, (275183293043940463211886020)));
        _replay(
            abi.encodeCall(AccumulationHandler.advance, (17432916670459796410386115229499060352090880518787))
        );
        _replay(abi.encodeCall(AccumulationHandler.payReliable, (264480746646084638039469285)));
        afterInvariant();
        assertTrue(handler.ghostLossSeen(), "a share price that fell is outside the per-dollar claim");
    }

    /// @dev One handler call as the campaign makes it, then every per-call invariant. The campaign's senders are
    ///      not replayed: the handler never reads `msg.sender` (each circle call is pranked as its own actor).
    function _replay(bytes memory call) internal {
        (bool ok,) = address(handler).call(call);
        assertTrue(ok, "handler call reverted");
        _check();
    }
}
