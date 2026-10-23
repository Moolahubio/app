// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

/// @notice R8 boundary-gas harness (spec §4.7: "Boundary-gas test on every public function"). The legacy defect was
///         a try/catch and a low-level `_pay` that a caller could starve of gas (the 63/64 rule) so that the inner
///         payment failed while the outer call still succeeded in a different state. For a call that succeeds
///         with unlimited gas, the harness:
///         1. records the state before (`_probe`) and after an unconstrained call;
///         2. binary-searches the exact minimum gas limit at which the call succeeds;
///         3. tries every gas limit in a window around that minimum, and a coarse sweep from 21,000 up to well
///            above it.
///         Every attempt must either revert with the state untouched, or succeed with exactly the unconstrained
///         end state: no gas limit may produce a third outcome (a partial payout, a queued payout, a skipped
///         strike). The minimum must also stay under the spec's 5M gas bound.
abstract contract BoundaryGas is Test {
    uint256 internal constant BOUNDARY_GAS_CAP = 5_000_000;
    uint256 internal constant WINDOW = 128;
    uint256 internal constant SWEEP_STEP = 499;
    uint256 internal constant SWEEP_ABOVE = 40_000;

    /// @dev A hash of every piece of state the call could touch.
    function _probe() internal view virtual returns (bytes32);

    struct Attempt {
        address target;
        address caller;
        bytes data;
        bytes32 before;
        bytes32 expected;
        uint256 snap;
    }

    /// @return gMin The smallest gas limit at which the call succeeds.
    function _boundary(address target, address caller, bytes memory data, string memory label)
        internal
        returns (uint256 gMin)
    {
        Attempt memory a;
        a.target = target;
        a.caller = caller;
        a.data = data;
        a.before = _probe();
        a.snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok,) = target.call(data);
        assertTrue(ok, string.concat(label, ": must succeed with unlimited gas"));
        a.expected = _probe();
        assertTrue(a.expected != a.before, string.concat(label, ": the call must change state"));
        vm.revertToState(a.snap);

        uint256 lo;
        uint256 hi = 30_000_000;
        assertTrue(_attempt(a, hi), string.concat(label, ": must succeed at 30M"));
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_attempt(a, mid)) hi = mid;
            else lo = mid;
        }
        gMin = hi;
        assertFalse(_attempt(a, gMin - 1), string.concat(label, ": fails just below the minimum"));
        uint256 from = gMin > WINDOW ? gMin - WINDOW : 0;
        for (uint256 g = from; g <= gMin + WINDOW; ++g) {
            _attempt(a, g);
        }
        for (uint256 g = 21_000; g <= gMin + SWEEP_ABOVE; g += SWEEP_STEP) {
            _attempt(a, g);
        }
        emit log_named_uint(string.concat("R8 boundary gas: ", label), gMin);
        assertLt(gMin, BOUNDARY_GAS_CAP, string.concat(label, ": above the 5M gas bound"));
    }

    function _attempt(Attempt memory a, uint256 gasLimit) private returns (bool ok) {
        // Every attempt's scratch memory (return data, the probe's encoding) is released at the end, so a long sweep
        // (thousands of attempts for a call whose minimum is in the millions) does not grow memory quadratically.
        uint256 fmp;
        assembly ("memory-safe") {
            fmp := mload(0x40)
        }
        vm.prank(a.caller);
        (ok,) = a.target.call{ gas: gasLimit }(a.data);
        bytes32 p = _probe();
        if (ok) assertEq(p, a.expected, "a success under a gas limit must equal the unconstrained call");
        else assertEq(p, a.before, "a call that ran out of gas must leave no partial state");
        vm.revertToState(a.snap);
        assembly ("memory-safe") {
            mstore(0x40, fmp)
        }
    }
}
