// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { RotatingFixture } from "./RotatingFixture.sol";
import { AccumulationFixture } from "./AccumulationFixture.sol";
import { MHRotatingCircle } from "../../src/circles/MHRotatingCircle.sol";
import { MHAccumulationCircle } from "../../src/circles/MHAccumulationCircle.sol";
import { CircleStatus, RotatingParams, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

import { IVm7702, Mock7702BatchExecutor } from "../mocks/Mock7702.sol";

/// @notice Spec §4.1 / §4.7: an EIP-7702 member (an EOA delegated to a Kernel-style batch executor, so it has code)
///         uses circles exactly like a plain EOA, batching [approve, action] in one call as Privy's 7702 wallets do.
///         Circles never use `tx.origin`, code-size checks or signature-based membership. The test EVM is switched
///         to Prague for the delegation (forge 1.7.1 cheatcodes; forge-std v1.9.4 does not declare them yet).
abstract contract Member7702 {
    IVm7702 internal constant VM7702 = IVm7702(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _delegate(uint256 pk) internal returns (Mock7702BatchExecutor account) {
        VM7702.setEvmVersion("prague");
        Mock7702BatchExecutor impl = new Mock7702BatchExecutor();
        VM7702.signAndAttachDelegation(address(impl), pk);
        account = Mock7702BatchExecutor(_addr(pk));
    }

    function _addr(uint256 pk) internal pure virtual returns (address);

    function _two(address t1, bytes memory d1, address t2, bytes memory d2)
        internal
        pure
        returns (Mock7702BatchExecutor.Call[] memory calls)
    {
        calls = new Mock7702BatchExecutor.Call[](2);
        calls[0] = Mock7702BatchExecutor.Call(t1, d1);
        calls[1] = Mock7702BatchExecutor.Call(t2, d2);
    }
}

contract MH7702MemberRotatingTest is RotatingFixture, Member7702 {
    uint256 internal constant PK = 0x7702;

    function _addr(uint256 pk) internal pure override returns (address) {
        return vm.addr(pk);
    }

    function test_7702Member_rotatingLifecycle() public {
        Mock7702BatchExecutor account = _delegate(PK);
        address eoa = address(account);
        assertGt(eoa.code.length, 0, "the delegated EOA has code");

        RotatingParams memory p = _params(3, 200, 10_000);
        p.members[0] = eoa; // slot 1: paid first
        _create(p);
        usdc.mint(eoa, 1_000e6);

        // [approve, join with $200 collateral] in one batch.
        Mock7702BatchExecutor.Call[] memory calls = _two(
            address(usdc),
            abi.encodeCall(usdc.approve, (address(circle), 200e6)),
            address(circle),
            abi.encodeCall(MHRotatingCircle.join, (circle.termsHash(), 200e6))
        );
        vm.prank(eoa);
        account.execute(calls);
        _join(slots[1], 0);
        _join(slots[2], 0);
        vm.warp(circle.startTime());

        for (uint256 r = 1; r <= 3; ++r) {
            _openRound(r);
            uint256 due = circle.amountDue(eoa, r);
            if (due != 0) {
                calls = _two(
                    address(usdc),
                    abi.encodeCall(usdc.approve, (address(circle), due)),
                    address(circle),
                    abi.encodeCall(MHRotatingCircle.contribute, (r, due))
                );
                vm.prank(eoa);
                account.execute(calls);
            }
            _payAll(r, 6); // slots 2 and 3
            circle.settleRound();
        }
        assertEq(uint8(circle.status()), uint8(CircleStatus.Completed));
        // Its collateral paid rounds 2 and 3 by draws (σ = 100%), so nothing is left to withdraw.
        assertEq(circle.memberState(eoa).sec, 0);
        assertEq(usdc.balanceOf(eoa), 1_000e6 - 6e6, "a 7702 member nets -fee like everyone else");
        assertEq(reputation.strikeCount(eoa), 0);
        _assertBuckets();
    }
}

contract MH7702MemberAccumulationTest is AccumulationFixture, Member7702 {
    uint256 internal constant PK = 0x7703;

    function _addr(uint256 pk) internal pure override returns (address) {
        return vm.addr(pk);
    }

    function test_7702Member_accumulationLifecycleInKind() public {
        Mock7702BatchExecutor account = _delegate(PK);
        address eoa = address(account);

        AccumulationParams memory p = _params(3, 2, 1_000, address(morpho), false);
        p.members[0] = eoa;
        _create(p);
        bytes32 terms = circle.termsHash();
        vm.prank(eoa);
        circle.join(terms, 0);
        _join(people[1]);
        _join(people[2]);
        vm.warp(circle.startTime());
        usdc.mint(eoa, 1_000e6);

        for (uint256 r = 1; r <= 2; ++r) {
            _openRound(r);
            Mock7702BatchExecutor.Call[] memory calls = _two(
                address(usdc),
                abi.encodeCall(usdc.approve, (address(circle), C)),
                address(circle),
                abi.encodeCall(MHAccumulationCircle.contribute, (r, C))
            );
            vm.prank(eoa);
            account.execute(calls);
            _payAll(r, 6);
            _deploy();
        }
        morpho.mockYield(morpho.totalAssets() / 50);
        _mature();
        circle.finalize();
        morpho.mockSetLiquidity(0);
        vm.prank(eoa); // the member itself (msg.sender == member) takes its settlement in kind
        circle.settleMemberInKind(eoa);
        assertGt(morpho.balanceOf(eoa), 0, "vault shares in kind");
        uint256 held = usdc.balanceOf(eoa) + morpho.convertToAssets(morpho.balanceOf(eoa));
        assertGt(held, 1_000e6, "principal plus earnings, net of the fee");
        _assertBuckets();
    }
}
