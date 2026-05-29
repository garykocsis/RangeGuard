// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title ComputeILHandler
/// @notice Invariant-test handler that drives RangeGuardHook._computeIL() with randomized
///         withdrawal amounts and exit ticks against a fixed, seeded position snapshot.
/// @dev    Each call reads the stored position into memory, computes IL, and records the
///         IL plus an independently-derived V_HODL / V_actual into ghost variables so the
///         invariant suite can check the floor relation and the held-value bound. The
///         seeded snapshot is captured once as a baseline so the suite can assert IL
///         computation never mutates it. All inputs are bounded so the price math stays
///         within uint256 (no reverts).
contract ComputeILHandler is Test {
    RangeGuardHookHarness public immutable harness;

    PoolId public constant POOL_ID = PoolId.wrap(bytes32(uint256(7)));
    bytes32 public constant KEY = keccak256("il-pos");

    uint256 internal constant PRICE_PRECISION = 1e18;
    uint256 internal constant MAX_AMT = 1e30;

    uint128 internal constant ENTRY0 = 5e17; // mixed (Case B) baseline
    uint128 internal constant ENTRY1 = 1000e6;
    uint256 internal constant ENTRY_NOTIONAL = 2000e6;

    // Ghosts: last computed IL and the independently-derived value components.
    uint256 public ghost_lastIL;
    uint256 public ghost_lastVHodl;
    uint256 public ghost_lastVActual;
    uint256 public ghost_calls;

    RangeGuardHook.PositionState internal _baseline;

    constructor(RangeGuardHookHarness _harness) {
        harness = _harness;

        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = ENTRY0;
        pos.entryAmt1 = ENTRY1;
        pos.entryTick = 0;
        pos.tickLower = -100;
        pos.tickUpper = 100;
        pos.depositTime = 1;
        pos.lastAccrualTime = 1;
        pos.active = true;
        pos.entryNotionalStable = ENTRY_NOTIONAL;

        harness.seedPosition(POOL_ID, KEY, pos);
        _baseline = harness.getPosition(POOL_ID, KEY);
    }

    /// @notice Fuzzed action: compute IL for the stored position at random out amounts/tick.
    function computeIL(uint256 o0, uint256 o1, int256 tickSeed) external {
        uint128 outAmt0 = uint128(bound(o0, 0, MAX_AMT));
        uint128 outAmt1 = uint128(bound(o1, 0, MAX_AMT));
        int24 tick = int24(bound(tickSeed, int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));

        RangeGuardHook.PositionState memory pos = harness.getPosition(POOL_ID, KEY);
        uint256 il = harness.exposed_computeIL(pos, outAmt0, outAmt1, tick);

        // Independently derive the value components for the invariant checks.
        uint256 p = harness.exposed_priceFromTick(tick);
        uint256 vHodl = uint256(pos.entryAmt1) + FullMath.mulDiv(uint256(pos.entryAmt0), p, PRICE_PRECISION);
        uint256 vActual = uint256(outAmt1) + FullMath.mulDiv(uint256(outAmt0), p, PRICE_PRECISION);

        ghost_lastIL = il;
        ghost_lastVHodl = vHodl;
        ghost_lastVActual = vActual;
        ghost_calls++;
    }

    function baseline() external view returns (RangeGuardHook.PositionState memory) {
        return _baseline;
    }
}
