// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardReactive's lastKnownInRange tracking under arbitrary tick sequences.
// Invariant: after processing any TickUpdated, lastKnownInRange equals the in-range predicate of the
// most recent tick — transitions flip it to match, no-transition ticks leave it already matching.
// Naming per testing-strategy.md: testFuzz_*.

import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";

contract ReactiveLastKnownInRangeFuzzTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));
    bytes32 internal constant KEY = bytes32(uint256(1));
    int24 internal constant LOWER = -100;
    int24 internal constant UPPER = 100;

    function _inRange(bytes32 key) internal view returns (bool inRange) {
        (,,, inRange,,) = reactive.positions(key);
    }

    /// Why: across any sequence of ticks, lastKnownInRange must always equal the in-range status of
    /// the most recently processed tick (the handler only flips on genuine transitions).
    function testFuzz_LastKnownInRange_TracksMostRecentTick(int24[] calldata rawTicks, int24 entryTick) public {
        entryTick = int24(bound(int256(entryTick), -500, 500));
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, LOWER, UPPER, entryTick));

        // Initial guard mirrors the entry predicate.
        assertEq(_inRange(KEY), (entryTick >= LOWER && entryTick < UPPER), "init matches entry predicate");

        uint256 n = rawTicks.length < 32 ? rawTicks.length : 32; // bound work per run
        for (uint256 i = 0; i < n; i++) {
            int24 tick = int24(bound(int256(rawTicks[i]), -500, 500));
            reactive.exposed_handleTickUpdated(_tickLog(POOL, tick));

            bool expected = (tick >= LOWER && tick < UPPER);
            assertEq(_inRange(KEY), expected, "guard tracks most recent tick");
        }
    }

    /// Why: a position in a different pool is never touched by another pool's ticks, no matter the
    /// sequence — its guard stays at the entry predicate.
    function testFuzz_LastKnownInRange_UnaffectedByOtherPoolTicks(int24[] calldata rawTicks) public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, LOWER, UPPER, 0)); // in range -> true
        bytes32 otherPool = bytes32(uint256(0xBEEF));

        uint256 n = rawTicks.length < 32 ? rawTicks.length : 32;
        for (uint256 i = 0; i < n; i++) {
            int24 tick = int24(bound(int256(rawTicks[i]), -500, 500));
            reactive.exposed_handleTickUpdated(_tickLog(otherPool, tick)); // wrong pool
        }
        assertTrue(_inRange(KEY), "guard unaffected by other-pool ticks");
    }
}
