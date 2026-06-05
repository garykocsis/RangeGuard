// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive.react() routing — each subscribed source dispatches to the right
// handler. react() is vmOnly; in plain Foundry vm == true (no system contract), so it is callable.
// Naming per testing-strategy.md.

import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";
import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";

contract ReactiveReactRoutingTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));
    bytes32 internal constant KEY = bytes32(uint256(1));

    function _active(bytes32 key) internal view returns (bool active) {
        (,,,, active,) = reactive.positions(key);
    }

    function _inRange(bytes32 key) internal view returns (bool inRange) {
        (,,, inRange,,) = reactive.positions(key);
    }

    function _lastCheckpoint(bytes32 key) internal view returns (uint256 lastCp) {
        (,,,,, lastCp) = reactive.positions(key);
    }

    /// PositionRegistered topic -> _handlePositionRegistered.
    function test_React_WhenPositionRegisteredTopic_RoutesToRegister() public {
        reactive.react(_registeredLog(POOL, KEY, -100, 100, 0));
        assertTrue(_active(KEY), "registered via react routing");
    }

    /// TickUpdated topic -> _handleTickUpdated (transition detected).
    function test_React_WhenTickUpdatedTopic_RoutesToTick() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0)); // in range
        reactive.react(_tickLog(POOL, 500)); // out
        assertFalse(_inRange(KEY), "tick routing flipped range status");
    }

    /// PositionClosed topic -> _handlePositionClosed.
    function test_React_WhenPositionClosedTopic_RoutesToClose() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));
        reactive.react(_closedLog(POOL, KEY));
        assertFalse(_active(KEY), "closed via react routing");
        assertEq(reactive.activeKeysLength(), 0, "untracked via react routing");
    }

    /// A log from the system contract (address(service)) -> _handleHeartbeat (regardless of topic).
    function test_React_WhenFromSystemContract_RoutesToHeartbeat() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));
        vm.warp(REACT_TS + MIN_INTERVAL); // due
        reactive.react(_cronLog());
        assertEq(_lastCheckpoint(KEY), REACT_TS + MIN_INTERVAL, "heartbeat ran via react routing");
    }

    /// An unrecognized topic from a non-service contract is ignored (no state change, no revert).
    function test_React_WhenUnknownTopic_NoOp() public {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, KEY, -100, 100, 0));

        IReactive.LogRecord memory log =
            _log(SEPOLIA_CHAIN_ID, hookAddr, uint256(keccak256("Nonsense(uint256)")), uint256(POOL), 0, "");

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countCallbacks(logs), 0, "no Callback on unknown topic");
        assertTrue(_active(KEY), "state unchanged on unknown topic");
        assertEq(reactive.activeKeysLength(), 1, "tracking unchanged on unknown topic");
    }
}
