// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive._handlePositionRegistered — adds a position to tracking and
// initializes lastKnownInRange from the entry tick (mirrors the hook's _lastRangeEventInRange init).
// Driven via the harness's exposed handler with manually built LogRecords.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";

contract ReactivePositionRegisteredTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));
    bytes32 internal constant KEY = bytes32(uint256(1));

    function _info(bytes32 key)
        internal
        view
        returns (bytes32 poolId, int24 tickLower, int24 tickUpper, bool lastKnownInRange, bool active, uint256 lastCp)
    {
        return reactive.positions(key);
    }

    /// Case B: entry tick in range -> lastKnownInRange true; pushed to activeKeys; event emitted.
    function test_HandlePositionRegistered_WhenInRange_TracksAndInitsTrue() public {
        vm.expectEmit(true, true, false, true, address(reactive));
        emit PositionTracked(POOL, KEY, true, REACT_TS);
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));

        (bytes32 poolId, int24 lower, int24 upper, bool inRange, bool active, uint256 lastCp) = _info(KEY);
        assertEq(poolId, POOL, "poolId tracked");
        assertEq(lower, int24(-100), "tickLower tracked");
        assertEq(upper, int24(100), "tickUpper tracked");
        assertTrue(inRange, "in range -> true");
        assertTrue(active, "active");
        assertEq(lastCp, REACT_TS, "lastCheckpointTime seeded to now");
        assertEq(reactive.activeKeysLength(), 1, "pushed to activeKeys");
        assertEq(reactive.activeKeys(0), KEY, "activeKeys[0] == key");
    }

    /// Case A: entry tick below range -> lastKnownInRange false.
    function test_HandlePositionRegistered_WhenBelowRange_InitsFalse() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, 100, 200, 0)); // tick 0 < 100
        (,,, bool inRange,,) = _info(KEY);
        assertFalse(inRange, "below range -> false");
    }

    /// Case C: entry tick above range -> lastKnownInRange false.
    function test_HandlePositionRegistered_WhenAboveRange_InitsFalse() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -200, -100, 0)); // tick 0 >= -100
        (,,, bool inRange,,) = _info(KEY);
        assertFalse(inRange, "above range -> false");
    }

    /// Why: half-open [lower, upper) — tick == upper is OUT of range.
    function test_HandlePositionRegistered_WhenEntryEqualsUpper_InitsFalse() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 0, 0)); // entryTick == upper
        (,,, bool inRange,,) = _info(KEY);
        assertFalse(inRange, "tick == upper -> false");
    }

    /// Why: duplicate registration for an already-active key is a no-op (no double-push, no overwrite).
    function test_HandlePositionRegistered_WhenAlreadyActive_SkipsDuplicate() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));
        // Second registration with different bounds must NOT overwrite or double-push.
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, 100, 200, 0));

        (, int24 lower, int24 upper, bool inRange,,) = _info(KEY);
        assertEq(lower, int24(-100), "bounds unchanged by duplicate");
        assertEq(upper, int24(100), "bounds unchanged by duplicate");
        assertTrue(inRange, "range status unchanged by duplicate");
        assertEq(reactive.activeKeysLength(), 1, "no double-push");
    }

    /// Why: multiple distinct positions are each tracked independently.
    function test_HandlePositionRegistered_WhenMultiple_TracksEach() public {
        bytes32 k2 = bytes32(uint256(2));
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, k2, 100, 200, 0));
        assertEq(reactive.activeKeysLength(), 2, "both tracked");
        assertEq(reactive.activeKeys(1), k2, "second key pushed");
    }
}
