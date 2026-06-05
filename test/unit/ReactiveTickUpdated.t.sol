// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive._handleTickUpdated — detects range transitions per active
// position in the affected pool and dispatches the matching atomic checkpoint Callback. Uncapped.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {Vm} from "forge-std/Vm.sol";
import {ReactiveTestBase} from "../shared/ReactiveTestBase.t.sol";
import {RangeGuardReactiveHarness} from "../harness/RangeGuardReactiveHarness.sol";

contract ReactiveTickUpdatedTest is ReactiveTestBase {
    bytes32 internal constant POOL = bytes32(uint256(0xABCD));
    bytes32 internal constant POOL_B = bytes32(uint256(0xBEEF));

    function _register(bytes32 key, int24 lower, int24 upper, int24 entryTick) internal {
        reactive.exposed_handlePositionRegistered(_registeredLog(POOL, key, lower, upper, entryTick));
    }

    function _inRange(bytes32 key) internal view returns (bool inRange) {
        (,,, inRange,,) = reactive.positions(key);
    }

    /// Why: in -> out fires checkpointAndEmitOutOfRange and flips lastKnownInRange to false.
    function test_HandleTickUpdated_WhenInToOut_FiresOutOfRangeCallback() public {
        bytes32 key = bytes32(uint256(1));
        _register(key, -100, 100, 0); // in range

        vm.expectEmit(true, true, true, true, address(reactive));
        emit Callback(SEPOLIA_CHAIN_ID, hookAddr, CALLBACK_GAS_LIMIT, _outOfRangePayload(POOL, key));
        vm.expectEmit(true, true, false, true, address(reactive));
        emit RangeTransitionDetected(POOL, key, false, REACT_TS);

        reactive.exposed_handleTickUpdated(_tickLog(POOL, 500)); // 500 >= upper -> out

        assertFalse(_inRange(key), "flag flipped to out");
    }

    /// Why: out -> in fires checkpointAndEmitBackInRange and flips lastKnownInRange to true.
    function test_HandleTickUpdated_WhenOutToIn_FiresBackInRangeCallback() public {
        bytes32 key = bytes32(uint256(1));
        _register(key, 100, 200, 0); // tick 0 below -> out

        vm.expectEmit(true, true, true, true, address(reactive));
        emit Callback(SEPOLIA_CHAIN_ID, hookAddr, CALLBACK_GAS_LIMIT, _backInRangePayload(POOL, key));
        vm.expectEmit(true, true, false, true, address(reactive));
        emit RangeTransitionDetected(POOL, key, true, REACT_TS);

        reactive.exposed_handleTickUpdated(_tickLog(POOL, 150)); // 100 <= 150 < 200 -> in

        assertTrue(_inRange(key), "flag flipped to in");
    }

    /// Why: no boundary crossing -> no Callback, flag unchanged.
    function test_HandleTickUpdated_WhenNoTransition_NoCallback() public {
        bytes32 key = bytes32(uint256(1));
        _register(key, -100, 100, 0); // in range

        vm.recordLogs();
        reactive.exposed_handleTickUpdated(_tickLog(POOL, 50)); // still in range
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countCallbacks(logs), 0, "no Callback on no-transition");
        assertTrue(_inRange(key), "flag unchanged");
    }

    /// Why: a tick update for a different pool must not affect this pool's positions.
    function test_HandleTickUpdated_WhenDifferentPool_Ignored() public {
        bytes32 key = bytes32(uint256(1));
        _register(key, -100, 100, 0); // in range, pool POOL

        vm.recordLogs();
        reactive.exposed_handleTickUpdated(_tickLog(POOL_B, 500)); // out, but wrong pool
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countCallbacks(logs), 0, "no Callback for other pool");
        assertTrue(_inRange(key), "flag unchanged for other pool");
    }

    /// Why: an inactive (closed) position is skipped even on a real boundary crossing.
    function test_HandleTickUpdated_WhenInactive_Skipped() public {
        bytes32 key = bytes32(uint256(1));
        _register(key, -100, 100, 0);
        reactive.exposed_handlePositionClosed(_closedLog(POOL, key)); // now inactive

        vm.recordLogs();
        reactive.exposed_handleTickUpdated(_tickLog(POOL, 500));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0, "no Callback for inactive position");
    }

    /// Why: NO position cap on transition detection — all active positions in the pool fire (here 25,
    /// exceeding MAX_POSITIONS_PER_CYCLE = 20, proving the heartbeat cap does not apply).
    function test_HandleTickUpdated_WhenManyPositions_NoCap() public {
        uint256 count = 25;
        for (uint256 i = 0; i < count; i++) {
            _register(bytes32(uint256(i + 1)), -100, 100, 0); // all in range
        }

        vm.recordLogs();
        reactive.exposed_handleTickUpdated(_tickLog(POOL, 500)); // all transition out
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countCallbacks(logs), count, "every active position fires (uncapped)");
    }

    /// Why: the destination chain is parameterized — a contract configured for a different host chain
    /// dispatches its Callbacks to that chain id (not a hardcoded Sepolia).
    function test_HandleTickUpdated_RespectsParameterizedHookChainId() public {
        uint256 altChain = 84532; // e.g. Base Sepolia
        RangeGuardReactiveHarness alt = new RangeGuardReactiveHarness(hookAddr, altChain, CRON_TOPIC, MIN_INTERVAL);
        assertEq(alt.hookChainId(), altChain, "immutable hookChainId set from constructor");

        bytes32 key = bytes32(uint256(1));
        alt.exposed_handlePositionRegistered(_registeredLog(POOL, key, -100, 100, 0)); // in range

        vm.expectEmit(true, true, true, true, address(alt));
        emit Callback(altChain, hookAddr, CALLBACK_GAS_LIMIT, _outOfRangePayload(POOL, key));
        alt.exposed_handleTickUpdated(_tickLog(POOL, 500)); // transition out -> Callback to altChain
    }
}
