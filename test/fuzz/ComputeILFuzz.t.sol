// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Property-based fuzz tests for RangeGuardHook._computeIL() and _priceFromTick().
// Follows testing-strategy.md naming: testFuzz_Function_Property().
// These assert mathematical PROPERTIES that must hold across randomized inputs, rather
// than fixed scenarios (those live in test/unit/ComputeIL.t.sol). Inherits
// BaseRangeGuardTest; both functions are pure and reached via the harness.
//
// Amounts are bounded to MAX_AMT and ticks to the TickMath domain so the price math
// stays within uint256 (the only overflow corner is max-uint128 amount AND near-MAX_TICK
// simultaneously, which is economically unreachable — see session notes).

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract ComputeILFuzzTest is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;

    uint256 internal constant PRICE_PRECISION = 1e18;
    uint256 internal constant MAX_AMT = 1e30; // generous; far above realistic positions

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    function _pos(uint128 a0, uint128 a1) internal pure returns (RangeGuardHook.PositionState memory pos) {
        pos.entryAmt0 = a0;
        pos.entryAmt1 = a1;
        pos.active = true;
    }

    function _tick(int256 seed) internal pure returns (int24) {
        return int24(bound(seed, int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
    }

    function _amt(uint256 seed) internal pure returns (uint128) {
        return uint128(bound(seed, 0, MAX_AMT));
    }

    /*//////////////////////////////////////////////////////////////
                              _priceFromTick
    //////////////////////////////////////////////////////////////*/

    /// Proves: price is monotonic non-decreasing in tick across the entire tick domain —
    /// the ordering that all exit/entry valuation relies on.
    function testFuzz_PriceFromTick_MonotonicInTick(int256 seedA, int256 seedB) public view {
        int24 tA = _tick(seedA);
        int24 tB = _tick(seedB);
        (int24 lo, int24 hi) = tA <= tB ? (tA, tB) : (tB, tA);
        assertLe(harness.exposed_priceFromTick(lo), harness.exposed_priceFromTick(hi), "price not monotonic in tick");
    }

    /*//////////////////////////////////////////////////////////////
                                _computeIL
    //////////////////////////////////////////////////////////////*/

    /// Proves: IL can never exceed the total held value (V_HODL) — coverage is bounded by
    /// the value the LP would have had by holding. Also exercises overflow-safety.
    function testFuzz_ComputeIL_NeverExceedsHodlValue(uint256 a0, uint256 a1, uint256 o0, uint256 o1, int256 tickSeed)
        public
        view
    {
        RangeGuardHook.PositionState memory pos = _pos(_amt(a0), _amt(a1));
        int24 tick = _tick(tickSeed);

        uint256 il = harness.exposed_computeIL(pos, _amt(o0), _amt(o1), tick);

        uint256 vHodl = uint256(pos.entryAmt1)
            + FullMath.mulDiv(uint256(pos.entryAmt0), harness.exposed_priceFromTick(tick), PRICE_PRECISION);
        assertLe(il, vHodl, "IL must never exceed V_HODL");
    }

    /// Proves: IL_raw matches the documented formula exactly for arbitrary inputs/tick —
    /// max(0, V_HODL - V_actual) with both legs valued at the same exit price.
    function testFuzz_ComputeIL_MatchesHodlMinusActual(uint256 a0, uint256 a1, uint256 o0, uint256 o1, int256 tickSeed)
        public
        view
    {
        RangeGuardHook.PositionState memory pos = _pos(_amt(a0), _amt(a1));
        uint128 outAmt0 = _amt(o0);
        uint128 outAmt1 = _amt(o1);
        int24 tick = _tick(tickSeed);
        uint256 p = harness.exposed_priceFromTick(tick);

        uint256 vHodl = uint256(pos.entryAmt1) + FullMath.mulDiv(uint256(pos.entryAmt0), p, PRICE_PRECISION);
        uint256 vActual = uint256(outAmt1) + FullMath.mulDiv(uint256(outAmt0), p, PRICE_PRECISION);
        uint256 expected = vHodl > vActual ? vHodl - vActual : 0;

        assertEq(harness.exposed_computeIL(pos, outAmt0, outAmt1, tick), expected, "IL != max(0, V_HODL - V_actual)");
    }

    /// Proves: when the LP withdraws at least as much of BOTH tokens as they entered with,
    /// there is no loss at any price — IL is exactly zero (IL_raw never negative).
    function testFuzz_ComputeIL_ZeroWhenWithdrawalCoversEntry(
        uint256 a0,
        uint256 a1,
        uint256 extra0,
        uint256 extra1,
        int256 tickSeed
    ) public view {
        uint128 entryAmt0 = _amt(a0);
        uint128 entryAmt1 = _amt(a1);
        // out >= entry componentwise (capped so out stays within uint128 / MAX range).
        uint128 outAmt0 = uint128(bound(extra0, entryAmt0, MAX_AMT));
        uint128 outAmt1 = uint128(bound(extra1, entryAmt1, MAX_AMT));

        uint256 il = harness.exposed_computeIL(_pos(entryAmt0, entryAmt1), outAmt0, outAmt1, _tick(tickSeed));
        assertEq(il, 0, "withdrawing >= entry on both legs => zero IL");
    }

    /// Proves: IL is non-increasing in withdrawn amounts — recovering more value (e.g. fees)
    /// can only reduce or hold IL, never increase it. Fixed entry/tick, out2 >= out1.
    function testFuzz_ComputeIL_NonIncreasingInWithdrawal(
        uint256 a0,
        uint256 a1,
        uint256 o0,
        uint256 o1,
        uint256 d0,
        uint256 d1,
        int256 tickSeed
    ) public view {
        RangeGuardHook.PositionState memory pos = _pos(_amt(a0), _amt(a1));
        int24 tick = _tick(tickSeed);

        uint128 out1a = _amt(o0);
        uint128 out1b = _amt(o1);
        uint128 out2a = uint128(bound(d0, out1a, MAX_AMT)); // >= out1a
        uint128 out2b = uint128(bound(d1, out1b, MAX_AMT)); // >= out1b

        uint256 ilLess = harness.exposed_computeIL(pos, out1a, out1b, tick);
        uint256 ilMore = harness.exposed_computeIL(pos, out2a, out2b, tick);
        assertLe(ilMore, ilLess, "more withdrawn must not increase IL");
    }

    /// Proves: in a pure-loss scenario (withdrew <= entry on both legs), IL is monotonic
    /// non-decreasing in price — a higher exit tick values the token0 deficit higher.
    function testFuzz_ComputeIL_MonotonicInTickWhenLosingBothLegs(
        uint256 a0,
        uint256 a1,
        uint256 o0,
        uint256 o1,
        int256 seedLo,
        int256 seedHi
    ) public view {
        uint128 entryAmt0 = _amt(a0);
        uint128 entryAmt1 = _amt(a1);
        uint128 outAmt0 = uint128(bound(o0, 0, entryAmt0)); // <= entry
        uint128 outAmt1 = uint128(bound(o1, 0, entryAmt1)); // <= entry
        RangeGuardHook.PositionState memory pos = _pos(entryAmt0, entryAmt1);

        int24 tLo = _tick(seedLo);
        int24 tHi = _tick(seedHi);
        if (tHi < tLo) (tLo, tHi) = (tHi, tLo);

        uint256 ilLo = harness.exposed_computeIL(pos, outAmt0, outAmt1, tLo);
        uint256 ilHi = harness.exposed_computeIL(pos, outAmt0, outAmt1, tHi);
        assertGe(ilHi, ilLo, "higher price must not reduce IL when losing both legs");
    }

    /// Proves: at parity (tick 0, 1:1 price) the math is scale-invariant (homogeneous of
    /// degree 1): scaling all amounts by k scales IL by k. This is the decimal-agnostic
    /// property — the result carries no implicit decimal assumption.
    function testFuzz_ComputeIL_ScaleInvariantAtParity(uint256 a0, uint256 a1, uint256 o0, uint256 o1, uint256 k)
        public
        view
    {
        uint128 x0 = uint128(bound(a0, 0, 1e24));
        uint128 x1 = uint128(bound(a1, 0, 1e24));
        uint128 y0 = uint128(bound(o0, 0, 1e24));
        uint128 y1 = uint128(bound(o1, 0, 1e24));
        k = bound(k, 1, 1e6);

        uint256 ilBase = harness.exposed_computeIL(_pos(x0, x1), y0, y1, int24(0));
        uint256 ilScaled = harness.exposed_computeIL(
            _pos(uint128(uint256(x0) * k), uint128(uint256(x1) * k)),
            uint128(uint256(y0) * k),
            uint128(uint256(y1) * k),
            int24(0)
        );
        assertEq(ilScaled, ilBase * k, "IL must scale linearly at parity (decimal-agnostic)");
    }

    /// Proves: at parity the closed form holds exactly — IL == max(0, (a0+a1) - (o0+o1)) —
    /// confirming both legs are summed 1:1 with no hidden scaling at the price anchor.
    function testFuzz_ComputeIL_AtParityEqualsNetValueLoss(uint256 a0, uint256 a1, uint256 o0, uint256 o1)
        public
        view
    {
        uint128 entryAmt0 = _amt(a0);
        uint128 entryAmt1 = _amt(a1);
        uint128 outAmt0 = _amt(o0);
        uint128 outAmt1 = _amt(o1);

        uint256 held = uint256(entryAmt0) + uint256(entryAmt1);
        uint256 got = uint256(outAmt0) + uint256(outAmt1);
        uint256 expected = held > got ? held - got : 0;

        uint256 il = harness.exposed_computeIL(_pos(entryAmt0, entryAmt1), outAmt0, outAmt1, int24(0));
        assertEq(il, expected, "parity IL != net value loss");
    }
}
