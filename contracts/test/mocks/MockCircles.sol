// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MHCircleBase } from "../../src/circles/MHCircleBase.sol";
import { IUSDC } from "../../src/circles/interfaces/IUSDC.sol";
import { IMHCircleRegistry } from "../../src/circles/interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "../../src/circles/interfaces/IMHReputation.sol";
import { CircleMode, RotatingParams, AccumulationParams } from "../../src/circles/MHCircleTypes.sol";

/// @notice Test-only circle core on top of the real `MHCircleBase`. It records what `initialize` received and
///         exposes the base's internal helpers so the factory and the `_pay`/`owed` mechanism can be tested before
///         the real circles exist. Never deploy.
abstract contract MockCircleCore is MHCircleBase {
    /// @notice `initialize` reverts with BadConfig for this id, to test that a failed create rolls back.
    bytes32 public constant REVERT_ID = keccak256("MOCK_REVERT");

    bytes32 public circleId;
    bytes32 public termsHash;
    uint256 public memberCount;
    address public initCaller;
    /// @notice Whether the clone was already a Reputation reporter when `initialize` ran (spec order).
    bool public reporterAtInit;
    /// @notice Whether the factory already flagged the clone as a circle when `initialize` ran (must be false).
    bool public isCircleAtInit;

    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation)
        MHCircleBase(usdc, registry, reputation)
    { }

    function payForTest(address to, uint256 amount) external nonReentrant {
        _pay(to, amount);
    }

    function strikeForTest(address user, uint256 round, IMHReputation.Reason reason) external {
        _strike(user, round, reason);
    }

    function requireUsdcLiveForTest() external view {
        _requireUsdcLive();
    }

    function _record(bytes32 id, uint256 members) internal {
        if (id == REVERT_ID) revert BadConfig();
        circleId = id;
        memberCount = members;
        initCaller = msg.sender;
        reporterAtInit = REPUTATION.isReporter(address(this));
        // Test-only probe of the caller; a non-factory caller simply yields false.
        (bool ok, bytes memory ret) =
            msg.sender.staticcall(abi.encodeWithSignature("isCircle(address)", address(this)));
        isCircleAtInit = ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}

/// @dev Exposes `initialize(RotatingParams)` with the same selector as `IMHRotatingCircle`, which is all the factory
///      calls; it does not implement the full rotating surface.
contract MockRotatingCircle is MockCircleCore {
    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation)
        MockCircleCore(usdc, registry, reputation)
    { }

    function circleMode() external pure returns (CircleMode) {
        return CircleMode.Rotating;
    }

    function initialize(RotatingParams calldata p) external initializer {
        _record(p.config.circleId, p.members.length);
        termsHash = _rotatingTermsHash(p.config, p.members, p.securityBps);
    }
}

/// @dev Exposes `initialize(AccumulationParams)` with the same selector as `IMHAccumulationCircle`, which is all the
///      factory calls; it does not implement the full accumulation surface.
contract MockAccumulationCircle is MockCircleCore {
    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation)
        MockCircleCore(usdc, registry, reputation)
    { }

    function circleMode() external pure returns (CircleMode) {
        return CircleMode.Accumulation;
    }

    function initialize(AccumulationParams calldata p) external initializer {
        _record(p.config.circleId, p.members.length);
        termsHash = _accumulationTermsHash(p.config, p.members);
    }
}
