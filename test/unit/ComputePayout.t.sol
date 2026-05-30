// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._computePayout() and the pure _computePayoutAmount() core.
// Follows testing-strategy.md naming: test_Function_WhenCondition_ExpectedBehavior().
// Inherits BaseRangeGuardTest for canonical deployment; both functions are reached directly
// via the RangeGuardHookHarness (no test-only code in production).
//
// The three caps (BPS denominator 10,000):
//   IL_covered = ILRaw  * maxPayoutPctOfIl     / 10000
//   bufferCap  = buffer * maxPayoutPctOfBuffer / 10000
//   payout     = min(IL_covered, earned, bufferCap)
// Numbers below are chosen so every cap value is hand-verifiable and exactly one (or, for
// the tie tests, a deliberate set) is binding.

import {PoolId} from "v4-core/types/PoolId.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract ComputePayoutTest is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(42)));

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    /// @dev Asserts both return values of the pure core in one call.
    function _assertPayout(
        uint256 ILRaw,
        uint256 earned,
        uint256 buffer,
        uint16 pctIl,
        uint16 pctBuffer,
        uint256 expectedPayout,
        RangeGuardHook.LimitingFactor expectedFactor,
        string memory label
    ) internal view {
        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayoutAmount(ILRaw, earned, buffer, pctIl, pctBuffer);
        assertEq(payout, expectedPayout, string.concat(label, ": payout"));
        assertEq(uint256(factor), uint256(expectedFactor), string.concat(label, ": factor"));
    }

    /*//////////////////////////////////////////////////////////////
                            ZERO-IL SHORT CIRCUIT
    //////////////////////////////////////////////////////////////*/

    /// Why: IL_raw == 0 means no loss to cover. This is the ONLY path that returns NONE,
    /// and it must short-circuit regardless of earned/buffer/caps.
    function test_ComputePayout_WhenILRawZero_ReturnsNone() public view {
        _assertPayout(0, 1000, 1_000_000, 5000, 1000, 0, RangeGuardHook.LimitingFactor.NONE, "zero IL");
    }

    /*//////////////////////////////////////////////////////////////
                            EACH CAP BINDS
    //////////////////////////////////////////////////////////////*/

    /// Why: when IL_covered is the smallest of the three, it binds and is reported as IL_CAP.
    /// IL_covered = 100*5000/10000 = 50; earned 1000; bufferCap = 1e6*1000/10000 = 100000.
    function test_ComputePayout_WhenILCapBinds_ReturnsILCovered() public view {
        _assertPayout(100, 1000, 1_000_000, 5000, 1000, 50, RangeGuardHook.LimitingFactor.IL_CAP, "IL cap");
    }

    /// Why: when earned coverage is the smallest, it binds and is reported as COVERAGE_CAP.
    /// IL_covered = 100*10000/10000 = 100; earned 40; bufferCap = 1e6 (100%). min = 40.
    function test_ComputePayout_WhenCoverageCapBinds_ReturnsEarned() public view {
        _assertPayout(100, 40, 1_000_000, 10000, 10000, 40, RangeGuardHook.LimitingFactor.COVERAGE_CAP, "coverage cap");
    }

    /// Why: when the buffer cap is the smallest, it binds and is reported as BUFFER_CAP.
    /// IL_covered = 100 (100%); earned 1000; bufferCap = 300*1000/10000 = 30. min = 30.
    function test_ComputePayout_WhenBufferCapBinds_ReturnsBufferCap() public view {
        _assertPayout(100, 1000, 300, 10000, 1000, 30, RangeGuardHook.LimitingFactor.BUFFER_CAP, "buffer cap");
    }

    /*//////////////////////////////////////////////////////////////
                            ZERO-VALUE EDGES
    //////////////////////////////////////////////////////////////*/

    /// Why: an empty buffer makes bufferCap == 0, which binds at zero — the "buffer can't
    /// pay" case the callback later surfaces as a (partial/zero) payout. IL_raw > 0 so it is
    /// NOT NONE; it is BUFFER_CAP.
    function test_ComputePayout_WhenBufferEmpty_BindsBufferCapAtZero() public view {
        _assertPayout(100, 1000, 0, 5000, 1000, 0, RangeGuardHook.LimitingFactor.BUFFER_CAP, "empty buffer");
    }

    /// Why: a position that never accrued coverage (earned == 0) can receive nothing; this
    /// binds at zero and is reported as COVERAGE_CAP (not NONE — IL_raw > 0).
    function test_ComputePayout_WhenZeroEarned_BindsCoverageCapAtZero() public view {
        _assertPayout(100, 0, 1_000_000, 5000, 1000, 0, RangeGuardHook.LimitingFactor.COVERAGE_CAP, "zero earned");
    }

    /// Why: documents the rounding quirk — IL_raw > 0 but IL_covered truncates to 0
    /// (1*5000/10000 = 0). Payout is 0, attributed to IL_CAP (the starting factor), since
    /// neither earned nor bufferCap is strictly less than 0.
    function test_ComputePayout_WhenILCoveredRoundsToZero_ReturnsILCapAtZero() public view {
        _assertPayout(1, 1000, 1_000_000, 5000, 1000, 0, RangeGuardHook.LimitingFactor.IL_CAP, "IL rounds to zero");
    }

    /*//////////////////////////////////////////////////////////////
                          TIE-BREAK PRECEDENCE
    //////////////////////////////////////////////////////////////*/

    /// Why: when all three caps are equal, the earliest in precedence wins (IL_CAP).
    /// IL_covered = 100*5000/10000 = 50; earned = 50; bufferCap = 500*1000/10000 = 50.
    function test_ComputePayout_WhenAllCapsEqual_ReturnsILCap() public view {
        _assertPayout(100, 50, 500, 5000, 1000, 50, RangeGuardHook.LimitingFactor.IL_CAP, "all equal");
    }

    /// Why: IL_covered == earned, both below bufferCap — the tie resolves to IL_CAP
    /// (earned is not strictly less than payout). IL_covered 50, earned 50, bufferCap 100.
    function test_ComputePayout_WhenILEqualsEarnedBelowBuffer_ReturnsILCap() public view {
        _assertPayout(100, 50, 1000, 5000, 1000, 50, RangeGuardHook.LimitingFactor.IL_CAP, "IL==earned<buffer");
    }

    /// Why: earned == bufferCap, both below IL_covered — the tie resolves to COVERAGE_CAP
    /// (the earlier of the two). IL_covered = 100; earned = 50; bufferCap = 500*1000/10000 = 50.
    function test_ComputePayout_WhenEarnedEqualsBufferBelowIL_ReturnsCoverageCap() public view {
        _assertPayout(100, 50, 500, 10000, 1000, 50, RangeGuardHook.LimitingFactor.COVERAGE_CAP, "earned==buffer<IL");
    }

    /*//////////////////////////////////////////////////////////////
                          MAX CAPS & OVERFLOW
    //////////////////////////////////////////////////////////////*/

    /// Why: at 100% caps both percentage caps pass through unchanged, so payout collapses to
    /// min(ILRaw, earned, buffer). Here the raw buffer binds. IL_covered = 100, earned = 200,
    /// bufferCap = 50 (100% of 50).
    function test_ComputePayout_WhenMaxCaps_ReducesToMinOfRawEarnedBuffer() public view {
        _assertPayout(100, 200, 50, 10000, 10000, 50, RangeGuardHook.LimitingFactor.BUFFER_CAP, "max caps");
    }

    /// Why: at 100% caps a near-uint256-max IL must not overflow (FullMath carries the
    /// 512-bit intermediate); mulDiv(max, 10000, 10000) == max exactly.
    function test_ComputePayout_WhenLargeILAtMaxCap_DoesNotOverflow() public view {
        uint256 max = type(uint256).max;
        _assertPayout(max, max, max, 10000, 10000, max, RangeGuardHook.LimitingFactor.IL_CAP, "no overflow at max");
    }

    /*//////////////////////////////////////////////////////////////
                       WRAPPER WIRING (config + state)
    //////////////////////////////////////////////////////////////*/

    /// @dev Minimal config carrying just the two payout caps; other fields are arbitrary.
    function _cfg(uint16 pctIl, uint16 pctBuffer) internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.maxPayoutPctOfIl = pctIl;
        cfg.maxPayoutPctOfBuffer = pctBuffer;
    }

    function _posEarned(uint256 earned) internal pure returns (RangeGuardHook.PositionState memory pos) {
        pos.earnedCoverageStable = earned;
        pos.active = true;
    }

    /// Why: the wrapper must read the caps from PoolConfig, the buffer from PoolState, and
    /// earned from the in-memory snapshot — then apply the identical cap logic. Here IL binds.
    /// IL_covered = 100*5000/10000 = 50; earned 1000; bufferCap = 1e6*1000/10000 = 100000.
    function test_ComputePayout_WhenWrapperReadsConfigAndState_AppliesCaps() public {
        harness.seedConfig(POOL_ID, _cfg(5000, 1000));
        RangeGuardHook.PoolState memory st;
        st.bufferBalanceStable = 1_000_000;
        harness.seedPoolState(POOL_ID, st);

        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayout(POOL_ID, _posEarned(1000), 100);
        assertEq(payout, 50, "wrapper payout");
        assertEq(uint256(factor), uint256(RangeGuardHook.LimitingFactor.IL_CAP), "wrapper factor");
    }

    /// Why: confirms the wrapper sources bufferBalance from PoolState (not config) by making
    /// the buffer cap the binding constraint. bufferCap = 300*1000/10000 = 30.
    function test_ComputePayout_WhenWrapperBufferBinds_ReturnsBufferCap() public {
        harness.seedConfig(POOL_ID, _cfg(10000, 1000));
        RangeGuardHook.PoolState memory st;
        st.bufferBalanceStable = 300;
        harness.seedPoolState(POOL_ID, st);

        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayout(POOL_ID, _posEarned(1000), 100);
        assertEq(payout, 30, "wrapper buffer payout");
        assertEq(uint256(factor), uint256(RangeGuardHook.LimitingFactor.BUFFER_CAP), "wrapper buffer factor");
    }

    /// Why: the wrapper must also short-circuit to NONE when IL_raw == 0, independent of
    /// the seeded config / buffer / earned.
    function test_ComputePayout_WhenWrapperILRawZero_ReturnsNone() public {
        harness.seedConfig(POOL_ID, _cfg(5000, 1000));
        RangeGuardHook.PoolState memory st;
        st.bufferBalanceStable = 1_000_000;
        harness.seedPoolState(POOL_ID, st);

        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayout(POOL_ID, _posEarned(1000), 0);
        assertEq(payout, 0, "wrapper zero-IL payout");
        assertEq(uint256(factor), uint256(RangeGuardHook.LimitingFactor.NONE), "wrapper zero-IL factor");
    }
}
