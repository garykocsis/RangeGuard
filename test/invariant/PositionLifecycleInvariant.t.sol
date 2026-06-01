// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for position registration via RangeGuardHook._afterAddLiquidity().
// Protocol-domain naming per testing-strategy.md (PositionLifecycleInvariant), with
// invariant_PropertyName() functions. Each invariant cites the exact line it validates
// from invariant-mapping.md. Registration is driven by AfterAddLiquidityHandler over the
// shared harness (randomized owners/amounts/ranges/salts + re-adds under random ordering).

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {AfterAddLiquidityHandler} from "./handlers/AfterAddLiquidityHandler.sol";

contract PositionLifecycleInvariant is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;
    AfterAddLiquidityHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AfterAddLiquidityHandler(rangeGuardHook.i_manager());
        harness = handler.harness();

        // Only the handler's register() may drive state during invariant runs.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AfterAddLiquidityHandler.register.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// invariant-mapping.md (Accounting): "accrual must never modify entry position
    /// snapshots" / (Lifecycle): "immutable snapshots must never mutate after registration".
    /// A registered position's entry snapshot must equal its first-recorded value forever,
    /// despite any number of re-adds (top-ups) at the same key.
    function invariant_EntrySnapshotImmutableAfterRegistration() public view {
        uint256 n = handler.keysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 k = handler.keyAt(i);
            RangeGuardHook.PositionState memory ghost = handler.ghostOf(k);
            RangeGuardHook.PositionState memory live = harness.getPosition(handler.poolId(), k);

            assertEq(live.entryAmt0, ghost.entryAmt0, "entryAmt0 mutated");
            assertEq(live.entryAmt1, ghost.entryAmt1, "entryAmt1 mutated");
            assertEq(live.entryTick, ghost.entryTick, "entryTick mutated");
            assertEq(live.tickLower, ghost.tickLower, "tickLower mutated");
            assertEq(live.tickUpper, ghost.tickUpper, "tickUpper mutated");
            assertEq(live.entryNotionalStable, ghost.entryNotionalStable, "notional mutated");
            assertEq(live.depositTime, ghost.depositTime, "depositTime mutated");
        }
    }

    /// invariant-mapping.md (Lifecycle): "active positions must always have valid entry
    /// snapshots" / "active positions must always have initialized accrual state". Every
    /// registered position stays active, and its accrual clock is seeded to its deposit time
    /// (dt == 0 baseline) and never rewinds below it.
    function invariant_RegisteredPositionsActiveWithSeededClock() public view {
        uint256 n = handler.keysLength();
        for (uint256 i = 0; i < n; i++) {
            RangeGuardHook.PositionState memory live = harness.getPosition(handler.poolId(), handler.keyAt(i));
            assertTrue(live.active, "registered position must remain active");
            assertEq(live.depositTime, live.lastAccrualTime, "clock seeded to deposit time (dt=0 baseline)");
            assertGt(live.depositTime, 0, "valid (non-zero) deposit timestamp");
        }
    }

    /// invariant-mapping.md (Accounting): "earnedCoverageStable must never decrease" and
    /// (Range & Accrual): "zero dt must produce zero accrual delta". Registration only ever
    /// runs the dt==0 baseline accrual, so earned coverage is exactly zero and no payout is
    /// pending for any registered position.
    function invariant_RegistrationAccruesNothing() public view {
        uint256 n = handler.keysLength();
        for (uint256 i = 0; i < n; i++) {
            RangeGuardHook.PositionState memory live = harness.getPosition(handler.poolId(), handler.keyAt(i));
            assertEq(live.earnedCoverageStable, 0, "registration must not accrue coverage");
        }
    }
}
