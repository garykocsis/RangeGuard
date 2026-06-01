// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for the permissionless checkpoint() accrual driver. Protocol-domain naming per
// testing-strategy.md, with invariant_PropertyName() functions citing invariant-mapping.md. Driven
// by CheckpointHandler, which advances time and checkpoints in/out-of-range positions over a
// committed pool. Proves checkpoint() preserves the accrual invariants through its real entry point.

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {CheckpointHandler} from "./handlers/CheckpointHandler.sol";

contract CheckpointInvariant is BaseRangeGuardTest {
    CheckpointHandler internal handler;
    RangeGuardHookHarness internal harness;

    function setUp() public override {
        super.setUp();
        handler = new CheckpointHandler(rangeGuardHook.i_manager());
        harness = handler.harness();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = CheckpointHandler.checkpoint.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _main() internal view returns (RangeGuardHook.PositionState memory) {
        return harness.getPosition(handler.poolId(), handler.keyMain());
    }

    /// invariant-mapping.md (Range & Accrual): "checkpoint() must never reduce total earned coverage".
    function invariant_CheckpointNeverDecreasesCoverage() public view {
        assertGe(_main().earnedCoverageStable, handler.ghost_earnedHighWater(), "checkpoint reduced coverage");
    }

    /// invariant-mapping.md (Accounting): "earnedCoverageStable must never exceed the configured
    /// accrual ceiling" — preserved when accrual is driven through checkpoint().
    function invariant_CheckpointCoverageNeverExceedsCeiling() public view {
        assertLe(_main().earnedCoverageStable, handler.CAP(), "checkpoint exceeded ceiling");
    }

    /// invariant-mapping.md (Range & Accrual): "checkpoint() must never bypass range gating" /
    /// "out-of-range checkpoints must produce zero accrual delta". The OOR position never accrues.
    function invariant_CheckpointOutOfRangeNeverAccrues() public view {
        RangeGuardHook.PositionState memory oor = harness.getPosition(handler.poolId(), handler.keyOor());
        assertEq(oor.earnedCoverageStable, 0, "out-of-range checkpoint accrued");
    }

    /// invariant-mapping.md (Timing): "lastAccrualTime must monotonically increase". The MAIN clock
    /// can never fall below the highest value observed across all checkpoints.
    function invariant_CheckpointClockMonotonic() public view {
        assertGe(_main().lastAccrualTime, handler.ghost_clockHighWater(), "checkpoint rewound the clock");
    }

    /// invariant-mapping.md (Lifecycle): "inactive positions must never checkpoint". The never-touched
    /// inactive position stays unaccrued and inactive (checkpointing it would revert PositionNotActive).
    function invariant_CheckpointInactiveUntouched() public view {
        RangeGuardHook.PositionState memory inactive = harness.getPosition(handler.poolId(), handler.keyInactive());
        assertEq(inactive.earnedCoverageStable, 0, "inactive position accrued");
        assertEq(inactive.active, false, "inactive position activated");
    }
}
