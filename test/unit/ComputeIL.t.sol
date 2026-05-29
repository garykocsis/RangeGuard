// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._computeIL() and the shared _priceFromTick() helper.
// Follows testing-strategy.md naming: test_Function_WhenCondition_ExpectedBehavior().
// Inherits BaseRangeGuardTest for canonical deployment; both functions are pure and are
// reached directly via the RangeGuardHookHarness (no test-only code in production).
//
// Pricing is the raw token1/token0 ratio scaled by PRICE_PRECISION (1e18). At tick 0 the
// raw ratio is exactly 1, so P_exit == 1e18 and token0/token1 are 1:1 — which makes the
// IL arithmetic hand-verifiable. Non-1:1 prices are exercised with real ticks via the
// helper, and the extreme tick bounds are covered explicitly.

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract ComputeILTest is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;

    uint256 internal constant PRICE_PRECISION = 1e18;

    // tick 0 => raw ratio 1 => P_exit == 1e18 (token0 and token1 valued 1:1).
    int24 internal constant TICK_ONE = 0;
    // ~price 2x and ~price 0.5x (1.0001^6932 ~= 2). Used for direction, not exact values.
    int24 internal constant TICK_ABOVE = 6932;
    int24 internal constant TICK_BELOW = -6932;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager());
    }

    /// @dev Build a position carrying only the fields _computeIL reads (entry amounts).
    function _pos(uint128 entryAmt0, uint128 entryAmt1)
        internal
        pure
        returns (RangeGuardHook.PositionState memory pos)
    {
        pos.entryAmt0 = entryAmt0;
        pos.entryAmt1 = entryAmt1;
        pos.active = true;
    }

    /*//////////////////////////////////////////////////////////////
                          _priceFromTick: ANCHORS
    //////////////////////////////////////////////////////////////*/

    /// Why: tick 0 is the price anchor — the raw token1/token0 ratio is exactly 1, so the
    /// helper must return exactly PRICE_PRECISION. Everything else is relative to this.
    function test_PriceFromTick_WhenTickZero_ReturnsPricePrecision() public view {
        assertEq(harness.exposed_priceFromTick(TICK_ONE), PRICE_PRECISION, "tick 0 must price 1:1");
    }

    /// Why: a positive tick means more token1 per token0, so price must exceed 1e18.
    function test_PriceFromTick_WhenTickPositive_ReturnsAboveOne() public view {
        assertGt(harness.exposed_priceFromTick(TICK_ABOVE), PRICE_PRECISION, "positive tick > 1");
    }

    /// Why: a negative tick means less token1 per token0, so price must be below 1e18
    /// (and still strictly positive at a moderate tick).
    function test_PriceFromTick_WhenTickNegative_ReturnsBelowOne() public view {
        uint256 p = harness.exposed_priceFromTick(TICK_BELOW);
        assertLt(p, PRICE_PRECISION, "negative tick < 1");
        assertGt(p, 0, "moderate negative tick still > 0");
    }

    /// Why: price must be monotonic increasing in tick — the ordering underpins correct
    /// in-range/exit valuation across the whole tick domain.
    function test_PriceFromTick_WhenHigherTick_ReturnsHigherPrice() public view {
        uint256 low = harness.exposed_priceFromTick(TICK_BELOW);
        uint256 mid = harness.exposed_priceFromTick(TICK_ONE);
        uint256 high = harness.exposed_priceFromTick(TICK_ABOVE);
        assertLt(low, mid, "price increases with tick (low<mid)");
        assertLt(mid, high, "price increases with tick (mid<high)");
    }

    /*//////////////////////////////////////////////////////////////
                       _computeIL: ZERO-IL FLOOR
    //////////////////////////////////////////////////////////////*/

    /// Why: when withdrawn value equals held value (out == entry at 1:1), there is no
    /// loss — IL must be exactly zero.
    function test_ComputeIL_WhenOutEqualsEntry_ReturnsZero() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 1e18);
        // V_HODL = 1e18 + 1e18 = 2e18; V_actual = 1e18 + 1e18 = 2e18.
        uint256 il = harness.exposed_computeIL(pos, 1e18, 1e18, TICK_ONE);
        assertEq(il, 0, "no loss when out == entry");
    }

    /// Why: IL must never be negative; if the LP withdraws MORE value than held (e.g. fees
    /// accrued), IL is floored at zero rather than going negative.
    function test_ComputeIL_WhenValueGained_ReturnsZero() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 1e18);
        // V_HODL = 2e18; V_actual = 1.5e18 + 1e18 = 2.5e18 > V_HODL => floored to 0.
        uint256 il = harness.exposed_computeIL(pos, 15e17, 1e18, TICK_ONE);
        assertEq(il, 0, "gain floors IL to zero (never negative)");
    }

    /// Why: the core loss path — IL must equal exactly V_HODL - V_actual (at 1:1 price).
    function test_ComputeIL_WhenLoss_ReturnsExactDifference() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 1e18);
        // V_HODL = 2e18; V_actual = 0.5e18 + 1.2e18 = 1.7e18; IL = 0.3e18.
        uint256 il = harness.exposed_computeIL(pos, 5e17, 12e17, TICK_ONE);
        assertEq(il, 3e17, "IL == V_HODL - V_actual");
    }

    /*//////////////////////////////////////////////////////////////
                    _computeIL: DEPOSIT CASES A / B / C
    //////////////////////////////////////////////////////////////*/

    /// Why: Case A — deposit entered 100% token0 (entryAmt1 == 0). V_HODL must value the
    /// token0 leg only; IL computed against it correctly (at 1:1).
    function test_ComputeIL_WhenCaseA_AllToken0() public view {
        RangeGuardHook.PositionState memory pos = _pos(2e18, 0);
        // V_HODL = 0 + 2e18 = 2e18; V_actual = 0.3e18 + 1.5e18 = 1.8e18; IL = 0.2e18.
        uint256 il = harness.exposed_computeIL(pos, 15e17, 3e17, TICK_ONE);
        assertEq(il, 2e17, "Case A: 100% token0 entry");
    }

    /// Why: Case B — mixed deposit (both legs > 0); the demo case. Both entry legs must
    /// contribute to V_HODL.
    function test_ComputeIL_WhenCaseB_MixedDeposit() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 1e18);
        // V_HODL = 1e18 + 1e18 = 2e18; V_actual = 0.5e18 + 1.2e18 = 1.7e18; IL = 0.3e18.
        uint256 il = harness.exposed_computeIL(pos, 5e17, 12e17, TICK_ONE);
        assertEq(il, 3e17, "Case B: mixed entry");
    }

    /// Why: Case C — deposit entered 100% token1 (entryAmt0 == 0). The token0 term must
    /// vanish; V_HODL is the stable leg only.
    function test_ComputeIL_WhenCaseC_AllToken1() public view {
        RangeGuardHook.PositionState memory pos = _pos(0, 2e18);
        // V_HODL = 2e18 + 0 = 2e18; V_actual = 0.1e18 + 1.7e18 = 1.8e18; IL = 0.2e18.
        uint256 il = harness.exposed_computeIL(pos, 1e17, 17e17, TICK_ONE);
        assertEq(il, 2e17, "Case C: 100% token1 entry");
    }

    /*//////////////////////////////////////////////////////////////
                    _computeIL: PRICE APPLICATION & EXTREMES
    //////////////////////////////////////////////////////////////*/

    /// Why: confirms the token0 leg is valued at the actual exit price (not 1:1). With a
    /// price > 1 and zero withdrawal, IL must equal the price-valued token0 entry exactly.
    function test_ComputeIL_WhenPriceAboveOne_ValuesToken0AtPrice() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 0);
        uint256 pExit = harness.exposed_priceFromTick(TICK_ABOVE);
        // V_HODL = 0 + (1e18 * pExit / 1e18) = pExit; V_actual = 0; IL = pExit.
        uint256 il = harness.exposed_computeIL(pos, 0, 0, TICK_ABOVE);
        assertEq(il, pExit, "token0 valued at exit price");
        assertGt(pExit, PRICE_PRECISION, "sanity: price above one");
    }

    /// Why: extreme upper tick must not revert (overflow-safe via mulDiv) for realistic
    /// amounts, and must produce a large positive IL.
    function test_ComputeIL_WhenExtremeMaxTick_DoesNotRevert() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e6, 0);
        uint256 il = harness.exposed_computeIL(pos, 0, 0, TickMath.MAX_TICK);
        assertGt(il, 0, "max tick yields large positive IL without reverting");
    }

    /// Why: extreme lower tick floors the price to ~0, so the token0 leg contributes
    /// nothing; V_HODL collapses to the stable leg only.
    function test_ComputeIL_WhenExtremeMinTick_Token0ValueNearZero() public view {
        RangeGuardHook.PositionState memory pos = _pos(1e18, 5e6);
        // P_exit rounds to 0 at MIN_TICK => V_HODL = entryAmt1; V_actual = 0; IL = 5e6.
        uint256 il = harness.exposed_computeIL(pos, 0, 0, TickMath.MIN_TICK);
        assertEq(il, 5e6, "min tick: token0 leg ~ 0, only stable leg remains");
    }

    /*//////////////////////////////////////////////////////////////
                          DECIMAL-AGNOSTIC CHECK
    //////////////////////////////////////////////////////////////*/

    /// Why: the math is decimal-agnostic — with an 18-decimal numeraire (raw amounts at
    /// 1e18 scale) the same formula holds and IL comes out in raw token1 units.
    function test_ComputeIL_WhenNumeraire18Decimals_ComputesInRawUnits() public view {
        // Entry: 1 token0 + 2000 "stable" (18-dec) ; at 1:1 price.
        RangeGuardHook.PositionState memory pos = _pos(1e18, 2000e18);
        // V_HODL = 2000e18 + 1e18 = 2001e18; V_actual = 0.5e18 + 1900e18 = 1900.5e18.
        // IL = 100.5e18.
        uint256 il = harness.exposed_computeIL(pos, 5e17, 1900e18, TICK_ONE);
        assertEq(il, 1005e17, "18-decimal numeraire: IL in raw token1 units");
    }
}
