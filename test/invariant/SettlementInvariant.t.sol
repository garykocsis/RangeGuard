// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for RangeGuardHook._computeIL() (settlement domain).
// Protocol-domain naming per testing-strategy.md (SettlementInvariant), with
// invariant_PropertyName() functions. Each invariant cites the exact line it validates
// from invariant-mapping.md. Inherits BaseRangeGuardTest; randomized IL computation is
// driven by ComputeILHandler over the shared harness.

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {ComputeILHandler} from "./handlers/ComputeILHandler.sol";
import {ComputePayoutHandler} from "./handlers/ComputePayoutHandler.sol";

contract SettlementInvariant is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;
    ComputeILHandler internal handler;
    ComputePayoutHandler internal payoutHandler;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        handler = new ComputeILHandler(harness);
        payoutHandler = new ComputePayoutHandler(harness);

        // Only the handlers' fuzzed actions may drive state during invariant runs.
        targetContract(address(handler));
        bytes4[] memory ilSelectors = new bytes4[](1);
        ilSelectors[0] = ComputeILHandler.computeIL.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: ilSelectors}));

        targetContract(address(payoutHandler));
        bytes4[] memory payoutSelectors = new bytes4[](1);
        payoutSelectors[0] = ComputePayoutHandler.computePayout.selector;
        targetSelector(FuzzSelector({addr: address(payoutHandler), selectors: payoutSelectors}));
    }

    /// invariant-mapping.md (Settlement): "IL_raw must never be negative".
    /// IL is the floored difference: it must be exactly 0 when V_actual >= V_HODL, and
    /// exactly V_HODL - V_actual otherwise. This rules out any underflow/wraparound (a
    /// wrap would make IL enormous and break the equality).
    function invariant_ILRawNeverNegative() public view {
        uint256 vHodl = handler.ghost_lastVHodl();
        uint256 vActual = handler.ghost_lastVActual();
        uint256 expected = vHodl > vActual ? vHodl - vActual : 0;
        assertEq(handler.ghost_lastIL(), expected, "IL_raw is not the floored, non-negative difference");
    }

    /// invariant-mapping.md (Settlement): supports the payout caps
    /// "payout must never exceed ... IL_covered / earnedCoverageStable / bufferCap".
    /// IL_raw is bounded above by V_HODL (the total value the LP would have held), so every
    /// downstream cap (all <= IL_raw) is also bounded. Derived safety bound on IL itself.
    function invariant_ILNeverExceedsHodlValue() public view {
        assertLe(handler.ghost_lastIL(), handler.ghost_lastVHodl(), "IL_raw exceeded V_HODL");
    }

    /// invariant-mapping.md (Settlement): "settlement must never modify immutable entry
    /// snapshots". Across all IL computations, the stored entry snapshot equals its
    /// registration-time baseline (the _computeIL path never mutates position state).
    function invariant_EntrySnapshotsRemainImmutable() public view {
        RangeGuardHook.PositionState memory live = harness.getPosition(handler.POOL_ID(), handler.KEY());
        RangeGuardHook.PositionState memory base = handler.baseline();

        assertEq(live.entryAmt0, base.entryAmt0, "entryAmt0 mutated");
        assertEq(live.entryAmt1, base.entryAmt1, "entryAmt1 mutated");
        assertEq(live.entryTick, base.entryTick, "entryTick mutated");
        assertEq(live.tickLower, base.tickLower, "tickLower mutated");
        assertEq(live.tickUpper, base.tickUpper, "tickUpper mutated");
        assertEq(live.entryNotionalStable, base.entryNotionalStable, "entryNotional mutated");
    }

    /*//////////////////////////////////////////////////////////////
                          _computePayout INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// invariant-mapping.md (Settlement): "payout must never exceed IL_covered /
    /// earnedCoverageStable / bufferCap / bufferBalanceStable / the configured payout caps".
    /// Every computed payout is bounded by all three caps and by the raw buffer balance
    /// (the latter because the fuzzed cap percentages stay within the init-enforced
    /// [0, 10000] domain).
    function invariant_PayoutNeverExceedsAnyCap() public view {
        uint256 payout = payoutHandler.ghost_lastPayout();
        assertLe(payout, payoutHandler.ghost_lastILCovered(), "payout exceeded IL_covered");
        assertLe(payout, payoutHandler.ghost_lastEarned(), "payout exceeded earned coverage");
        assertLe(payout, payoutHandler.ghost_lastBufferCap(), "payout exceeded bufferCap");
        assertLe(payout, payoutHandler.ghost_lastBuffer(), "payout exceeded buffer balance");
    }

    /// invariant-mapping.md (Settlement): supports an unambiguous LimitingFactor in every
    /// settlement — the reported factor always names a cap whose value equals the payout,
    /// and NONE is reported iff there was no impermanent loss.
    function invariant_PayoutFactorMatchesBindingCap() public view {
        RangeGuardHook.LimitingFactor factor = payoutHandler.ghost_lastFactor();
        uint256 payout = payoutHandler.ghost_lastPayout();

        if (factor == RangeGuardHook.LimitingFactor.NONE) {
            assertEq(payoutHandler.ghost_lastILRaw(), 0, "NONE only when IL_raw == 0");
            assertEq(payout, 0, "NONE must carry zero payout");
        } else if (factor == RangeGuardHook.LimitingFactor.IL_CAP) {
            assertEq(payout, payoutHandler.ghost_lastILCovered(), "IL_CAP != IL_covered");
        } else if (factor == RangeGuardHook.LimitingFactor.COVERAGE_CAP) {
            assertEq(payout, payoutHandler.ghost_lastEarned(), "COVERAGE_CAP != earned");
        } else {
            assertEq(payout, payoutHandler.ghost_lastBufferCap(), "BUFFER_CAP != bufferCap");
        }
    }
}
