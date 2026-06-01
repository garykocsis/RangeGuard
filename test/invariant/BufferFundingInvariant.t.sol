// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for buffer funding via RangeGuardHook._afterSwap(). Protocol-domain naming
// per testing-strategy.md (BufferFundingInvariant), with invariant_PropertyName() functions.
// Each invariant cites the exact line it validates from invariant-mapping.md. Swaps are driven
// by AfterSwapHandler over the shared harness (randomized swap deltas under random ordering).

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {AfterSwapHandler} from "./handlers/AfterSwapHandler.sol";

contract BufferFundingInvariant is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;
    AfterSwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AfterSwapHandler(rangeGuardHook.i_manager());
        harness = handler.harness();

        // Only the handler's swap() may drive state during invariant runs.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AfterSwapHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// invariant-mapping.md (Pillar 2 / Accounting): the buffer is funded purely by swap skims,
    /// so `bufferBalanceStable` and `totalSkimmedStable` must both equal the running sum of
    /// contributions (no payouts occur in this handler).
    function invariant_BufferEqualsSummedSkims() public view {
        (uint256 buf, uint256 skimmed, uint256 paidOut) = harness.poolState(handler.poolId());
        assertEq(buf, handler.ghost_totalContribution(), "buffer == sum of swap contributions");
        assertEq(skimmed, handler.ghost_totalContribution(), "totalSkimmed == sum of swap contributions");
        assertEq(paidOut, 0, "no payouts from swaps");
    }

    /// invariant-mapping.md (Accounting): "bufferBalanceStable must never be negative". Buffer is
    /// only ever credited by afterSwap, so it stays at or above zero and matches its skim total.
    function invariant_BufferNeverExceedsSkimmed() public view {
        (uint256 buf, uint256 skimmed,) = harness.poolState(handler.poolId());
        assertLe(buf, skimmed, "buffer never exceeds cumulative skims (no payouts here)");
    }

    /// invariant-mapping.md (Range & Accrual): "afterSwap must never directly accrue positions"
    /// and "accrual calculations must never iterate over all LP positions". The seeded active
    /// position must be byte-for-byte unchanged regardless of how many swaps run.
    function invariant_AfterSwapNeverAccruesPositions() public view {
        RangeGuardHook.PositionState memory pos = harness.getPosition(handler.poolId(), handler.seededKey());
        assertEq(pos.earnedCoverageStable, handler.SEEDED_COVERAGE(), "afterSwap must not accrue coverage");
        assertEq(pos.lastAccrualTime, handler.SEEDED_CLOCK(), "afterSwap must not advance the accrual clock");
        assertTrue(pos.active, "afterSwap must not deactivate the position");
    }
}
