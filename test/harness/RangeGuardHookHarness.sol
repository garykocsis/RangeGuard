// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {RangeGuardHook} from "../../src/RangeGuardHook.sol";

/// @title RangeGuardHookHarness
/// @notice Test-only harness exposing RangeGuardHook internals for unit testing.
/// @dev    Per the project's test-seeding decision, this lives entirely in the test
///         tree so no test-only code leaks into the production contract. It:
///           - overrides validateHookAddress() to a no-op so the harness can be
///             deployed at any address (we call internals directly, never through
///             the PoolManager, so hook-flag encoding is irrelevant here);
///           - exposes setters to seed PoolConfig / PositionState directly;
///           - exposes the internal _accrue() and a position getter.
contract RangeGuardHookHarness is RangeGuardHook {
    constructor(IPoolManager _manager) RangeGuardHook(_manager) {}

    /// @dev Skip hook-address flag validation during testing. The base function is
    ///      virtual specifically to allow this (see BaseHook NatSpec).
    function validateHookAddress(BaseHook) internal pure override {}

    /// @notice Seeds a pool's immutable config directly into storage.
    function seedConfig(PoolId poolId, PoolConfig memory cfg) external {
        poolConfig[poolId] = cfg;
    }

    /// @notice Seeds a position's state directly into storage.
    function seedPosition(PoolId poolId, bytes32 positionKey, PositionState memory pos) external {
        positions[poolId][positionKey] = pos;
    }

    /// @notice Seeds a pool's mutable buffer accounting directly into storage.
    function seedPoolState(PoolId poolId, PoolState memory state) external {
        poolState[poolId] = state;
    }

    /// @notice Exposes the internal accrual engine for direct unit testing.
    function exposed_accrue(PoolId poolId, bytes32 positionKey, int24 currentTick) external {
        _accrue(poolId, positionKey, currentTick);
    }

    /// @notice Exposes the internal tick->price helper for direct unit testing.
    function exposed_priceFromTick(int24 tick) external pure returns (uint256) {
        return _priceFromTick(tick);
    }

    /// @notice Exposes the internal IL computation for direct unit testing.
    function exposed_computeIL(PositionState memory pos, uint128 outAmt0, uint128 outAmt1, int24 exitTick)
        external
        pure
        returns (uint256)
    {
        return _computeIL(pos, outAmt0, outAmt1, exitTick);
    }

    /// @notice Exposes the internal payout wrapper (reads config + buffer state).
    function exposed_computePayout(PoolId poolId, PositionState memory pos, uint256 ILRaw)
        external
        view
        returns (uint256, LimitingFactor)
    {
        return _computePayout(poolId, pos, ILRaw);
    }

    /// @notice Exposes the pure three-cap payout core for direct unit / fuzz testing.
    function exposed_computePayoutAmount(
        uint256 ILRaw,
        uint256 earned,
        uint256 bufferBalance,
        uint16 maxPayoutPctOfIl,
        uint16 maxPayoutPctOfBuffer
    ) external pure returns (uint256, LimitingFactor) {
        return _computePayoutAmount(ILRaw, earned, bufferBalance, maxPayoutPctOfIl, maxPayoutPctOfBuffer);
    }

    /// @notice Returns the full stored PositionState for assertions.
    function getPosition(PoolId poolId, bytes32 positionKey) external view returns (PositionState memory) {
        return positions[poolId][positionKey];
    }
}
