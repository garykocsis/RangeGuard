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

contract SettlementInvariant is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;
    ComputeILHandler internal handler;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager());
        handler = new ComputeILHandler(harness);

        // Only the handler's computeIL() may drive state during invariant runs.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ComputeILHandler.computeIL.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
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
}
