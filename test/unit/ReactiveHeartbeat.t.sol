// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive._handleHeartbeat — periodic checkpointCallback dispatch for
// active positions past minCheckpointInterval, capped at MAX_POSITIONS_PER_CYCLE = 20.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {Vm} from "forge-std/Vm.sol";
import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";

contract ReactiveHeartbeatTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));

    function _register(bytes32 key) internal {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, key, -100, 100, 0));
    }

    function _lastCheckpoint(bytes32 key) internal view returns (uint256 lastCp) {
        (,,,,, lastCp) = reactive.positions(key);
    }

    /// Why: a freshly registered position (lastCheckpointTime == now) is within the interval -> skipped.
    function test_HandleHeartbeat_WhenWithinInterval_Skips() public {
        bytes32 key = bytes32(uint256(1));
        _register(key); // lastCheckpointTime == REACT_TS

        vm.recordLogs();
        reactive.exposed_handleHeartbeat(); // no time elapsed
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0, "skipped within interval");
    }

    /// Why: the interval gate is `>=`; exactly minCheckpointInterval elapsed -> due -> fires Callback,
    /// updates lastCheckpointTime, emits HeartbeatCheckpointFired.
    function test_HandleHeartbeat_WhenDue_FiresAndUpdatesTime() public {
        bytes32 key = bytes32(uint256(1));
        _register(key);
        vm.warp(REACT_TS + MIN_INTERVAL);

        vm.expectEmit(true, true, true, true, SYSTEM_ADDR);
        emit Callback(SEPOLIA_CHAIN_ID, hookAddr, CALLBACK_GAS_LIMIT, _checkpointPayload(POOL, key));
        vm.expectEmit(true, true, false, true, address(reactive));
        emit HeartbeatCheckpointFired(POOL, key, REACT_TS + MIN_INTERVAL);

        reactive.exposed_handleHeartbeat();

        assertEq(_lastCheckpoint(key), REACT_TS + MIN_INTERVAL, "lastCheckpointTime advanced");
    }

    /// Why: after a due heartbeat resets lastCheckpointTime, an immediate second heartbeat skips.
    function test_HandleHeartbeat_WhenCalledTwice_SecondRespectsInterval() public {
        bytes32 key = bytes32(uint256(1));
        _register(key);
        vm.warp(REACT_TS + MIN_INTERVAL);
        reactive.exposed_handleHeartbeat(); // fires, lastCheckpointTime = now

        vm.recordLogs();
        reactive.exposed_handleHeartbeat(); // no further time -> skip
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0, "second call within interval skips");
    }

    /// Why: inactive (closed) positions are skipped by the heartbeat.
    function test_HandleHeartbeat_WhenInactive_Skips() public {
        bytes32 key = bytes32(uint256(1));
        _register(key);
        reactive.exposed_handlePositionClosed(_closedLog(POOL, key));
        vm.warp(REACT_TS + MIN_INTERVAL);

        vm.recordLogs();
        reactive.exposed_handleHeartbeat();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0, "inactive skipped");
    }

    /// Why: the heartbeat is capped at MAX_POSITIONS_PER_CYCLE = 20 even with more due positions.
    function test_HandleHeartbeat_WhenManyDue_CapsAt20() public {
        uint256 count = 25;
        for (uint256 i = 0; i < count; i++) {
            _register(bytes32(uint256(i + 1)));
        }
        vm.warp(REACT_TS + MIN_INTERVAL); // all due

        vm.recordLogs();
        reactive.exposed_handleHeartbeat();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 20, "capped at MAX_POSITIONS_PER_CYCLE");

        // The first 20 (activeKeys order) were checkpointed; the 21st was not (time unchanged).
        assertEq(_lastCheckpoint(bytes32(uint256(1))), REACT_TS + MIN_INTERVAL, "position 1 checkpointed");
        assertEq(_lastCheckpoint(bytes32(uint256(21))), REACT_TS, "position 21 left for next cycle");
    }
}
