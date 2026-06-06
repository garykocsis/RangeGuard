// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPausableReactive} from "./base/AbstractPausableReactive.sol";
import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";

/// @title RangeGuardReactive
/// @notice Autonomous, event-driven automation layer for the RangeGuard Uniswap v4 hook, deployed on
///         the Reactive Network's ReactVM. It performs two jobs the hook cannot do for itself:
///           1. Range transition detection — subscribes to the hook's `TickUpdated`, tracks each
///              active position's last-known range status, and fires a `checkpointAndEmitOutOfRange`
///              / `checkpointAndEmitBackInRange` callback when a position crosses a boundary.
///           2. Periodic heartbeat — subscribes to a Cron system event and fires `checkpointCallback`
///              for each active position whose `minCheckpointInterval` has elapsed, keeping lazy
///              coverage accrual current.
/// @dev    Inherits `AbstractPausableReactive` (reactive-lib): provides `owner`, `paused`,
///         `pause()`/`resume()`, the `Subscription` type, `service`, `vm`, `vmOnly`, `rnOnly`,
///         `REACTIVE_IGNORE`, and the `getPausableSubscriptions()` hook. Only the Cron subscription
///         is declared pausable, so the operator can halt the heartbeat (conserving rGas) while the
///         hook event subscriptions stay live. The contract never mutates hook accounting state — it
///         only emits `Callback` events routed through the official Callback Proxy.
contract RangeGuardReactive is AbstractPausableReactive {
    /*//////////////////////////////////////////////////////////////
                              TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-position tracking record kept on ReactVM.
    /// @dev    `lastKnownInRange` is a bool (MVP): the initial range status is always deterministic
    ///         from `PositionRegistered` (entryTick vs [tickLower, tickUpper)), so there is no unknown
    ///         state in normal operation.
    struct PositionInfo {
        bytes32 poolId; // PoolId (bytes32) — scopes hook callbacks
        int24 tickLower; // position lower tick bound
        int24 tickUpper; // position upper tick bound
        bool lastKnownInRange; // last range status, for transition detection
        bool active; // false after PositionClosed received
        uint256 lastCheckpointTime; // block.timestamp of last heartbeat Callback emit
    }

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reactive Network (Lasna) chain ID — documented for deployment reference.
    uint256 private constant REACTIVE_CHAIN_ID = 5318007;

    /// @notice Gas limit attached to every `Callback` (covers `_accrue` + event emission with
    ///         headroom; Reactive Network minimum is 100,000).
    uint64 private constant CALLBACK_GAS_LIMIT = 300_000;

    /// @notice Safety cap on heartbeat Callbacks per Cron cycle (prevents gas exhaustion). Range
    ///         transition detection is deliberately uncapped.
    uint256 private constant MAX_POSITIONS_PER_CYCLE = 20;

    /// @notice topic0 of the hook's `PositionRegistered` event (PoolId encoded as bytes32).
    /// @dev    `internal` so the test harness can assert these against the hook's real emitted
    ///         topics (a single-character signature mismatch would silently break subscriptions).
    uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(
        keccak256(
            "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
        )
    );

    /// @notice topic0 of the hook's `TickUpdated` event.
    uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256("TickUpdated(bytes32,int24,uint256)"));

    /// @notice topic0 of the hook's `PositionClosed` event.
    uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256("PositionClosed(bytes32,bytes32,address)"));

    /// @notice The RangeGuardHook on the host chain whose events drive this contract.
    address public immutable hookAddress;

    /// @notice EIP-155 chain ID of the host chain the hook is deployed on (e.g. 11155111 for Sepolia).
    /// @dev    Used both as the subscription SOURCE chain for the three hook events and as the
    ///         DESTINATION chain for every dispatched `Callback`. Parameterized so the same contract
    ///         can target any host chain without a code change.
    uint256 public immutable hookChainId;

    /// @notice The subscribed Cron system-event topic0 (Cron10 demo / Cron1000 mainnet).
    uint256 public immutable cronTopic;

    /// @notice Minimum seconds between heartbeat checkpoints per position; mirrors the hook's
    ///         per-pool `minCheckpointInterval` and gates the heartbeat to avoid wasted rGas on
    ///         `CheckpointTooSoon` reverts.
    uint256 public immutable minCheckpointInterval;

    /// @notice Per-position tracking, keyed by positionKey. Never deleted — set inactive on close.
    mapping(bytes32 => PositionInfo) public positions;

    /// @notice Active position keys, for heartbeat iteration. Maintained by push / swap-and-pop.
    bytes32[] public activeKeys;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on ReactVM when a new position is added to tracking (from `PositionRegistered`).
    event PositionTracked(
        bytes32 indexed poolId, bytes32 indexed positionKey, bool initiallyInRange, uint256 timestamp
    );

    /// @notice Emitted on ReactVM when a position is removed from tracking (from `PositionClosed`).
    event PositionUntracked(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 timestamp);

    /// @notice Emitted on ReactVM when a range transition is detected and a Callback is dispatched.
    /// @param inRange  false -> `checkpointAndEmitOutOfRange` fired; true -> `checkpointAndEmitBackInRange`.
    event RangeTransitionDetected(bytes32 indexed poolId, bytes32 indexed positionKey, bool inRange, uint256 timestamp);

    /// @notice Emitted on ReactVM when a heartbeat Callback is dispatched for a position.
    event HeartbeatCheckpointFired(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @param _hookAddress           RangeGuardHook on the host chain.
    /// @param _hookChainId           EIP-155 chain ID of that host chain (e.g. 11155111 Sepolia);
    ///                               used for both hook-event subscriptions and callback routing.
    /// @param _cronTopic             Cron system-event topic0 to subscribe to (Cron10/Cron1000).
    /// @param _minCheckpointInterval Heartbeat time gate (seconds); matches the hook's pool config.
    /// @dev    Subscriptions are wrapped in `if (!vm)` so local Foundry runs (where the system
    ///         contract is absent and `vm == true`) deploy without reverting. `payable` allows
    ///         initial rGas funding at deployment.
    constructor(address _hookAddress, uint256 _hookChainId, uint256 _cronTopic, uint256 _minCheckpointInterval)
        payable
    {
        hookAddress = _hookAddress;
        hookChainId = _hookChainId;
        cronTopic = _cronTopic;
        minCheckpointInterval = _minCheckpointInterval;

        if (!vm) {
            // Cron heartbeat (ReactVM system contract).
            SYSTEM.subscribe(
                block.chainid, address(SYSTEM), _cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            // Hook events (host chain).
            SYSTEM.subscribe(
                _hookChainId,
                _hookAddress,
                POSITION_REGISTERED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            SYSTEM.subscribe(
                _hookChainId, _hookAddress, TICK_UPDATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            SYSTEM.subscribe(
                _hookChainId, _hookAddress, POSITION_CLOSED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EXTERNAL / PUBLIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Single entry point for all subscribed event notifications; routes to the right handler.
    /// @dev    `vmOnly` — only the ReactVM runtime may call. Routing: a log from the system contract
    ///         is the Cron heartbeat; otherwise dispatch on topic0. Unrecognized logs are ignored.
    /// @param  log  The intercepted log record delivered by the Reactive Network.
    function react(LogRecord calldata log) external override vmOnly {
        if (log.contractAddress == address(SYSTEM)) {
            _handleHeartbeat();
        } else if (log.topic0 == POSITION_REGISTERED_TOPIC_0) {
            _handlePositionRegistered(log);
        } else if (log.topic0 == TICK_UPDATED_TOPIC_0) {
            _handleTickUpdated(log);
        } else if (log.topic0 == POSITION_CLOSED_TOPIC_0) {
            _handlePositionClosed(log);
        }
    }

    /// @notice Number of active position keys currently tracked (for off-chain monitoring / tests).
    function activeKeysLength() external view returns (uint256) {
        return activeKeys.length;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns ONLY the Cron heartbeat subscription as pausable.
    /// @dev    Pausing therefore halts the heartbeat while keeping the hook event subscriptions
    ///         (`PositionRegistered`, `TickUpdated`, `PositionClosed`) always active.
    function getPausableSubscriptions() internal view override returns (Subscription[] memory) {
        Subscription[] memory subs = new Subscription[](1);
        subs[0] = Subscription({
            chain_id: block.chainid,
            _contract: address(SYSTEM),
            topic_0: cronTopic,
            topic_1: REACTIVE_IGNORE,
            topic_2: REACTIVE_IGNORE,
            topic_3: REACTIVE_IGNORE
        });
        return subs;
    }

    /// @notice Adds a newly registered position to tracking, initializing its range status.
    /// @dev    Indexed fields come from topics; the rest from `log.data`. `lastKnownInRange` mirrors
    ///         the hook's `_lastRangeEventInRange` init so the first transition fires correctly.
    function _handlePositionRegistered(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic1);
        bytes32 positionKey = bytes32(log.topic2);

        (int24 tickLower, int24 tickUpper,,,, int24 entryTick,,,) =
            abi.decode(log.data, (int24, int24, uint128, uint128, uint256, int24, uint32, uint256, uint256));

        // Dedup: skip if already tracking this position.
        if (positions[positionKey].active) return;

        bool inRange = (entryTick >= tickLower && entryTick < tickUpper);
        positions[positionKey] = PositionInfo({
            poolId: poolId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            lastKnownInRange: inRange,
            active: true,
            lastCheckpointTime: block.timestamp
        });
        activeKeys.push(positionKey);

        emit PositionTracked(poolId, positionKey, inRange, block.timestamp);
    }

    /// @notice On a post-swap tick update, detects range transitions for every active position in the
    ///         affected pool and dispatches the matching atomic checkpoint Callback.
    /// @dev    Uncapped by design — every active position in the pool must be evaluated so a
    ///         transition is never silently dropped. `lastKnownInRange` is updated BEFORE the Callback
    ///         lands; if the hook's guard reverts (duplicate), this state is already correct and no
    ///         retry occurs.
    function _handleTickUpdated(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic1);
        (int24 newTick,) = abi.decode(log.data, (int24, uint256));

        uint256 len = activeKeys.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 positionKey = activeKeys[i];
            PositionInfo storage pos = positions[positionKey];

            if (!pos.active) continue;
            if (pos.poolId != poolId) continue; // only positions in the affected pool

            bool isInRange = (newTick >= pos.tickLower && newTick < pos.tickUpper);

            if (pos.lastKnownInRange && !isInRange) {
                // in range -> out of range
                bytes memory payload = abi.encodeWithSignature(
                    "checkpointAndEmitOutOfRange(address,bytes32,bytes32)", address(0), poolId, positionKey
                );
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: hookChainId,
                        recipient: hookAddress,
                        gasLimit: CALLBACK_GAS_LIMIT,
                        payload: payload
                    })
                );
                pos.lastKnownInRange = false;
                emit RangeTransitionDetected(poolId, positionKey, false, block.timestamp);
            } else if (!pos.lastKnownInRange && isInRange) {
                // out of range -> back in range
                bytes memory payload = abi.encodeWithSignature(
                    "checkpointAndEmitBackInRange(address,bytes32,bytes32)", address(0), poolId, positionKey
                );
                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: hookChainId,
                        recipient: hookAddress,
                        gasLimit: CALLBACK_GAS_LIMIT,
                        payload: payload
                    })
                );
                pos.lastKnownInRange = true;
                emit RangeTransitionDetected(poolId, positionKey, true, block.timestamp);
            }
            // No transition: no Callback, lastKnownInRange unchanged.
        }
    }

    /// @notice Stops tracking a settled position (received from the hook's `PositionClosed`).
    /// @dev    Marks inactive and swap-and-pops from `activeKeys`. The record is not deleted — the
    ///         heartbeat and tick handlers gate on `active`.
    function _handlePositionClosed(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic1);
        bytes32 positionKey = bytes32(log.topic2);

        if (!positions[positionKey].active) return; // dedup / unknown guard

        positions[positionKey].active = false;
        _removeActiveKey(positionKey);

        emit PositionUntracked(poolId, positionKey, block.timestamp);
    }

    /// @notice Periodic heartbeat: dispatches a `checkpointCallback` Callback for each active position
    ///         whose `minCheckpointInterval` has elapsed, capped at `MAX_POSITIONS_PER_CYCLE`.
    /// @dev    Pausing the Cron subscription halts delivery, so this only runs while active.
    function _handleHeartbeat() internal {
        uint256 len = activeKeys.length;
        uint256 count = 0;

        for (uint256 i = 0; i < len && count < MAX_POSITIONS_PER_CYCLE; i++) {
            bytes32 positionKey = activeKeys[i];
            PositionInfo storage pos = positions[positionKey];

            if (!pos.active) continue;
            if (block.timestamp - pos.lastCheckpointTime < minCheckpointInterval) continue;

            bytes memory payload = abi.encodeWithSignature(
                "checkpointCallback(address,bytes32,bytes32)", address(0), pos.poolId, positionKey
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: hookChainId,
                    recipient: hookAddress,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );

            pos.lastCheckpointTime = block.timestamp;
            count++;

            emit HeartbeatCheckpointFired(pos.poolId, positionKey, block.timestamp);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  PRIVATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Removes a key from `activeKeys` via swap-and-pop (O(1) write; order not meaningful).
    function _removeActiveKey(bytes32 positionKey) private {
        uint256 len = activeKeys.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeKeys[i] == positionKey) {
                activeKeys[i] = activeKeys[len - 1];
                activeKeys.pop();
                return;
            }
        }
    }
}
