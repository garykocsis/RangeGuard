# RangeGuard Reactive Contract Specification

## 1. Executive Summary

The RangeGuard Reactive contract is an autonomous, event-driven automation
layer deployed on the Reactive Network's ReactVM. It completes the RangeGuard
protocol by providing two services that the Uniswap v4 hook cannot provide
for itself:

**Job 1 — Range Transition Detection:**
The hook emits a lightweight `TickUpdated` event on every swap but cannot
determine which LP positions have crossed a tick boundary — doing so would
require iterating all positions, an O(N) operation forbidden in the swap path.
The Reactive contract subscribes to `TickUpdated`, tracks the last known range
status of every active position, and calls `checkpointAndEmitOutOfRange()` or
`checkpointAndEmitBackInRange()` on the hook when a transition is detected.

**Job 2 — Periodic Heartbeat:**
Coverage accrual is lazy — it only advances on explicit touches. Without
regular checkpoints, LP coverage reports would show large gaps. The Reactive
contract subscribes to the Reactive Network's built-in `Cron10` system event
(~1 minute) and calls `checkpointCallback()` on the hook for each active
tracked position that has exceeded `minCheckpointInterval`.

**Deployment model:**
The Reactive contract is deployed on ReactVM after the hook is deployed on
the host chain (Sepolia/Unichain). It is initialized with the hook address
and begins subscriptions immediately. No registration step is required on
the hook — authorization is handled entirely by the Reactive Network's
Callback Proxy (`onlyServiceProvider` on the hook side via `AbstractCallback`).

**Inheritance:** `RangeGuardReactive` inherits from `AbstractPausableReactive`,
which provides built-in owner-controlled pause/resume for the Cron10 heartbeat
subscription — essential for managing rGas costs between demo sessions. NOTE: the Omni
`reactive-lib-omni` **removed** the upstream `AbstractPausableReactive` (and the
`vm`/`detectVm` detection), so this is now a **local port** at
`src/base/AbstractPausableReactive.sol` — behaviourally identical, but built on the new
`AbstractReactive` and targeting the new system contract `SYSTEM` (`0x8888…8888`).

**MVP scope:**
Single ETH/USDC pool demo on Sepolia testnet. Naturally supports all pools
managed by the same hook deployment. Up to 20 active positions.

---

## 2. Reactive Network Conceptual Model

### What is the Reactive Network?

The Reactive Network is a separate EVM-compatible blockchain (ReactVM / Lasna)
designed for autonomous, event-driven contract execution. Reactive contracts
deployed on ReactVM can subscribe to events emitted on other chains (e.g.
Sepolia, Unichain) and trigger callbacks back to those chains — without any
off-chain keeper infrastructure.

### Subscription Model

A reactive contract declares its event subscriptions in its constructor by
calling `SYSTEM.subscribe()`:

```solidity
SYSTEM.subscribe(
    chainId,          // source chain to monitor
    contractAddress,  // source contract address
    topic0,           // keccak256 of event signature
    REACTIVE_IGNORE,  // topic1 filter (REACTIVE_IGNORE = no filter)
    REACTIVE_IGNORE,  // topic2 filter
    REACTIVE_IGNORE   // topic3 filter
);
```

The Reactive Network infrastructure monitors the source chain and delivers
matching log records to the reactive contract's `react()` function.

### react() — The Single Entry Point

All incoming events are routed through one function:

```solidity
function react(LogRecord calldata log) external vmOnly;
```

`LogRecord` (reactive-lib-omni, camelCase fields) contains: `chainId`, `contractAddress`,
`topic0`–`topic3` (all `uint256`), `data`, `blockNumber`, `opCode`, `blockHash`, `txHash`,
`logIndex` — note there is no `blockTimestamp` field (handlers use the `block.timestamp`
global). The `vmOnly` modifier (from the local `AbstractPausableReactive` port) ensures
`react()` can only be called by the ReactVM runtime.

### Callback Mechanism

When the reactive contract wants to call a function on the host chain,
it requests a callback through the Reactive system contract (Omni fork):

```solidity
SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
    chainId: targetChainId, recipient: targetContract, gasLimit: gasLimit, payload: payload
}));
```

(The legacy `emit Callback(...)` event still exists in `IReactive` but is deprecated and
unused.) The Reactive Network routes the call through the official **Callback Proxy** on the
destination chain. From the hook's perspective, `msg.sender` is always that Callback Proxy —
never the reactive contract directly. The proxy address is **per network**: for Reactive
**Lasna** → Ethereum **Sepolia** it is `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` (the Omni
fork changed it from the legacy `0x…fffFfF`).

### RVM ID Placeholder Rule

The Reactive Network overwrites the first 160 bits of every callback
payload with the calling contract's ReactVM ID. Every hook function
callable from a reactive contract must accept a leading `address` parameter
(ignored at runtime). Callback payloads must place `address(0)` first:

```solidity
bytes memory payload = abi.encodeWithSignature(
    "checkpointCallback(address,bytes32,bytes32)",
    address(0),   // ← RVM ID placeholder — overwritten by network
    poolId,
    positionKey
);
```

### Cron System Events

The Reactive system contract (`SYSTEM = 0x8888888888888888888888888888888888888888` on
Lasna) is the source of built-in Cron events on ReactVM, emitted at fixed block intervals
(the `react()` heartbeat route keys off `log.contractAddress == address(SYSTEM)`):

| Event    | Frequency         | Approx Duration |
| -------- | ----------------- | --------------- |
| Cron1    | Every block       | ~1–7 seconds    |
| Cron10   | Every 10 blocks   | ~1 minute       |
| Cron100  | Every 100 blocks  | ~12 minutes     |
| Cron1000 | Every 1000 blocks | ~2 hours        |

RangeGuard uses `Cron10` for the demo (~1 minute) and `Cron1000` for
mainnet (~2 hours), paired with matching `minCheckpointInterval` values.

### Testing: the `vm` Flag

When running under Foundry (or any non-ReactVM environment), the `vm`
flag is `true`. Subscriptions are wrapped in `if (!vm)` to prevent
revert during local testing:

```solidity
if (!vm) {
    SYSTEM.subscribe(...);
}
```

### Gas and rGas

Each dispatched callback (`SYSTEM.requestCallbackV_1_0`) incurs a minimum of 100,000 rGas on
the Reactive Network (RangeGuard uses 300,000). rGas is charged per CALLBACK, not per
`react()` execution — a no-op heartbeat with zero tracked positions spends nothing (verified
on-chain). The reactive contract must maintain a positive rGas (lREACT) balance or callbacks
stop firing.

---

## 3. Background and Design

### Why the Hook Cannot Self-Automate

RangeGuardHook is a stateless callback processor — it reacts to events
triggered by PoolManager (swaps, liquidity changes) but cannot initiate
actions on its own. Three automation needs cannot be satisfied inside
the hook:

**1. Range transition detection.**
After every swap, the pool tick may have crossed one or more LP position
boundaries. To detect this, the hook would need to iterate all registered
positions and compare their tick ranges against the new tick — an O(N)
operation in the swap path. This is architecturally forbidden: gas cost
would scale with the number of LPs and could make swaps prohibitively
expensive or hit block gas limits. `afterSwap` emits a lightweight
`TickUpdated` event instead, delegating range detection to an off-chain
observer.

**2. Periodic accrual heartbeat.**
RangeGuard uses lazy accrual — coverage is only computed on explicit
touches (add, checkpoint, remove). Without regular checkpoints, LP
coverage reports would show large gaps and final accrual at withdrawal
would carry months of un-emitted `AccrualUpdated` events. A periodic
heartbeat is required to keep the coverage report live.

**3. Range transition events.**
`PositionOutOfRange` and `PositionBackInRange` are emitted by the hook
when called by the Reactive contract. The hook cannot emit these itself
because it does not know which positions are affected by a tick move
without iterating all of them.

### Why the Reactive Network

The Reactive Network solves all three problems without any off-chain
infrastructure. A reactive contract deployed on ReactVM:

- Subscribes to `TickUpdated` from the hook
- Tracks per-position range status in its own state
- Detects transitions and calls back to the hook atomically
- Runs a periodic heartbeat via the built-in Cron system

No keeper bots, no centralized relayers, no cron jobs — fully on-chain
automation.

### Key Design Decisions

**AbstractPausableReactive inheritance (local port under Omni).**
`RangeGuardReactive` inherits from `AbstractPausableReactive` (not
`AbstractReactive`). Because `reactive-lib-omni` removed the upstream
`AbstractPausableReactive`, this is a **local port** at `src/base/AbstractPausableReactive.sol`
(built on the new `AbstractReactive`, system contract `SYSTEM = 0x8888…8888`). It provides the
same `owner`, `paused` state, `pause()`/`resume()`, the `Subscription` type, and the restored
`vm`/`vmOnly`/`rnOnly` detection. Combined
with `getPausableSubscriptions()` returning only the Cron10 subscription,
this allows the operator to halt the heartbeat between demo sessions to
conserve rGas — while keeping hook event subscriptions
(`PositionRegistered`, `TickUpdated`, `PositionClosed`) always active.

**AbstractCallback over per-pool reactiveContract mapping.**
The original design stored `reactiveContract[poolId]` on the hook and
used an `onlyReactive(poolId)` modifier. Research revealed this is
architecturally incorrect — the hook's `msg.sender` is always the
Callback Proxy, not the reactive contract. The hook cannot verify which
specific reactive contract triggered a callback. `AbstractCallback`
(from `reactive-lib-omni`) provides the correct `onlyServiceProvider`
modifier (which replaced the pre-Omni `authorizedSenderOnly`/`senders` ACL —
semantically equivalent, both gating on "called by the Callback Proxy"), verifying
only that the call arrived through the official Callback Proxy infrastructure.
`setReactiveContract()` was removed entirely, simplifying the deployment sequence.

**Combined checkpointAndEmit\* functions.**
The original design called `checkpoint()` then `emitOutOfRange()` as
two separate calls. This is not atomic — if `checkpoint()` succeeds but
`emitOutOfRange()` fails, accrual advances without the event. Combined
functions (`checkpointAndEmitOutOfRange`, `checkpointAndEmitBackInRange`)
make accrual and event emission atomic in a single call.

**Hook-side \_lastRangeEventInRange guard.**
The hook tracks the last emitted range event per position to prevent
duplicate `PositionOutOfRange` or `PositionBackInRange` events, even
if the Reactive contract's state is stale or restarted. This provides
a second layer of protection independent of the Reactive contract's
own `lastKnownRangeStatus` tracking.

**PositionClosed over four settlement event subscriptions.**
Rather than subscribing to all four settlement events (`ClaimSettled`,
`NoClaim`, `IneligibleClaim`, `PartialPayout`), a single `PositionClosed`
event is emitted on every settlement path. This decouples the Reactive
contract from settlement logic — it only needs to know THAT a position
closed, not WHY.

**Individual Callbacks with safety cap.**
The heartbeat emits one `Callback` per active position per Cron10 cycle,
capped at `MAX_POSITIONS_PER_CYCLE = 20`. Upgradeable to Pattern A
(batch contract) without any hook changes since `checkpointCallback()`
is `onlyServiceProvider` and callable only via the Callback Proxy.

---

## 4. Scope and Non-Scope

### In Scope (MVP)

**RangeGuardReactive.sol — ReactVM contract:**

- Inherits `AbstractPausableReactive` (local port at `src/base/`; `reactive-lib-omni`
  removed the upstream one)
- Subscribes to three hook events on Sepolia: `PositionRegistered`,
  `TickUpdated`, `PositionClosed`
- Subscribes to `Cron10` on ReactVM for periodic heartbeat
- Tracks per-position state: tick range, last known range status,
  last checkpoint time, active flag
- Detects range transitions from `TickUpdated` and calls
  `checkpointAndEmitOutOfRange` / `checkpointAndEmitBackInRange`
- Drives periodic `checkpointCallback` calls for active positions
- Removes positions from tracking on `PositionClosed`
- Operator-controlled heartbeat pause/resume via `AbstractPausableReactive`

**Hook changes required this session (retrofit to RangeGuardHook.sol):**

- `AbstractCallback` inheritance + `_callbackSender` constructor arg
- `checkpointCallback(address, PoolId, bytes32)` — new onlyServiceProvider function
- `checkpointAndEmitOutOfRange(address, PoolId, bytes32)` — new onlyServiceProvider
- `checkpointAndEmitBackInRange(address, PoolId, bytes32)` — new onlyServiceProvider
- `_lastRangeEventInRange` mapping + initialization in `afterAddLiquidity`
- `PositionClosed` event + emission in `afterRemoveLiquidity` on all paths
- Remove `reactiveContract[poolId]` and `_reactiveSet[poolId]` mappings

**Target environment:** Sepolia testnet. Naturally supports all pools
managed by the hook deployment. MVP demo uses a single ETH/USDC pool
with up to 20 active positions across all tracked pools.

---

### Out of Scope (MVP)

**Multiple hook deployments.**
The Reactive contract is initialized with a single `hookAddress`. If the
protocol deploys multiple hook instances, a separate Reactive contract
instance is needed per hook deployment.

**Pattern A batch contract.**
A `RangeGuardBatchCheckpoint` contract on Sepolia (receives one Callback
with an array of positions, iterates locally) is the production scaling
path for >20 positions. Not needed for demo scale.

**Paginated heartbeat (Pattern B).**
Tracking `nextProcessIndex` for chunked iteration across Cron cycles.
Unnecessary for demo scale.

**Direct on-chain state reads from ReactVM.**
The Reactive contract cannot read Sepolia state (e.g. current pool tick)
directly from ReactVM. All state is derived from subscribed events.

**rGas auto-refill.**
Monitoring and topping up the Reactive contract's rGas balance is a
manual operational concern for the demo.

**Reactive contract upgrades.**
No upgrade pattern in MVP — redeploy if needed.

**Mainnet deployment.**
Verify Callback Proxy address on mainnet before production deploy.

**Frontend dashboard and demo script.**
Separate phases — not part of this session.

## 5. Agreed MVP Architecture Decisions

All decisions below are locked. They must not be revisited or modified
during implementation without a spec amendment.

---

**A. Contract Inheritance**
`RangeGuardReactive` inherits from `AbstractPausableReactive` — a **local port** at
`src/base/AbstractPausableReactive.sol` (the Omni `reactive-lib-omni` removed the upstream
one). This provides `owner`, `paused` state, `pause()`/`resume()` functions, and
`getPausableSubscriptions()`. The Cron10 subscription is declared pausable
via `getPausableSubscriptions()`, allowing the operator to halt the heartbeat
between demo sessions while keeping hook event subscriptions always active.

**B. Hook Authorization via AbstractCallback**
`RangeGuardHook` inherits from `AbstractCallback` (reactive-lib-omni).
`onlyServiceProvider` (provided by `AbstractPayer` under `AbstractCallback`) replaces the
pre-Omni `authorizedSenderOnly` ACL and any custom `onlyReactive` modifier. The hook verifies
only that `msg.sender` equals the Callback Proxy — it cannot and does not verify which specific
Reactive contract triggered the call.

**C. Callback Proxy Address (per network — Omni fork changed this)**
For Reactive **Lasna** → Ethereum **Sepolia**:
`0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` (no longer the legacy `0x…fffFfF`; source:
dev.reactive.network/origins-and-destinations). Passed as `_callbackSender` to the hook
constructor and stored by `AbstractCallback` as both the `_SERVICE_PROVIDER` (payment vendor)
and the authorized callback sender. Distinct from the Lasna system contract
(`SYSTEM = 0x8888…8888`) and the Sepolia lREACT faucet (`0x9b9BB25f…Cf434`).

**D. RVM ID Placeholder Rule**
Every hook function callable from a Reactive contract must accept a leading
`address` parameter (ignored at runtime). Every `abi.encodeWithSignature`
payload in the Reactive contract must place `address(0)` as the first
argument. The network overwrites it with the ReactVM contract ID before
delivery.

**E. Atomic Range Transition Functions**
`checkpointAndEmitOutOfRange(address, PoolId, bytes32)` and
`checkpointAndEmitBackInRange(address, PoolId, bytes32)` replace the
former two-step pattern. Accrual and event emission are atomic in a
single call. Neither function enforces `minCheckpointInterval`.

**F. Hook-Side Range Event Guard**
`_lastRangeEventInRange[poolId][positionKey]` (bool mapping on the hook)
enforces correct alternation of range events independently of the Reactive
contract's state. Initialized in `afterAddLiquidity` based on entry tick
vs tick range. Reverts `PositionAlreadyOutOfRange` / `PositionAlreadyInRange`
on duplicate consecutive calls.

**G. PositionClosed Event**
A single `PositionClosed(PoolId, bytes32 positionKey, address owner)` event
is emitted by the hook on every settlement path in `afterRemoveLiquidity`.
The Reactive contract subscribes to `PositionClosed` to stop tracking a
position — it does not subscribe to any individual settlement events.

**H. Three Hook Subscriptions + Cron**
The Reactive contract subscribes to exactly three events from the hook:
`PositionRegistered`, `TickUpdated`, `PositionClosed`. Plus `Cron10`
(demo) or `Cron1000` (mainnet) from the ReactVM system contract.

**I. Cron Selection and minCheckpointInterval**
Both are passed as constructor arguments, matched to the deployment target:

| Parameter                | Demo (Sepolia)        | Mainnet                |
| ------------------------ | --------------------- | ---------------------- |
| `_minCheckpointInterval` | 120 seconds (2 min)   | 86400 seconds (24 hr)  |
| `_cronTopic`             | Cron10 topic (~1 min) | Cron1000 topic (~2 hr) |

**J. checkpointCallback() as RVM Entry Point**
A dedicated `checkpointCallback(address, PoolId, bytes32)` function on the
hook serves as the Reactive heartbeat entry point. It is `onlyServiceProvider`
— only callable via the Callback Proxy. The existing `checkpoint(PoolId, bytes32)`
(no sender param, no access restriction) is preserved for permissionless
direct callers (keepers, LPs, manual).

**K. Individual Callbacks with Safety Cap**
The heartbeat loop emits one `Callback` per active position per Cron cycle.
`MAX_POSITIONS_PER_CYCLE = 20` prevents gas exhaustion. Production upgrade
to Pattern A (single batch Callback) requires no hook changes.

**L. Per-Position lastCheckpointTime**
`PositionInfo` stores `lastCheckpointTime` (uint256) to allow the Reactive
contract to skip positions checkpointed recently, avoiding wasted rGas on
`CheckpointTooSoon` reverts.

**M. Callback Gas Limit**
`CALLBACK_GAS_LIMIT = 300_000` per callback. Covers `_accrue()` + event
emission with headroom. Reactive Network minimum is 100,000.

**N. Multi-Pool Support**
The Reactive contract is initialized with a single `hookAddress`. It
naturally supports all pools managed by that hook — `PositionInfo` stores
`poolId` and all callbacks include the correct pool scope.

**O. if (!vm) Subscription Guard**
All `SYSTEM.subscribe()` calls are wrapped in `if (!vm)` to allow local
Foundry testing without reverting on subscription setup.

**P. topic0 Constants**
Event topic0 values are precomputed `keccak256` hashes of event signatures
stored as `uint256` constants. Must match the hook's emitted events exactly.

---

## 6. Hook Events Subscribed To

The Reactive contract subscribes to three events from the hook on Sepolia
and one system event on ReactVM. All subscriptions are registered in the
constructor inside `if (!vm)`.

---

### 6.1 PositionRegistered (Sepolia — hook)

**Purpose:** Learn about a new LP position so it can be added to tracking.

**Event signature (hook — verified against source):**

```solidity
event PositionRegistered(
    PoolId  indexed poolId,
    bytes32 indexed positionKey,
    address indexed owner,
    int24   tickLower,
    int24   tickUpper,
    uint128 entryAmt0,
    uint128 entryAmt1,
    uint256 entryNotionalStable,
    int24   entryTick,
    uint32  depositTime,
    uint256 coverageApr,
    uint256 secondsPerYear
);
```

**topic0 constant:**

```solidity
uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(keccak256(
    "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
));
```

**LogRecord field mapping:**
| Field | Source |
|-------|--------|
| poolId | `bytes32(log.topic1)` |
| positionKey | `bytes32(log.topic2)` |
| owner | `address(uint160(uint256(log.topic3)))` |
| tickLower, tickUpper, entryAmt0, entryAmt1, entryNotionalStable, entryTick, depositTime, coverageApr, secondsPerYear | `abi.decode(log.data, (int24, int24, uint128, uint128, uint256, int24, uint32, uint256, uint256))` |

**Fields used by Reactive contract:**

- `poolId` + `positionKey` — tracking keys
- `tickLower` + `tickUpper` — for range evaluation on TickUpdated
- `entryTick` — to initialize `lastKnownInRange`

**Fields decoded but not used:** `owner`, `entryAmt0`, `entryAmt1`,
`entryNotionalStable`, `depositTime`, `coverageApr`, `secondsPerYear`.

**Subscription:**

```solidity
SYSTEM.subscribe(
    hookChainId, hookAddress,
    POSITION_REGISTERED_TOPIC_0,
    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
);
```

---

### 6.2 TickUpdated (Sepolia — hook)

**Purpose:** Detect tick movements that may have crossed a position's
tick boundary, triggering range transition detection.

**Event signature (hook — verified):**

```solidity
event TickUpdated(
    PoolId  indexed poolId,
    int24   newTick,
    uint256 timestamp
);
```

**topic0 constant:**

```solidity
uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256(
    "TickUpdated(bytes32,int24,uint256)"
));
```

**LogRecord field mapping:**
| Field | Source |
|-------|--------|
| poolId | `bytes32(log.topic1)` |
| newTick, timestamp | `abi.decode(log.data, (int24, uint256))` |

**Subscription:**

```solidity
SYSTEM.subscribe(
    hookChainId, hookAddress,
    TICK_UPDATED_TOPIC_0,
    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
);
```

---

### 6.3 PositionClosed (Sepolia — hook)

**Purpose:** Remove a settled position from tracking and stop heartbeat
calls for it.

**Event signature (hook — verified):**

```solidity
event PositionClosed(
    PoolId  indexed poolId,
    bytes32 indexed positionKey,
    address         owner
);
```

**topic0 constant:**

```solidity
uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256(
    "PositionClosed(bytes32,bytes32,address)"
));
```

**LogRecord field mapping:**
| Field | Source |
|-------|--------|
| poolId | `bytes32(log.topic1)` |
| positionKey | `bytes32(log.topic2)` |
| owner | `abi.decode(log.data, (address))` |

**Subscription:**

```solidity
SYSTEM.subscribe(
    hookChainId, hookAddress,
    POSITION_CLOSED_TOPIC_0,
    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
);
```

---

### 6.4 Cron10 / Cron1000 (ReactVM — system contract)

**Purpose:** Periodic heartbeat trigger for driving `checkpointCallback()`
on all active tracked positions.

**Source:** Emitted by the system contract at `address(SYSTEM)` on ReactVM.

- Demo: Cron10 (~1 minute)
- Mainnet: Cron1000 (~2 hours)

**topic0:** Passed as `_cronTopic` constructor argument.

**Subscription:**

```solidity
SYSTEM.subscribe(
    block.chainid,       // ReactVM chain
    address(SYSTEM),    // system contract
    _cronTopic,          // Cron10 (demo) or Cron1000 (mainnet)
    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
);
```

---

### Critical Note on topic0 Accuracy

topic0 constants are `keccak256` hashes of the exact event signature string.
Verify against the deployed hook ABI before computing topic0 values. A single
character mismatch will cause the subscription to never fire.

---

## 7. Hook Functions Called by Reactive Contract

The Reactive contract triggers three functions on the hook via
`SYSTEM.requestCallbackV_1_0(...)` (Omni fork; the deprecated `emit Callback(...)` is no
longer used). All three use `CALLBACK_GAS_LIMIT = 300_000`.
All three require `address(0)` as the first payload argument (RVM ID
placeholder — see §5D). All three are `onlyServiceProvider`.

Note: `PoolId` is a user-defined value type wrapping `bytes32`. In ABI
encoding and signature strings it must be expressed as `bytes32`.

---

### 7.1 checkpointCallback()

**Purpose:** Periodic heartbeat accrual. Called by the Reactive contract
on Cron cycle for each active position that has exceeded
`minCheckpointInterval`.

**Hook function signature:**

```solidity
function checkpointCallback(
    address /* sender */,   // RVM ID placeholder — ignored
    PoolId   poolId,
    bytes32  positionKey
) external onlyServiceProvider
```

**Access control:** `onlyServiceProvider` — only Callback Proxy.
**Rate-limited:** Yes — reverts `CheckpointTooSoon` if
`block.timestamp - lastAccrualTime < minCheckpointInterval`.

**Callback payload encoding:**

```solidity
bytes memory payload = abi.encodeWithSignature(
    "checkpointCallback(address,bytes32,bytes32)",
    address(0),    // RVM ID placeholder
    pos.poolId,
    positionKey
);
SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));
```

**Hook behavior on success:**

- Guards: `_poolInitialized` → `PositionNotActive` → `CheckpointTooSoon`
- Reads current tick via `_getCurrentTick(poolId)`
- Calls `_accrue(poolId, positionKey, currentTick)`
- Emits `AccrualUpdated` + `Checkpointed`

---

### 7.2 checkpointAndEmitOutOfRange()

**Purpose:** Atomic range transition — accrual + `PositionOutOfRange`
event. Called when a position crosses below `tickLower`.

**Hook function signature:**

```solidity
function checkpointAndEmitOutOfRange(
    address /* sender */,   // RVM ID placeholder — ignored
    PoolId   poolId,
    bytes32  positionKey
) external onlyServiceProvider
```

**Access control:** `onlyServiceProvider`. **Rate-limited:** No.

**Callback payload encoding:**

```solidity
bytes memory payload = abi.encodeWithSignature(
    "checkpointAndEmitOutOfRange(address,bytes32,bytes32)",
    address(0), poolId, positionKey
);
SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));
```

**Hook behavior on success:**

- Guards: `PositionNotActive` → `PositionAlreadyOutOfRange`
- Calls `_accrue`, sets `_lastRangeEventInRange = false`, emits `PositionOutOfRange`

**On revert `PositionAlreadyOutOfRange`:**
Reactive contract updates `lastKnownInRange = false` and does not retry.

---

### 7.3 checkpointAndEmitBackInRange()

**Purpose:** Atomic range transition — accrual + `PositionBackInRange`
event. Called when a position crosses back above `tickLower`.

**Hook function signature:**

```solidity
function checkpointAndEmitBackInRange(
    address /* sender */,   // RVM ID placeholder — ignored
    PoolId   poolId,
    bytes32  positionKey
) external onlyServiceProvider
```

**Access control:** `onlyServiceProvider`. **Rate-limited:** No.

**Callback payload encoding:**

```solidity
bytes memory payload = abi.encodeWithSignature(
    "checkpointAndEmitBackInRange(address,bytes32,bytes32)",
    address(0), poolId, positionKey
);
SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));
```

**Hook behavior on success:**

- Guards: `PositionNotActive` → `PositionAlreadyInRange`
- Calls `_accrue`, sets `_lastRangeEventInRange = true`, emits `PositionBackInRange`

**On revert `PositionAlreadyInRange`:**
Reactive contract updates `lastKnownInRange = true` and does not retry.

---

### 7.4 Constants

```solidity
uint64  private constant CALLBACK_GAS_LIMIT       = 300_000;
uint256 private constant MAX_POSITIONS_PER_CYCLE  = 20;
```

## 8. Reactive Contract State Model

### 8.1 Immutable State

```solidity
address public immutable hookAddress;         // RangeGuardHook on the host chain
uint256 public immutable hookChainId;         // host chain id (e.g. 11155111 Sepolia)
uint256 public immutable cronTopic;           // Cron10 (demo) or Cron1000 (mainnet)
uint256 public immutable minCheckpointInterval; // 120s (demo) | 86400s (mainnet)
```

`owner` and `paused` are provided by `AbstractPausableReactive`.

---

### 8.2 PositionInfo Struct

```solidity
struct PositionInfo {
    bytes32 poolId;             // PoolId (bytes32) — scopes hook calls
    int24   tickLower;          // position lower tick bound
    int24   tickUpper;          // position upper tick bound
    bool    lastKnownInRange;   // last range status for transition detection
    bool    active;             // false after PositionClosed received
    uint256 lastCheckpointTime; // block.timestamp of last checkpointCallback emit
}
```

**lastKnownInRange** initialized from `entryTick`:

```solidity
info.lastKnownInRange = (entryTick >= tickLower && entryTick < tickUpper);
```

**lastCheckpointTime** initialized to `block.timestamp` at registration.

---

### 8.3 Position Registry

```solidity
mapping(bytes32 => PositionInfo) public positions;  // positionKey → info
bytes32[] public activeKeys;                         // for heartbeat iteration
```

**Adding:** push to `activeKeys` on `PositionRegistered`.
**Removing:** swap-and-pop on `PositionClosed`.

```solidity
function _removeActiveKey(bytes32 positionKey) internal {
    uint256 len = activeKeys.length;
    for (uint256 i = 0; i < len; i++) {
        if (activeKeys[i] == positionKey) {
            activeKeys[i] = activeKeys[len - 1];
            activeKeys.pop();
            return;
        }
    }
}
```

---

### 8.4 Chain and System Constants

```solidity
uint256 private constant REACTIVE_CHAIN_ID       = 5318007;
uint64  private constant CALLBACK_GAS_LIMIT      = 300_000;
uint256 private constant MAX_POSITIONS_PER_CYCLE = 20;
```

---

### 8.5 topic0 Constants

Declared `internal` (not `private`) so the test harness can assert them against the hook's
real emitted event topics — a single-character signature mismatch would silently break a
subscription, so this wiring is verified directly.

```solidity
uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(keccak256(
    "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
));
uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256(
    "TickUpdated(bytes32,int24,uint256)"
));
uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256(
    "PositionClosed(bytes32,bytes32,address)"
));
```

---

### 8.6 State Ownership Rules

| State                               | Modified by                                                  |
| ----------------------------------- | ------------------------------------------------------------ |
| `positions[key]`                    | `PositionRegistered` (add), `PositionClosed` (deactivate)    |
| `activeKeys`                        | `PositionRegistered` (push), `PositionClosed` (swap-and-pop) |
| `positions[key].lastKnownInRange`   | `TickUpdated` handler (on transition)                        |
| `positions[key].lastCheckpointTime` | Heartbeat handler (after Callback emit)                      |
| `positions[key].active`             | `PositionClosed` handler (set false)                         |

**Reactive contracts must never mutate hook accounting state.**

---

## 9. Dependencies and Imports

### 9.1 reactive-lib-omni dependency (vendored)

The project uses the **Omni fork** library (`reactive-lib-omni` v0.1.0 `@3ade0dc`), not the legacy
`reactive-lib`. Its `src/` is **vendored** — committed directly into `lib/reactive-lib-omni/`
(NOT a git submodule, matching how `forge-std`/`v4-hooks-public` are tracked here) — so a fresh
`git clone` builds with no submodule init. See `lib/reactive-lib-omni/VENDORED.md`.

`remappings.txt`:

```
reactive-lib/=lib/reactive-lib-omni/
```

> **Pragma:** upstream sources are `pragma ^0.8.29`, but the project (and v4-core's `PoolManager`)
> compile on `0.8.26`. Since the lib uses no 0.8.27+ features, the 8 vendored files are relaxed to
> `^0.8.26`. Because they're committed (not a submodule), this persists across clones; the re-apply
> one-liner only matters if re-vendoring from upstream:
> `find lib/reactive-lib-omni/src -name '*.sol' -exec sed -i '' 's/\^0\.8\.29;/^0.8.26;/' {} +`

---

### 9.2 RangeGuardReactive.sol Imports

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// AbstractPausableReactive is a LOCAL port (the Omni lib removed the upstream one).
import {AbstractPausableReactive} from "./base/AbstractPausableReactive.sol";
// ISystemContract supplies the CallbackConfiguration_V_1_0 struct for requestCallbackV_1_0.
import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";
```

The local `AbstractPausableReactive` (inheriting Omni's `AbstractReactive`) provides:

- `AbstractReactive` base (IReactive + AbstractPayer)
- `SYSTEM` — Reactive Network system contract constant (`0x8888…8888`); use for
  `subscribe`/`unsubscribe`/`requestCallbackV_1_0` (the old `service` field was removed upstream)
- `REACTIVE_IGNORE` — constant for unfiltered topic subscriptions
- `vm` — bool flag; `true` when running outside ReactVM (restored by the local port)
- `vmOnly` / `rnOnly` — modifiers restoring the ReactVM / Reactive-Network gating
- `owner` — deployer address
- `paused` — boolean pause state
- `pause()` / `resume()` — owner-controlled
- `getPausableSubscriptions()` — override to define pausable subscriptions
- `Subscription` — the struct type (snake_case fields, decoupled from the renamed `LogRecord`)

---

### 9.3 RangeGuardHook.sol Additional Import (retrofit)

```solidity
import {AbstractCallback} from
    "reactive-lib/src/base/AbstractCallback.sol";
```

---

### 9.4 Contract Declaration

```solidity
contract RangeGuardReactive is AbstractPausableReactive {

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant REACTIVE_CHAIN_ID       = 5318007;
    uint64  private constant CALLBACK_GAS_LIMIT      = 300_000;
    uint256 private constant MAX_POSITIONS_PER_CYCLE = 20;

    uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(keccak256(
        "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
    ));
    uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256(
        "TickUpdated(bytes32,int24,uint256)"
    ));
    uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256(
        "PositionClosed(bytes32,bytes32,address)"
    ));

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable hookAddress;
    uint256 public immutable hookChainId;
    uint256 public immutable cronTopic;
    uint256 public immutable minCheckpointInterval;

    struct PositionInfo {
        bytes32 poolId;
        int24   tickLower;
        int24   tickUpper;
        bool    lastKnownInRange;
        bool    active;
        uint256 lastCheckpointTime;
    }

    mapping(bytes32 => PositionInfo) public positions;
    bytes32[] public activeKeys;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _hookAddress,
        uint256 _hookChainId,
        uint256 _cronTopic,
        uint256 _minCheckpointInterval
    ) payable {
        hookAddress            = _hookAddress;
        hookChainId            = _hookChainId;
        cronTopic              = _cronTopic;
        minCheckpointInterval  = _minCheckpointInterval;

        if (!vm) {
            // Cron heartbeat (ReactVM)
            SYSTEM.subscribe(
                block.chainid, address(SYSTEM), _cronTopic,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            // Hook events (Sepolia)
            SYSTEM.subscribe(
                _hookChainId, _hookAddress,
                POSITION_REGISTERED_TOPIC_0,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            SYSTEM.subscribe(
                _hookChainId, _hookAddress,
                TICK_UPDATED_TOPIC_0,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            SYSTEM.subscribe(
                _hookChainId, _hookAddress,
                POSITION_CLOSED_TOPIC_0,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSABLE SUBSCRIPTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Only the Cron heartbeat is pausable.
    ///         Hook event subscriptions remain active when paused.
    function getPausableSubscriptions()
        internal view override
        returns (Subscription[] memory)
    {
        Subscription[] memory subs = new Subscription[](1);
        subs[0] = Subscription(
            block.chainid,
            address(SYSTEM),
            cronTopic,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        return subs;
    }
}
```

---

### 9.5 Deployment Command

```bash
# Demo (Sepolia) — Cron10, 2-minute interval
forge create src/RangeGuardReactive.sol:RangeGuardReactive \
  --rpc-url $REACTIVE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args $HOOK_ADDRESS $HOOK_CHAIN_ID $CRON10_TOPIC 120 \
  --value 0.01ether

# Mainnet — Cron1000, 24-hour interval
forge create src/RangeGuardReactive.sol:RangeGuardReactive \
  --rpc-url $REACTIVE_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args $HOOK_ADDRESS $HOOK_CHAIN_ID $CRON1000_TOPIC 86400 \
  --value 0.01ether
```

The `payable` constructor allows initial rGas funding at deployment.

## 10. Reaction: PositionRegistered

### 10.1 Trigger

Received when `afterAddLiquidity` on the hook registers a new LP position.
Signal to begin tracking the position for range detection and heartbeat.

### 10.2 Full Handler

```solidity
function _handlePositionRegistered(LogRecord calldata log) internal {
    bytes32 poolId      = bytes32(log.topic1);
    bytes32 positionKey = bytes32(log.topic2);

    (
        int24 tickLower,
        int24 tickUpper,
        ,,,             // entryAmt0, entryAmt1, entryNotionalStable (unused)
        int24 entryTick,
        ,,              // depositTime, coverageApr, secondsPerYear (unused)
    ) = abi.decode(
        log.data,
        (int24, int24, uint128, uint128, uint256, int24, uint32, uint256, uint256)
    );

    // Guard: skip if already tracking
    if (positions[positionKey].active) return;

    positions[positionKey] = PositionInfo({
        poolId            : poolId,
        tickLower         : tickLower,
        tickUpper         : tickUpper,
        lastKnownInRange  : (entryTick >= tickLower && entryTick < tickUpper),
        active            : true,
        lastCheckpointTime: block.timestamp
    });

    activeKeys.push(positionKey);

    emit PositionTracked(poolId, positionKey,
        (entryTick >= tickLower && entryTick < tickUpper), block.timestamp);
}
```

### 10.3 Notes

**lastKnownInRange initialization** mirrors the hook's
`_lastRangeEventInRange` initialization. Both must agree on initial
range status for the first transition to fire correctly.

**Deposit cases:**
| Case | entryTick | lastKnownInRange |
|------|-----------|-----------------|
| A (100% token0, below range) | < tickLower | false |
| B (mixed, in range) | >= tickLower && < tickUpper | true |
| C (100% token1, above range) | >= tickUpper | false |

---

## 11. Reaction: TickUpdated

### 11.1 Trigger

Received after every swap on the hook. Primary driver for range
transition detection.

### 11.2 Full Handler

```solidity
function _handleTickUpdated(LogRecord calldata log) internal {
    bytes32 poolId = bytes32(log.topic1);
    (int24 newTick, ) = abi.decode(log.data, (int24, uint256));

    uint256 len = activeKeys.length;
    for (uint256 i = 0; i < len; i++) {
        bytes32 positionKey = activeKeys[i];
        PositionInfo storage pos = positions[positionKey];

        if (!pos.active) continue;
        if (pos.poolId != poolId) continue;  // only positions in this pool

        bool isInRange = (newTick >= pos.tickLower && newTick < pos.tickUpper);

        if (pos.lastKnownInRange && !isInRange) {
            // Transition: in range → out of range
            bytes memory payload = abi.encodeWithSignature(
                "checkpointAndEmitOutOfRange(address,bytes32,bytes32)",
                address(0), poolId, positionKey
            );
            SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));
            pos.lastKnownInRange = false;
            emit RangeTransitionDetected(poolId, positionKey, false, block.timestamp);

        } else if (!pos.lastKnownInRange && isInRange) {
            // Transition: out of range → back in range
            bytes memory payload = abi.encodeWithSignature(
                "checkpointAndEmitBackInRange(address,bytes32,bytes32)",
                address(0), poolId, positionKey
            );
            SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));
            pos.lastKnownInRange = true;
            emit RangeTransitionDetected(poolId, positionKey, true, block.timestamp);
        }
        // No transition: no Callback emitted, lastKnownInRange unchanged
    }
}
```

### 11.3 Key Design Notes

**lastKnownInRange updated before Callback lands.** If the hook's guard
reverts (duplicate event), the Reactive contract's state is already
correct and does not retry.

**No position cap.** Unlike the heartbeat, `MAX_POSITIONS_PER_CYCLE`
does NOT apply here. Every active position in the affected pool must
be evaluated on every swap — transitions must not be silently dropped.

**Pool-scoped iteration.** Only positions matching `poolId` are evaluated.
Positions in other pools are skipped via `pos.poolId != poolId` guard.

---

## 12. Reaction: PositionClosed

### 12.1 Trigger

Received when `afterRemoveLiquidity` emits `PositionClosed` on any
settlement path. Signal to stop tracking the position.

### 12.2 Full Handler

```solidity
function _handlePositionClosed(LogRecord calldata log) internal {
    bytes32 poolId      = bytes32(log.topic1);
    bytes32 positionKey = bytes32(log.topic2);

    if (!positions[positionKey].active) return;

    positions[positionKey].active = false;
    _removeActiveKey(positionKey);

    emit PositionUntracked(poolId, positionKey, block.timestamp);
}

function _removeActiveKey(bytes32 positionKey) internal {
    uint256 len = activeKeys.length;
    for (uint256 i = 0; i < len; i++) {
        if (activeKeys[i] == positionKey) {
            activeKeys[i] = activeKeys[len - 1];
            activeKeys.pop();
            return;
        }
    }
}
```

### 12.3 Notes

**No Callback emitted.** This handler is purely administrative — no
hook call is needed when a position closes.

**Swap-and-pop** for O(1) storage writes. Array order is not semantically
meaningful.

**PositionInfo not deleted** — only marked inactive. Heartbeat and
TickUpdated handlers check `pos.active` before processing.

---

## 13. Heartbeat Checkpointing (Cron10 / Cron1000)

### 13.1 Trigger

Received when the ReactVM system contract emits the subscribed Cron
event. Drives periodic accrual updates for all active tracked positions.

### 13.2 minCheckpointInterval and Cron Selection

| Parameter               | Demo (Sepolia)      | Mainnet               |
| ----------------------- | ------------------- | --------------------- |
| `minCheckpointInterval` | 120 seconds (2 min) | 86400 seconds (24 hr) |
| `cronTopic`             | Cron10 (~1 min)     | Cron1000 (~2 hr)      |

Demo: Cron10 fires every ~1 minute. Time gate skips positions checkpointed
in the last 2 minutes. Approximately every other Cron10 cycle results in
Callbacks.

Mainnet: Cron1000 fires every ~2 hours. Time gate skips positions
checkpointed in the last 24 hours. Approximately every 12th Cron1000
cycle results in Callbacks (~once per day per position).

### 13.3 Pause/Resume via AbstractPausableReactive

The Cron subscription is declared as pausable via
`getPausableSubscriptions()`. Calling `pause()` halts Cron event
delivery — hook event subscriptions (`PositionRegistered`,
`TickUpdated`, `PositionClosed`) remain active.

```
pause()   → Cron stops → no heartbeat Callbacks → rGas conserved
resume()  → Cron restarts → heartbeat resumes
```

**Operational workflow:**

```
Deploy Reactive contract    → heartbeat active
Between demo sessions       → call pause()
Before demo                 → call resume()
Demo complete               → call pause()
```

Only `owner` (deployer, from `AbstractPausableReactive`) can pause/resume.

### 13.4 Full Handler

```solidity
function _handleHeartbeat() internal {
    // AbstractPausableReactive handles Cron delivery when paused —
    // if paused, Cron events are not delivered, so this handler
    // is only called when active.

    uint256 len   = activeKeys.length;
    uint256 count = 0;

    for (uint256 i = 0; i < len && count < MAX_POSITIONS_PER_CYCLE; i++) {
        bytes32 positionKey = activeKeys[i];
        PositionInfo storage pos = positions[positionKey];

        if (!pos.active) continue;
        if (block.timestamp - pos.lastCheckpointTime < minCheckpointInterval)
            continue;

        bytes memory payload = abi.encodeWithSignature(
            "checkpointCallback(address,bytes32,bytes32)",
            address(0),    // RVM ID placeholder
            pos.poolId,
            positionKey
        );
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0(hookChainId, hookAddress, CALLBACK_GAS_LIMIT, payload));

        pos.lastCheckpointTime = block.timestamp;
        count++;

        emit HeartbeatCheckpointFired(pos.poolId, positionKey, block.timestamp);
    }
}
```

### 13.5 rGas Cost Per Cycle

**Demo (Cron10, 2-minute interval):**

```
Cron10 cycles per hour:        ~60
Cycles that fire Callbacks:    ~30 (every other cycle, 2-min gate)
Max Callbacks per firing:      20
Gas per Callback:              300,000
Hourly rGas (worst case):      30 × 20 × 300,000 = 180,000,000 rGas
```

**Mainnet (Cron1000, 24-hour interval):**

```
Cron1000 cycles per day:       ~12
Cycles that fire Callbacks:    ~1 (once per 24 hours per position)
Daily rGas (20 positions):     20 × 300,000 = 6,000,000 rGas/day
```

Fund at deployment with enough ETH to cover at least 48 hours (demo)
or 30 days (mainnet).

---

## 14. Gas, Liveness, and Approximation Concerns

### 14.1 ReactVM Gas Constraints

**TickUpdated handler** iterates ALL active positions on every swap:

```
ReactVM iterations per hour = N × S  (N positions, S swaps/hr)
```

MVP (N=5, S=100): 500 iterations/hr — negligible.
Production (N=20, S=10,000): 200,000 iterations/hr — monitor carefully.

**Heartbeat handler** capped at `MAX_POSITIONS_PER_CYCLE = 20`.
Predictable and bounded.

### 14.2 Lazy Accrual Bounded Error at Transitions

**In → Out:** under-accrues by at most one `minCheckpointInterval`.
**Out → In:** may over-accrue by at most one `minCheckpointInterval`.

Both errors are bounded and negligible relative to the 45-day demo
lifecycle. For a 2-minute interval, maximum error is 2 minutes of
coverage either way.

### 14.3 Heartbeat Gaps

If paused or rGas depleted:

- `checkpoint()` is permissionless — LPs or keepers can call directly
- `getEarnedCoverage()` on the hook always returns the live simulated value
- Final `_accrue` in `afterRemoveLiquidity` catches up at settlement

### 14.4 State Desynchronization

If `lastKnownInRange` diverges from hook's `_lastRangeEventInRange`:

- Hook guard prevents duplicate events
- Reactive contract accepts hook's state as authoritative on revert
- Next `TickUpdated` naturally re-converges state

### 14.5 Missed PositionRegistered Events

Deploy the Reactive contract before any LP deposits. If deployed mid-
lifecycle, positions already active will not be tracked. See §18.6 for
the production recovery pattern.

---

## 15. Security Requirements

### 15.1 Hook-Side Authorization

`onlyServiceProvider` (AbstractCallback) verifies `msg.sender ==
callbackSender` (Callback Proxy). The hook cannot verify which specific
Reactive contract triggered a callback. This is acceptable because the
reactive-callable functions cannot move funds or modify PoolConfig.

### 15.2 Hook-Side Guards Summary

| Function                       | Guard                       | Protection                          |
| ------------------------------ | --------------------------- | ----------------------------------- |
| `checkpointCallback`           | `CheckpointTooSoon`         | Prevents spam accrual               |
| `checkpointCallback`           | `PositionNotActive`         | Prevents calls on settled positions |
| `checkpointCallback`           | `onlyServiceProvider`      | Restricts to Callback Proxy         |
| `checkpointAndEmitOutOfRange`  | `PositionAlreadyOutOfRange` | Prevents duplicate events           |
| `checkpointAndEmitBackInRange` | `PositionAlreadyInRange`    | Prevents duplicate events           |
| All three                      | `PositionNotActive`         | Prevents calls on settled positions |

### 15.3 Reactive Contract Access Control

```
react()                → vmOnly — only ReactVM can call
pause() / resume()     → onlyOwner (AbstractPausableReactive)
hookAddress            → immutable
cronTopic              → immutable
minCheckpointInterval  → immutable
```

### 15.4 Reactive Contract Cannot

- Move funds
- Modify PoolConfig
- Modify earnedCoverageStable, bufferBalanceStable, totalPaidOutStable
- Trigger settlement or payout execution
- Register or close positions

### 15.5 Worst-Case Attack Scenarios

**Spam checkpointCallback:** Hook reverts `CheckpointTooSoon`. No accrual
advance beyond rate-limited interval. Zero protocol cost.

**Duplicate range events:** Hook guard (`PositionAlreadyOutOfRange` /
`PositionAlreadyInRange`) prevents duplicate events. Zero financial damage.

**Forced over-accrual:** Bounded by `maxAccruedCoverageMultiple` ceiling.
Payout still bounded by all three caps at settlement.

**rGas depletion attack:** rGas is consumed by the contract's own
Callbacks — cannot be drained by external parties.

### 15.6 Deployment Security

- Deploy after hook is deployed and verified
- Verify `hookAddress` before deploying
- Verify `cronTopic` from official Reactive Network docs
- Fund rGas at deployment — do not deploy with zero balance

### 15.7 Known Acceptable Risks (MVP)

- Hook cannot distinguish legitimate vs malicious Reactive contracts — accepted
- Lazy accrual bounded error at transitions — accepted
- Mid-lifecycle deployment misses prior events — accepted (deploy before deposits)
- No upgrade pattern — redeploy if bug found

---

## 16. Reactive Contract Events

Events emitted on **ReactVM** (not Sepolia) for operational visibility.

```solidity
/*//////////////////////////////////////////////////////////////
                     REACTIVE CONTRACT EVENTS
//////////////////////////////////////////////////////////////*/

/// @notice Emitted when a new position is added to tracking.
event PositionTracked(
    bytes32 indexed poolId,
    bytes32 indexed positionKey,
    bool            initiallyInRange,
    uint256         timestamp
);

/// @notice Emitted when a position is removed from tracking.
event PositionUntracked(
    bytes32 indexed poolId,
    bytes32 indexed positionKey,
    uint256         timestamp
);

/// @notice Emitted when a range transition is detected and Callback fired.
///         inRange=false → checkpointAndEmitOutOfRange fired.
///         inRange=true  → checkpointAndEmitBackInRange fired.
event RangeTransitionDetected(
    bytes32 indexed poolId,
    bytes32 indexed positionKey,
    bool            inRange,
    uint256         timestamp
);

/// @notice Emitted when a heartbeat Callback is fired for a position.
event HeartbeatCheckpointFired(
    bytes32 indexed poolId,
    bytes32 indexed positionKey,
    uint256         timestamp
);
```

### Event vs Hook Event Correspondence

| ReactVM event              | Corresponding Sepolia event                  |
| -------------------------- | -------------------------------------------- |
| `PositionTracked`          | — (triggered by hook's `PositionRegistered`) |
| `RangeTransitionDetected`  | `PositionOutOfRange` / `PositionBackInRange` |
| `HeartbeatCheckpointFired` | `Checkpointed` + `AccrualUpdated`            |
| `PositionUntracked`        | — (triggered by hook's `PositionClosed`)     |

ReactVM events fire when the Reactive contract **detects and dispatches**.
Sepolia events fire when the Callback **lands and executes** on the hook.
Monitor both chains during the demo to verify end-to-end delivery.

### Operational Monitoring During Demo

If `RangeTransitionDetected` fires on ReactVM but `PositionOutOfRange`
does NOT appear on Sepolia — the Callback was dispatched but failed.
Check `_lastRangeEventInRange` guard state or rGas balance.

## 17. Acceptance Criteria

### 17.1 Hook Retrofit (Workstream 1)

All existing 210 tests must continue passing after hook changes.

**Constructor and inheritance:**

- [ ] `RangeGuardHook` constructor accepts `address _callbackSender` as third arg
- [ ] `AbstractCallback` correctly inherited
- [ ] `onlyServiceProvider` gates all three reactive functions

**Removed state:**

- [ ] `reactiveContract[poolId]` mapping removed
- [ ] `_reactiveSet[poolId]` mapping removed
- [ ] No `setReactiveContract()` reference remains

**New functions (all with `address /*sender*/` first param):**

- [ ] `checkpointCallback(address, PoolId, bytes32)` — `onlyServiceProvider`,
      same gates as `checkpoint()`, emits `AccrualUpdated` + `Checkpointed`
- [ ] `checkpointAndEmitOutOfRange(address, PoolId, bytes32)` —
      `onlyServiceProvider`, not rate-limited, reverts
      `PositionAlreadyOutOfRange` on duplicate, emits `AccrualUpdated` +
      `PositionOutOfRange`
- [ ] `checkpointAndEmitBackInRange(address, PoolId, bytes32)` —
      `onlyServiceProvider`, not rate-limited, reverts
      `PositionAlreadyInRange` on duplicate, emits `AccrualUpdated` +
      `PositionBackInRange`

**New state and events:**

- [ ] `_lastRangeEventInRange[poolId][positionKey]` initialized in
      `afterAddLiquidity` based on entry tick vs tick range
- [ ] `PositionClosed` emitted in `afterRemoveLiquidity` on all four
      settlement paths

**Tests:**

- [ ] Unit tests for all three new hook functions
- [ ] `_lastRangeEventInRange` initialization tests (all three deposit cases)
- [ ] `PositionClosed` emission tests (all four settlement paths)
- [ ] Fuzz tests for range guard alternation
- [ ] Invariant: `_lastRangeEventInRange` alternates correctly
- [ ] All 210 existing tests still pass

---

### 17.2 RangeGuardReactive Contract (Workstream 2)

**Deployment:**

- [ ] Deploys on Anvil with `if (!vm)` guard — no revert during tests
- [ ] `hookAddress`, `cronTopic`, `minCheckpointInterval` immutables set
- [ ] `owner` set to deployer via `AbstractPausableReactive`
- [ ] Subscribes to 4 sources in constructor when `!vm`

**react() routing:**

- [ ] `log.contractAddress == address(SYSTEM)` → `_handleHeartbeat`
- [ ] `POSITION_REGISTERED_TOPIC_0` → `_handlePositionRegistered`
- [ ] `TICK_UPDATED_TOPIC_0` → `_handleTickUpdated`
- [ ] `POSITION_CLOSED_TOPIC_0` → `_handlePositionClosed`

**PositionRegistered handler:**

- [ ] Extracts poolId, positionKey, tickLower, tickUpper, entryTick
- [ ] Initializes `lastKnownInRange` correctly for all three deposit cases
- [ ] Adds to `positions` and `activeKeys`
- [ ] Emits `PositionTracked`
- [ ] Duplicate guard skips already-active positions

**TickUpdated handler:**

- [ ] Filters by poolId
- [ ] Detects in→out: fires `checkpointAndEmitOutOfRange` Callback,
      updates `lastKnownInRange = false`
- [ ] Detects out→in: fires `checkpointAndEmitBackInRange` Callback,
      updates `lastKnownInRange = true`
- [ ] Emits `RangeTransitionDetected` on transitions
- [ ] No Callback on no-transition ticks
- [ ] No position cap

**Heartbeat handler:**

- [ ] Skips inactive positions
- [ ] Skips positions within `minCheckpointInterval`
- [ ] Emits `checkpointCallback` Callback for due positions
- [ ] Updates `lastCheckpointTime` after each emit
- [ ] Caps at `MAX_POSITIONS_PER_CYCLE = 20`
- [ ] Emits `HeartbeatCheckpointFired`

**PositionClosed handler:**

- [ ] Sets `active = false`
- [ ] Removes from `activeKeys` via swap-and-pop
- [ ] Emits `PositionUntracked`
- [ ] Defensive guard skips unknown positions

**Pause/Resume:**

- [ ] `getPausableSubscriptions()` returns only Cron subscription
- [ ] `pause()` halts Cron delivery, hook events unaffected
- [ ] `resume()` restarts Cron delivery
- [ ] Only owner can call `pause()` / `resume()`

---

### 17.3 Integration Tests

- [ ] **Coverage accrual lifecycle** (closes Phase 3 gap):
      add position → heartbeat checkpoints → range out → range back in
      → heartbeat checkpoints → remove → ClaimSettled. Verify full
      `AccrualUpdated` history, `PositionOutOfRange`, `PositionBackInRange`.
- [ ] **Pause/resume:** pause → Cron fires → no Callback → resume →
      Cron fires → Callback emitted
- [ ] **PositionClosed lifecycle:** add → settle → verify removed from
      `activeKeys`, heartbeat skips it

---

### 17.4 Demo Readiness

- [ ] Reactive contract deploys on Sepolia with correct constructor args
- [ ] rGas balance funded for 48-hour demo operation
- [ ] LP deposit → `PositionTracked` on ReactVM
- [ ] Swap crossing boundary → `RangeTransitionDetected` on ReactVM →
      `PositionOutOfRange` on Sepolia (end-to-end verified)
- [ ] Cron10 → `HeartbeatCheckpointFired` on ReactVM →
      `Checkpointed` on Sepolia (end-to-end verified)
- [ ] `pause()` → heartbeat stops → `resume()` → restarts (verified)
- [ ] Full 45-day demo script runs without error

---

### 17.5 Test Count Target

| Suite                                    | Estimated new tests |
| ---------------------------------------- | ------------------- |
| Hook unit (new functions)                | +15                 |
| Hook fuzz (range guard)                  | +4                  |
| Hook invariant (range guard)             | +4                  |
| Reactive unit (react routing + handlers) | +22                 |
| Reactive fuzz                            | +4                  |
| Integration (coverage accrual lifecycle) | +1                  |
| Integration (pause/resume)               | +1                  |
| **Total new**                            | **~51**             |
| **Running total**                        | **~261**            |

---

## 18. Open Implementation Notes

### 18.1 Verify topic0 Constants Against Deployed Hook ABI

Before deploying, verify all three topic0 constants:

```bash
forge inspect RangeGuardHook abi | grep -A5 "PositionRegistered"
```

Compare event parameter types against the constants in §8.5.

### 18.2 AbstractPausableReactive Pause/Resume Events

RESOLVED: `AbstractPausableReactive` is now a local port (`src/base/`), so its events are
under our control — it emits no pause/resume events; `pause()`/`resume()` only flip `paused`
and (un)subscribe via `SYSTEM`.

### 18.3 Cron Topic Values

The exact `uint256` values for Cron10 and Cron1000 topics must be
sourced from official Reactive Network documentation at deployment time.
Do not hardcode — verify before each deployment.

### 18.4 minCheckpointInterval Per Pool (Production Upgrade)

MVP uses a single `minCheckpointInterval` for all pools. Production
upgrade: subscribe to `PoolConfigInitialized` and store per-pool values:

```solidity
mapping(bytes32 => uint32) public poolCheckpointIntervals;
```

Out of MVP scope.

### 18.5 Mid-Lifecycle Deployment Recovery

Deploy before any LP deposits. Production upgrade: add owner-callable
manual position registration:

```solidity
function registerExistingPosition(
    bytes32 poolId, bytes32 positionKey,
    int24 tickLower, int24 tickUpper, bool currentlyInRange
) external onlyOwner { ... }
```

Out of MVP scope.

### 18.6 vm Flag in Foundry Tests

RESOLVED: tests etch a `MockSystemContract` at `SYSTEM` (`0x8888…8888`). For the reactive
handler tests, the mock is etched **after** constructing the harness, so `detectVm()` (run in
the constructor) still sets `vm == true` (keeping `react()` callable and skipping constructor
subscriptions), while the mock is present afterward so the handlers' `SYSTEM.requestCallbackV_1_0`
dispatch succeeds (the mock re-emits the legacy `Callback` event so log-matching assertions
hold). Pause/resume tests etch it **before** construction (so `vm == false`, the `rnOnly` path).

### 18.7 rGas Funding Mechanism

Verify the exact funding mechanism with Reactive Network documentation:

- Is rGas funded in ETH at deployment via `payable` constructor?
- Is there a separate top-up function?
- Minimum recommended balance for 48-hour demo?

### 18.8 Pattern A Upgrade Path (Production)

For >20 positions: emit one Callback per Cron cycle to a
`RangeGuardBatchCheckpoint` contract on Sepolia. `checkpointCallback()`
is `onlyServiceProvider` — the batch contract must also call through
the Callback Proxy. Alternatively, use the permissionless `checkpoint()`
from a batch contract. No hook changes required.

### 18.9 Callback Proxy Address — Per Network (Omni fork)

The Callback Proxy is **per network**, not the legacy `0x…fffFfF`. Always confirm the
host-chain proxy for your target Reactive network at
dev.reactive.network/origins-and-destinations before deploying `RangeGuardHook` with
`_callbackSender`. Confirmed for the demo (Reactive Lasna → Ethereum Sepolia):
`0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`.

### 18.10 Docs Updated After This Session

| Document                        | Change needed                                    |
| ------------------------------- | ------------------------------------------------ |
| spec.md §8 function summary     | `checkpointCallback` → `onlyServiceProvider`    |
| context.md §11                  | `AbstractPausableReactive`, updated descriptions |
| CLAUDE.md Current Session State | Workstream 2 updated                             |
| project-status.md Phase 3B      | Reactive contract bullet updated                 |

### 18.11 lastKnownInRange — bool vs enum (Production Consideration)

`lastKnownInRange` is a `bool` for MVP. This is sufficient because
`PositionRegistered` always provides `entryTick`, `tickLower`, and
`tickUpper`, so the initial range status is always deterministic:

```solidity
lastKnownInRange = (entryTick >= tickLower && entryTick < tickUpper);
```

There is no unknown state in normal operation — the Reactive contract
always knows range status from the moment of registration.

**Production upgrade:** If mid-lifecycle recovery (§18.5) is implemented
— where positions are manually registered after the Reactive contract is
deployed — a third state is needed for positions whose current tick is
unknown at registration time:

```solidity
enum RangeStatus {
    Unknown,    // registered mid-lifecycle; no Callback on first TickUpdated
    InRange,    // last known state: in range
    OutOfRange  // last known state: out of range
}
```

The `TickUpdated` handler would set `Unknown` positions to `InRange` or
`OutOfRange` on the first tick received without emitting a Callback —
then operate normally from the second tick onward.

This is out of MVP scope. Keep `bool` until mid-lifecycle recovery is
implemented.
