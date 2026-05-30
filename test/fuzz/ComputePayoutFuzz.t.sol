// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Property-based fuzz tests for RangeGuardHook._computePayoutAmount().
// Follows testing-strategy.md naming: testFuzz_Function_Property().
// These assert the payout-cap PROPERTIES that must hold across randomized inputs (fixed
// scenarios live in test/unit/ComputePayout.t.sol). Inherits BaseRangeGuardTest; the core
// is pure and reached via the harness.
//
// Percentage caps are bounded to [0, BPS_DENOM] — the valid-config domain enforced at pool
// initialization (maxPayoutPct* <= 10,000). The `payout <= bufferBalance` property depends
// on that bound. Amounts are bounded to MAX_AMT (far above realistic positions) so the
// independent mulDiv recomputations stay obviously within range.

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract ComputePayoutFuzzTest is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;

    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant MAX_AMT = 1e30;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    function _amt(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, MAX_AMT);
    }

    function _pct(uint256 seed) internal pure returns (uint16) {
        return uint16(bound(seed, 0, BPS_DENOM));
    }

    /// Proves: payout never exceeds ANY of the three caps, nor the raw buffer balance.
    /// The buffer bound holds because pctBuffer <= BPS_DENOM (the init-enforced config rule).
    function testFuzz_ComputePayout_NeverExceedsAnyCap(
        uint256 ilSeed,
        uint256 earnedSeed,
        uint256 bufSeed,
        uint256 pctIlSeed,
        uint256 pctBufSeed
    ) public view {
        uint256 ILRaw = _amt(ilSeed);
        uint256 earned = _amt(earnedSeed);
        uint256 buffer = _amt(bufSeed);
        uint16 pctIl = _pct(pctIlSeed);
        uint16 pctBuffer = _pct(pctBufSeed);

        (uint256 payout,) = harness.exposed_computePayoutAmount(ILRaw, earned, buffer, pctIl, pctBuffer);

        uint256 ilCovered = FullMath.mulDiv(ILRaw, pctIl, BPS_DENOM);
        uint256 bufferCap = FullMath.mulDiv(buffer, pctBuffer, BPS_DENOM);

        assertLe(payout, ilCovered, "payout exceeded IL_covered");
        assertLe(payout, earned, "payout exceeded earned");
        assertLe(payout, bufferCap, "payout exceeded bufferCap");
        assertLe(payout, buffer, "payout exceeded buffer balance");
    }

    /// Proves: when IL_raw > 0, payout is exactly min(IL_covered, earned, bufferCap); when
    /// IL_raw == 0 it is exactly 0 (the short-circuit).
    function testFuzz_ComputePayout_EqualsMinOfThreeCaps(
        uint256 ilSeed,
        uint256 earnedSeed,
        uint256 bufSeed,
        uint256 pctIlSeed,
        uint256 pctBufSeed
    ) public view {
        uint256 ILRaw = _amt(ilSeed);
        uint256 earned = _amt(earnedSeed);
        uint256 buffer = _amt(bufSeed);
        uint16 pctIl = _pct(pctIlSeed);
        uint16 pctBuffer = _pct(pctBufSeed);

        (uint256 payout,) = harness.exposed_computePayoutAmount(ILRaw, earned, buffer, pctIl, pctBuffer);

        if (ILRaw == 0) {
            assertEq(payout, 0, "zero IL must yield zero payout");
            return;
        }

        uint256 ilCovered = FullMath.mulDiv(ILRaw, pctIl, BPS_DENOM);
        uint256 bufferCap = FullMath.mulDiv(buffer, pctBuffer, BPS_DENOM);
        uint256 expected = ilCovered;
        if (earned < expected) expected = earned;
        if (bufferCap < expected) expected = bufferCap;

        assertEq(payout, expected, "payout != min(IL_covered, earned, bufferCap)");
    }

    /// Proves: the reported LimitingFactor always names a cap whose value equals the payout
    /// (and NONE is returned iff IL_raw == 0). This is what makes the factor trustworthy in
    /// the coverage report.
    function testFuzz_ComputePayout_FactorIdentifiesBindingCap(
        uint256 ilSeed,
        uint256 earnedSeed,
        uint256 bufSeed,
        uint256 pctIlSeed,
        uint256 pctBufSeed
    ) public view {
        uint256 ILRaw = _amt(ilSeed);
        uint256 earned = _amt(earnedSeed);
        uint256 buffer = _amt(bufSeed);
        uint16 pctIl = _pct(pctIlSeed);
        uint16 pctBuffer = _pct(pctBufSeed);

        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayoutAmount(ILRaw, earned, buffer, pctIl, pctBuffer);

        uint256 ilCovered = FullMath.mulDiv(ILRaw, pctIl, BPS_DENOM);
        uint256 bufferCap = FullMath.mulDiv(buffer, pctBuffer, BPS_DENOM);

        if (factor == RangeGuardHook.LimitingFactor.NONE) {
            assertEq(ILRaw, 0, "NONE only when IL_raw == 0");
            assertEq(payout, 0, "NONE must carry zero payout");
        } else if (factor == RangeGuardHook.LimitingFactor.IL_CAP) {
            assertEq(payout, ilCovered, "IL_CAP must equal IL_covered");
        } else if (factor == RangeGuardHook.LimitingFactor.COVERAGE_CAP) {
            assertEq(payout, earned, "COVERAGE_CAP must equal earned");
        } else {
            assertEq(payout, bufferCap, "BUFFER_CAP must equal bufferCap");
        }
    }

    /// Proves: IL_raw == 0 always returns (0, NONE) regardless of any other input.
    function testFuzz_ComputePayout_ZeroILRawReturnsNone(
        uint256 earnedSeed,
        uint256 bufSeed,
        uint256 pctIlSeed,
        uint256 pctBufSeed
    ) public view {
        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayoutAmount(0, _amt(earnedSeed), _amt(bufSeed), _pct(pctIlSeed), _pct(pctBufSeed));
        assertEq(payout, 0, "zero IL payout");
        assertEq(uint256(factor), uint256(RangeGuardHook.LimitingFactor.NONE), "zero IL factor");
    }
}
