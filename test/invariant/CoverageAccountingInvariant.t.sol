// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for RangeGuardHook._accrue().
// Protocol-domain naming per testing-strategy.md (CoverageAccountingInvariant), with
// invariant_PropertyName() functions. Each invariant below cites the exact line it
// validates from invariant-mapping.md. Inherits BaseRangeGuardTest for canonical
// deployment; randomized accrual is driven by AccrueHandler over the shared harness.

import {PoolId} from "v4-core/types/PoolId.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {AccrueHandler} from "./handlers/AccrueHandler.sol";

contract CoverageAccountingInvariant is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;
    AccrueHandler internal handler;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager());
        handler = new AccrueHandler(harness);

        // Only the handler's accrue() may drive state during invariant runs.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = AccrueHandler.accrue.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _main() internal view returns (RangeGuardHook.PositionState memory) {
        return harness.getPosition(handler.POOL_ID(), handler.KEY_MAIN());
    }

    /// invariant-mapping.md (Accounting): "earnedCoverageStable must never decrease"
    /// Also (Range & Accrual): "checkpoint() must never reduce total earned coverage".
    /// The live earned total can never fall below the highest value ever observed.
    function invariant_CoverageNeverDecreases() public view {
        assertGe(_main().earnedCoverageStable, handler.ghost_earnedHighWater(), "earnedCoverageStable decreased");
    }

    /// invariant-mapping.md (Accounting): "earnedCoverageStable must never exceed the
    /// configured accrual ceiling".
    function invariant_CoverageNeverExceedsCeiling() public view {
        assertLe(_main().earnedCoverageStable, handler.CAP(), "earned exceeded ceiling");
    }

    /// invariant-mapping.md (Accounting/Lifecycle): "inactive positions must never accrue
    /// coverage". The inactive position's earned coverage stays zero across all calls.
    function invariant_InactivePositionNeverAccrues() public view {
        RangeGuardHook.PositionState memory inactive = harness.getPosition(handler.POOL_ID(), handler.KEY_INACTIVE());
        assertEq(inactive.earnedCoverageStable, 0, "inactive position accrued");
    }

    /// invariant-mapping.md (Range & Accrual): "coverage must only accrue while a position
    /// is in range" / "earnedCoverageStable must remain unchanged while out of range".
    /// The OOR position is only ever touched out of range, so it must never accrue.
    function invariant_OutOfRangePositionNeverAccrues() public view {
        RangeGuardHook.PositionState memory oor = harness.getPosition(handler.POOL_ID(), handler.KEY_OOR());
        assertEq(oor.earnedCoverageStable, 0, "out-of-range position accrued");
    }

    /// invariant-mapping.md (Timing/Accounting): "lastAccrualTime must monotonically
    /// increase". The live clock can never fall below the highest value observed,
    /// which also demonstrates dt never underflows.
    function invariant_LastAccrualTimeMonotonic() public view {
        assertGe(_main().lastAccrualTime, handler.ghost_clockHighWater(), "lastAccrualTime rewound");
    }

    /// invariant-mapping.md (Accounting): "accrual must never modify entry position
    /// snapshots". Every immutable entry field equals its registration-time baseline.
    function invariant_EntrySnapshotsRemainImmutable() public view {
        RangeGuardHook.PositionState memory live = _main();
        RangeGuardHook.PositionState memory base = handler.mainBaseline();

        assertEq(live.entryAmt0, base.entryAmt0, "entryAmt0 mutated");
        assertEq(live.entryAmt1, base.entryAmt1, "entryAmt1 mutated");
        assertEq(live.entryTick, base.entryTick, "entryTick mutated");
        assertEq(live.tickLower, base.tickLower, "tickLower mutated");
        assertEq(live.tickUpper, base.tickUpper, "tickUpper mutated");
        assertEq(live.depositTime, base.depositTime, "depositTime mutated");
        assertEq(live.entryNotionalStable, base.entryNotionalStable, "entryNotional mutated");
        assertEq(live.active, base.active, "active mutated");
    }
}
