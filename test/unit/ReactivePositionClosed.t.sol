// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive._handlePositionClosed — marks a position inactive and removes it
// from activeKeys via swap-and-pop. Naming per testing-strategy.md.

import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";

contract ReactivePositionClosedTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));

    function _register(bytes32 key) internal {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, key, -100, 100, 0));
    }

    function _active(bytes32 key) internal view returns (bool active) {
        (,,,, active,) = reactive.positions(key);
    }

    /// Why: closing deactivates the record, pops it from activeKeys, and emits PositionUntracked.
    function test_HandlePositionClosed_WhenActive_DeactivatesAndUntracks() public {
        bytes32 key = bytes32(uint256(1));
        _register(key);
        assertTrue(_active(key), "active before close");

        vm.expectEmit(true, true, false, true, address(reactive));
        emit PositionUntracked(POOL, key, REACT_TS);
        reactive.exposed_handlePositionClosed(_closedLog(POOL, key));

        assertFalse(_active(key), "inactive after close");
        assertEq(reactive.activeKeysLength(), 0, "removed from activeKeys");
    }

    /// Why: swap-and-pop removes the target and moves the last key into its slot (order not preserved).
    function test_HandlePositionClosed_WhenMiddle_SwapAndPop() public {
        bytes32 k1 = bytes32(uint256(1));
        bytes32 k2 = bytes32(uint256(2));
        bytes32 k3 = bytes32(uint256(3));
        _register(k1);
        _register(k2);
        _register(k3); // activeKeys = [k1, k2, k3]

        reactive.exposed_handlePositionClosed(_closedLog(POOL, k1)); // remove index 0

        assertEq(reactive.activeKeysLength(), 2, "length decremented");
        // Last (k3) swapped into index 0; k2 remains at index 1.
        assertEq(reactive.activeKeys(0), k3, "last key swapped into removed slot");
        assertEq(reactive.activeKeys(1), k2, "k2 untouched");
        assertFalse(_active(k1), "k1 inactive");
        assertTrue(_active(k2), "k2 still active");
        assertTrue(_active(k3), "k3 still active");
    }

    /// Why: closing an unknown (never-registered) position is a no-op — no revert, no state change.
    function test_HandlePositionClosed_WhenUnknown_NoOp() public {
        bytes32 known = bytes32(uint256(1));
        _register(known);

        reactive.exposed_handlePositionClosed(_closedLog(POOL, bytes32(uint256(99)))); // never tracked

        assertEq(reactive.activeKeysLength(), 1, "activeKeys unchanged");
        assertTrue(_active(known), "known position untouched");
    }

    /// Why: a second close for an already-closed position is a no-op (dedup guard).
    function test_HandlePositionClosed_WhenAlreadyClosed_NoOp() public {
        bytes32 key = bytes32(uint256(1));
        _register(key);
        reactive.exposed_handlePositionClosed(_closedLog(POOL, key));
        assertEq(reactive.activeKeysLength(), 0, "removed once");

        // Second close must not underflow activeKeys or revert.
        reactive.exposed_handlePositionClosed(_closedLog(POOL, key));
        assertEq(reactive.activeKeysLength(), 0, "still empty, no underflow");
    }
}
