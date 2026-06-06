// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Shared base for RangeGuardReactive unit/fuzz tests. Deploys a RangeGuardReactiveHarness over the
// canonically-deployed hook address (vm == true in plain Foundry, so the constructor's subscription
// block is skipped and react()/handlers are callable). Provides manual LogRecord builders that mirror
// the hook's real event encodings (indexed fields in topics, the rest in data) and event mirrors for
// vm.expectEmit. Tests inherit and call the exposed internal handlers directly.

import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

import {BaseRangeGuardTest} from "./BaseRangeGuardTest.t.sol";
import {RangeGuardReactiveHarness} from "../harness/RangeGuardReactiveHarness.sol";
import {MockSystemContract} from "../harness/MockSystemContract.sol";

abstract contract ReactiveTestBase is BaseRangeGuardTest {
    RangeGuardReactiveHarness internal reactive;

    address internal hookAddr;
    address internal constant LP = address(0x11A0); // owner field in PositionRegistered (unused by handlers)

    uint256 internal constant CRON_TOPIC = 0xC0FFEE; // arbitrary Cron topic for tests
    uint256 internal constant MIN_INTERVAL = 120; // 2 minutes (demo)
    uint256 internal constant REACT_TS = 2_000_000;

    // Must match RangeGuardReactive's production constants exactly.
    uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(
        keccak256(
            "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
        )
    );
    uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256("TickUpdated(bytes32,int24,uint256)"));
    uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256("PositionClosed(bytes32,bytes32,address)"));

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;

    // reactive-lib-omni system contract (SYSTEM). Under the new lib, callbacks are dispatched via
    // SYSTEM.requestCallbackV_1_0, so the etched mock here is the Callback event emitter (not the
    // reactive contract). Dispatch-pinned expectEmit assertions use this as the emitter address.
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    // topic0 of IReactive.Callback(uint256,address,uint64,bytes) — for counting dispatched callbacks.
    bytes32 internal constant CALLBACK_TOPIC0 = keccak256("Callback(uint256,address,uint64,bytes)");

    // Event mirrors.
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);
    event PositionTracked(
        bytes32 indexed poolId, bytes32 indexed positionKey, bool initiallyInRange, uint256 timestamp
    );
    event PositionUntracked(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 timestamp);
    event RangeTransitionDetected(bytes32 indexed poolId, bytes32 indexed positionKey, bool inRange, uint256 timestamp);
    event HeartbeatCheckpointFired(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 timestamp);

    function setUp() public virtual override {
        super.setUp();
        hookAddr = address(rangeGuardHook);
        reactive = new RangeGuardReactiveHarness(hookAddr, SEPOLIA_CHAIN_ID, CRON_TOPIC, MIN_INTERVAL);
        // Etch the mock system contract at SYSTEM (0x8888…) AFTER constructing the harness: detectVm()
        // already ran in the constructor (no code present -> vm == true, so react() stays callable and
        // constructor subscriptions are skipped, matching plain-Foundry behavior). The mock is now
        // present so the handlers' SYSTEM.requestCallbackV_1_0 dispatch succeeds and re-emits Callback.
        vm.etch(SYSTEM_ADDR, address(new MockSystemContract()).code);
        vm.warp(REACT_TS);
    }

    /*//////////////////////////////////////////////////////////////
                            LOGRECORD BUILDERS
    //////////////////////////////////////////////////////////////*/

    function _log(uint256 chainId, address contract_, uint256 t0, uint256 t1, uint256 t2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = chainId;
        r.contractAddress = contract_;
        r.topic0 = t0;
        r.topic1 = t1;
        r.topic2 = t2;
        r.topic3 = 0;
        r.data = data;
        // blockNumber / opCode / blockHash / txHash / logIndex left zero (unused by handlers).
    }

    /// @dev PositionRegistered: poolId/positionKey/owner are indexed; the 9 remaining fields are data.
    function _registeredLog(bytes32 poolId, bytes32 positionKey, int24 tickLower, int24 tickUpper, int24 entryTick)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        bytes memory data = abi.encode(
            tickLower, tickUpper, uint128(0), uint128(0), uint256(0), entryTick, uint32(0), uint256(0), uint256(0)
        );
        return
            _log(SEPOLIA_CHAIN_ID, hookAddr, POSITION_REGISTERED_TOPIC_0, uint256(poolId), uint256(positionKey), data);
    }

    /// @dev TickUpdated: poolId is indexed; newTick + timestamp are data.
    function _tickLog(bytes32 poolId, int24 newTick) internal view returns (IReactive.LogRecord memory) {
        bytes memory data = abi.encode(newTick, uint256(block.timestamp));
        return _log(SEPOLIA_CHAIN_ID, hookAddr, TICK_UPDATED_TOPIC_0, uint256(poolId), 0, data);
    }

    /// @dev PositionClosed: poolId/positionKey indexed; owner is data (unused by handler).
    function _closedLog(bytes32 poolId, bytes32 positionKey) internal view returns (IReactive.LogRecord memory) {
        bytes memory data = abi.encode(LP);
        return _log(SEPOLIA_CHAIN_ID, hookAddr, POSITION_CLOSED_TOPIC_0, uint256(poolId), uint256(positionKey), data);
    }

    /// @dev Cron heartbeat: routed by `_contract == service`, not by topic.
    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return _log(block.chainid, reactive.exposed_service(), CRON_TOPIC, 0, 0, "");
    }

    /// @dev Convenience checkpointCallback payload for Callback assertions.
    function _checkpointPayload(bytes32 poolId, bytes32 positionKey) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("checkpointCallback(address,bytes32,bytes32)", address(0), poolId, positionKey);
    }

    function _outOfRangePayload(bytes32 poolId, bytes32 positionKey) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "checkpointAndEmitOutOfRange(address,bytes32,bytes32)", address(0), poolId, positionKey
        );
    }

    function _backInRangePayload(bytes32 poolId, bytes32 positionKey) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "checkpointAndEmitBackInRange(address,bytes32,bytes32)", address(0), poolId, positionKey
        );
    }

    /// @dev Counts dispatched `Callback` events among recorded logs (for cap / no-cap assertions).
    function _countCallbacks(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CALLBACK_TOPIC0) n++;
        }
    }
}
