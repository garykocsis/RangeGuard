# Purpose

This document defines the valid lifecycle states and transitions for:

1. **Pool setup** — the three-phase initialization sequence before any LP can interact
2. **LP positions** — the full lifecycle from deposit through settlement

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
- Pool exists in PoolManager at exact `expectedSqrtPriceX96`
- LP position registration technically possible but not recommended
  until ReactiveRegistered + Seeded

### ReactiveRegistered

Owner deployed the reactive contract (using the now-known hook address)
and called `setReactiveContract()`. Reactive automation is now active.

Properties:

- `_reactiveSet[poolId] == true`
- `reactiveContract[poolId] != address(0)`
- `onlyReactive(poolId)` access control is now functional
- Range transition detection and periodic checkpoints are operational
- `_reactiveSet` is permanently true — no further changes possible

### Seeded

Admin called `seedBuffer()`. Buffer is funded and IL payouts can be executed.

Properties:

- `poolState[poolId].bufferBalanceStable > 0`
- Pool is fully operational
- LP deposits, checkpoints, and claim settlements all function correctly

## Pool Setup Transitions

```
Deploy hook
  → Unregistered

owner.stagePoolConfig(key, config, authorizedInitializer, expectedSqrtPriceX96)
  Unregistered → Staged

owner.stagePoolConfig() again (re-stage before init)
  Staged → Staged  (overwrites _pendingSetup)

authorizedInitializer → PoolManager.initialize(key, expectedSqrtPriceX96)
  (hook _beforeInitialize validates and commits)
  Staged → Initialized

owner.setReactiveContract(key, reactive)
  Initialized → ReactiveRegistered

admin.seedBuffer(key, amount)
  ReactiveRegistered → Seeded
  (also valid from Initialized, but not recommended before reactive is set)
```

## Pool Setup Invalid Transitions

```
Unregistered → Initialized     (PoolNotStaged — must stage first)
Staged → Initialized            with wrong caller (UnauthorizedInitializer)
Staged → Initialized            with wrong price  (UnexpectedSqrtPrice)
Any state → Staged              after initialized  (PoolAlreadyInitialized)
Any state → ReactiveRegistered  more than once     (ReactiveAlreadySet)
Unregistered → ReactiveRegistered                  (PoolNotInitialized)
```

## Pool Setup State Ownership

| Phase             | Actor                              | Function                   |
| ----------------- | ---------------------------------- | -------------------------- |
| Stage             | `owner` (contract-level)           | `stagePoolConfig()`        |
| Initialize        | `authorizedInitializer` (per-pool) | `PoolManager.initialize()` |
| Register reactive | `owner` (contract-level)           | `setReactiveContract()`    |
| Seed buffer       | `config.admin` (per-pool)          | `seedBuffer()`             |

Note: `owner` gates protocol-level operations (who can create pools).
`config.admin` gates pool-level operations (how a pool is funded).
These are intentionally separate roles.

## Minimum Pool State for LP Interaction

- Position registration (`afterAddLiquidity`): requires **Initialized** or later
- Reactive automation (checkpoints, range events): requires **ReactiveRegistered** or later
- IL payout execution: requires **Seeded** (buffer must have balance)
- **Recommended minimum before any LP interaction: Seeded**

---

# Position Lifecycle State Machine

## Core Position States

### Registered

Position exists and is active.

Properties:

- `active == true`
- `pendingPayout == 0`
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

### PendingSettlement

Position withdrawal initiated.

Properties:

- `pendingPayout` computed
- final accrual completed
- payout awaiting execution
- no further accrual permitted

### Settled

Payout execution completed.

Properties:

- `ClaimSettled` / `NoClaim` emitted
- buffer updated
- payout finalized

### Cleared

Position storage reset.

Properties:

- `active == false`
- `pendingPayout == 0`
- storage slot available for reuse
- position no longer valid

# Valid State Transitions

Note: all position transitions require pool to be in **Initialized** or later state.

```
afterAddLiquidity:
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

beforeRemoveLiquidity:
  any active state → PendingSettlement

afterRemoveLiquidity:
  PendingSettlement → Settled

cleanup:
  Settled → Cleared
```

# Invalid Transitions

```
Position:
  Cleared           → any active state
  PendingSettlement → InRangeAccruing
  Settled           → PendingSettlement
  inactive position → checkpoint()
  inactive position → payout execution
  OutOfRange        → payout execution    (settlement is valid but with zero delta
                                           from out-of-range period; full settlement
                                           still executes)
Pool:
  (see Pool Setup Invalid Transitions above)
  position registration before pool Initialized state
```

# State Ownership Rules

Hook contract owns:

- accounting state
- payout state
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

# Derived State Rules

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

# Frontend Interpretation Rules

## Pool setup states

| State              | Display                          |
| ------------------ | -------------------------------- |
| Unregistered       | "Pool not configured"            |
| Staged             | "Pool pending initialization"    |
| Initialized        | "Pool active — reactive pending" |
| ReactiveRegistered | "Pool active — buffer pending"   |
| Seeded             | "Pool fully operational"         |

## Position states

| State             | Display            |
| ----------------- | ------------------ |
| InRangeAccruing   | "Earning coverage" |
| OutOfRangePaused  | "Coverage paused"  |
| PendingSettlement | "Claim processing" |
| Cleared           | "Position closed"  |
