// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IMHCircle } from "./interfaces/IMHCircle.sol";
import { IUSDC } from "./interfaces/IUSDC.sol";
import { IMHCircleRegistry } from "./interfaces/IMHCircleRegistry.sol";
import { IMHReputation } from "./interfaces/IMHReputation.sol";
import { RotatingConfig, AccumulationConfig } from "./MHCircleTypes.sol";
import { MHCircleTerms } from "./MHCircleTerms.sol";

/// @title MHCircleBase
/// @notice Shared plumbing for Moolahub circle implementations: immutables, the `_pay`/`owed` payout mechanism
///         (spec §4.1), strike reporting, the USDC-paused guard and the terms hash.
/// @dev Implementations are deployed once, never upgraded, and used through EIP-1167 clones. Immutables live in the
///      implementation's bytecode, so every clone shares them. The constructor disables initializers on the
///      implementation itself. There is no `receive`/`fallback`, no `tx.origin`, no code-size check and no
///      signature-based membership, so EIP-7702 wallets behave like any other `msg.sender`. No try/catch.
abstract contract MHCircleBase is IMHCircle, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc IMHCircle
    IUSDC public immutable USDC;
    /// @inheritdoc IMHCircle
    IMHCircleRegistry public immutable REGISTRY;
    /// @inheritdoc IMHCircle
    IMHReputation public immutable REPUTATION;

    /// @inheritdoc IMHCircle
    mapping(address account => uint256 amount) public owed;
    /// @inheritdoc IMHCircle
    uint256 public owedTotal;

    /// @param usdc USDC on this chain.
    /// @param registry The circle registry (final address; may not have code yet under CREATE3 deployment).
    /// @param reputation The reputation register (final address; may not have code yet).
    constructor(IUSDC usdc, IMHCircleRegistry registry, IMHReputation reputation) {
        if (
            address(usdc) == address(0) || address(registry) == address(0)
                || address(reputation) == address(0)
        ) {
            revert ZeroAddress();
        }
        USDC = usdc;
        REGISTRY = registry;
        REPUTATION = reputation;
        _disableInitializers();
    }

    /// @inheritdoc IMHCircle
    function claimOwed() external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        if (USDC.paused()) revert UsdcPaused();
        // Effects before the transfer. A still-blacklisted caller makes the USDC transfer revert, which rolls
        // this back and leaves the entry in place.
        owed[msg.sender] = 0;
        owedTotal -= amount;
        emit OwedClaimed(msg.sender, amount);
        IERC20(address(USDC)).safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- Internal

    /// @notice Pays `x` USDC to `to`, or queues it in `owed[to]` when `to` or this circle is blacklisted, or USDC is
    ///         paused.
    /// @dev Spec §4.1: `if (USDC.isBlacklisted(to) || USDC.paused())` → `owed[to] += x` and `PayoutQueued`;
    ///      otherwise `SafeERC20.safeTransfer`, reverting on failure. Audit R1-15: a blacklist on the circle itself
    ///      (FiatToken reverts a blacklisted sender) also queues, so the settlements that do not need this circle
    ///      to send USDC (the vault-share leg of in-kind exits) still complete. No low-level call and no try/catch,
    ///      so it cannot be gas-griefed (R8). A zero amount is a no-op. Callers must finish their own state
    ///      changes first (checks-effects-interactions) and be `nonReentrant`.
    /// @param to The payee.
    /// @param x The amount in USDC base units.
    function _pay(address to, uint256 x) internal {
        if (x == 0) return;
        if (USDC.isBlacklisted(to) || USDC.isBlacklisted(address(this)) || USDC.paused()) {
            owed[to] += x;
            owedTotal += x;
            emit PayoutQueued(to, x);
        } else {
            IERC20(address(USDC)).safeTransfer(to, x);
        }
    }

    /// @notice Reverts with `UsdcPaused` while USDC is paused, and with `CircleBlacklisted` while USDC blacklists
    ///         this circle. Spec §4.5: functions that record strikes or stall a circle on a timer must call this first.
    /// @dev Audit R2-11: FiatToken reverts every transfer to a blacklisted recipient, so while the circle itself is
    ///      blacklisted no member can pay; that is the same as a pause for every strike, penalty and stall gate.
    function _requireUsdcLive() internal view {
        if (USDC.paused()) revert UsdcPaused();
        if (USDC.isBlacklisted(address(this))) revert CircleBlacklisted();
    }

    /// @notice Records a strike for `user`. Called directly (no try/catch): Reputation never reverts for a
    ///         registered reporter, and every factory-created clone is registered before `initialize`.
    /// @param user The member.
    /// @param round The round.
    /// @param reason Why.
    function _strike(address user, uint256 round, IMHReputation.Reason reason) internal {
        REPUTATION.record(user, address(this), round, reason);
    }

    /// @notice Terms hash of this rotating circle (see `MHCircleTerms.rotating`).
    function _rotatingTermsHash(
        RotatingConfig memory config,
        address[] memory members,
        uint16[] memory securityBps
    ) internal view returns (bytes32) {
        return MHCircleTerms.rotating(block.chainid, address(this), config, members, securityBps);
    }

    /// @notice Terms hash of this accumulation circle (see `MHCircleTerms.accumulation`).
    function _accumulationTermsHash(AccumulationConfig memory config, address[] memory members)
        internal
        view
        returns (bytes32)
    {
        return MHCircleTerms.accumulation(block.chainid, address(this), config, members);
    }
}
