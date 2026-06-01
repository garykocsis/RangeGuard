# Purpose

This document defines the valid lifecycle states and transitions
for RangeGuard LP positions and pool setup.

It serves as the canonical reference for:

- hook behavior
- Reactive Network interactions
- testing logic
- invariant generation
- frontend state interpretation

---

# Pool Setup Lifecycle

## Why a separate pool lifecycle

Pool setup is a prerequisite for any LP position. A pool moves through five
states before it is fully operational. These states are distinct from position
states and are owned by different actors at each phase.

## Pool Setup States

### Unregistered

Hook is deployed. No config has been staged for this poolId.

Properties:

- `_pendingSetup[poolId].exists == false`
- `_poolInitialized[poolId] == false`
- Pool does not exist in PoolManager
- No LP interaction possible

### Staged

Owner has called `stagePoolConfig()`. Config is stored in `_pendingSetup` but
is not yet live. Pool does not yet exist in PoolManager.

Properties:

- `_pendingSetup[poolId].exists == true`
- `_poolInitialized[poolId] == false`
- `authorizedInitializer` and `expectedSqrtPriceX96` are set
- Pool does not exist in PoolManager
- Re-stageable: owner may overwrite `_pendingSetup[poolId]` at any time
- No LP interaction possible

### Initialized

`authorizedInitializer` called `PoolManager.initialize()`. Hook's
`_beforeInitialize` validated caller and price, committed staged config,
and marked pool initialized. Pool now exists in PoolManager.

Properties:

- `_poolInitialized[poolId] == true`
- `poolConfig[poolId]` is live and immutable
- `_pendingSetup[poolId].exists == false` (deleted on commit)
- `reactiveContract[poolId] == address(0)` — not yet registered
- `_reactiveSet[poolId] == false`

### ReactiveRegistered

Owner deployed the reactive contract and called `setReactiveContract()`.

Properties:

- `_reactiveSet[poolId] == true`
- `reactiveContract[poolId] != address(0)`
- `onlyReactive(poolId)` access control is now functional
- `_reactiveSet` is permanently true — no further changes possible

### Seeded

Admin called `seedBuffer()`. Buffer is funded and IL payouts can execute.

Properties:

- `poolState[poolId].bufferBalanceStable > 0`
- Pool is fully operational

## Pool Setup Transitions

```
Deploy hook
  → Unregistered

owner → hook.stagePoolConfig(key, config, authorizedInitializer, expectedSqrtPriceX96)
  Unregistered → Staged

owner → hook.stagePoolConfig() again (before init)
  Staged → Staged  (overwrites _pendingSetup)

authorizedInitializer → PoolManager.initialize(key, expectedSqrtPriceX96)
  Staged → Initialized

owner → hook.setReactiveContract(key, reactive)
  Initialized → ReactiveRegistered

admin → hook.seedBuffer(key, amount)
  ReactiveRegistered → Seeded
```

## Pool Setup Invalid Transitions

```
Unregistered → Initialized     (PoolNotStaged)
Staged → Initialized            with wrong caller (UnauthorizedInitializer)
Staged → Initialized            with wrong price  (UnexpectedSqrtPrice)
Any state → Staged              after initialized  (PoolAlreadyInitialized)
Any state → ReactiveRegistered  more than once     (ReactiveAlreadySet)
Unregistered → ReactiveRegistered                  (PoolNotInitialized)
```

## Minimum Pool State for LP Interaction

- Position registration: requires **Initialized** or later
- Reactive automation: requires **ReactiveRegistered** or later
- IL payout execution: requires **Seeded** (real token balance)
- **Recommended minimum: Seeded**

---

# Position Lifecycle State Machine

## Core Position States

### Registered

Position exists and is active. No accrual has occurred yet (dt=0 at registration).

Properties:

- `active == true`
- `liquidity` set to full position liquidity at registration
- position registered in storage

### InRangeAccruing

Position is active and current tick is inside range.

Properties:

- accrual enabled
- `checkpoint()` may increase `earnedCoverageStable`

### OutOfRangePaused

Position is active but current tick is outside range.

Properties:

- accrual paused
- `checkpoint()` emits zero accrual delta

### Cleared

Position storage reset after settlement completes atomically in
`afterRemoveLiquidity`. Settlement (final accrual, IL, payout, transfer)
and cleanup occur in a single callback — there is no persistent intermediate
settlement state.

Properties:

- `active == false`
- storage slot available for reuse
- position no longer valid

## Valid State Transitions

Note: all position transitions require pool to be in **Initialized** or later state.
MVP enforces one add per position — `afterAddLiquidity` reverts `PositionAlreadyRegistered`
if the position key is already active.

```
afterAddLiquidity (first add only):
  → Registered

checkpoint() while in range:
  Registered       → InRangeAccruing
  InRangeAccruing  → InRangeAccruing

checkpoint() while out of range:
  Registered        → OutOfRangePaused
  InRangeAccruing   → OutOfRangePaused
  OutOfRangePaused  → OutOfRangePaused

Reactive range re-entry:
  OutOfRangePaused → InRangeAccruing

beforeRemoveLiquidity (validation only — no state transition):
  Validates: active position + full-withdrawal only
  No position state is written. If validation fails, reverts entirely.

afterRemoveLiquidity (atomic settlement):
  Any active state → Cleared
  Settlement (final _accrue, _computeIL, _computePayout, strict-CEI
  cleanup + transfer) is atomic within this single callback.
  No persistent intermediate state exists between before and after.
```

## Invalid Transitions

```
Cleared           → any active state      (no re-activation)
inactive position → checkpoint()          (PositionNotActive / silent skip)
inactive position → payout execution      (afterRemoveLiquidity no-ops)
afterAddLiquidity on active position      (PositionAlreadyRegistered)
partial removal on active position        (PartialWithdrawalNotSupported in beforeRemoveLiquidity)
```

## State Ownership Rules

Hook contract owns:

- accounting state
- accrual state
- pool setup state (`_pendingSetup`, `_poolInitialized`, `_reactiveSet`)

Reactive contract owns:

- external automation
- tick monitoring
- heartbeat scheduling

Owner owns:

- pool staging (`stagePoolConfig`)
- reactive registration (`setReactiveContract`)

Config admin owns:

- buffer seeding (`seedBuffer`)

Authorized initializer owns:

- pool creation moment (`PoolManager.initialize`)

**Reactive contract must never directly mutate accounting state.**

## Derived State Rules

Pool setup state is derived from:

- `_pendingSetup[poolId].exists` → Staged
- `_poolInitialized[poolId]` → Initialized or later
- `_reactiveSet[poolId]` → ReactiveRegistered or later
- `poolState[poolId].bufferBalanceStable > 0` → Seeded

Range status is derived from:

```
tickLower <= currentTick < tickUpper
```

Accrual eligibility is derived from:

- active position
- in-range status
- `dt > 0`

Claim eligibility is derived from:

```
block.timestamp - depositTime >= minHoldSeconds
```

(evaluated in `afterRemoveLiquidity` — not in `beforeRemoveLiquidity`)

## Frontend Interpretation Rules

### Pool setup states

| State              | Display                          |
| ------------------ | -------------------------------- |
| Unregistered       | "Pool not configured"            |
| Staged             | "Pool pending initialization"    |
| Initialized        | "Pool active — reactive pending" |
| ReactiveRegistered | "Pool active — buffer pending"   |
| Seeded             | "Pool fully operational"         |

### Position states

| State            | Display                                  |
| ---------------- | ---------------------------------------- |
| Registered       | "Position active — not yet checkpointed" |
| InRangeAccruing  | "Earning coverage"                       |
| OutOfRangePaused | "Coverage paused"                        |
| Cleared          | "Position closed"                        |
