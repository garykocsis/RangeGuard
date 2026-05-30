## Purpose

This document defines the core protocol invariants for RangeGuard.

Invariants are conditions that must always remain true regardless of:

- swaps
- checkpoints
- liquidity events
- range transitions
- Reactive Network interactions
- execution ordering
- fuzzed inputs

These invariants serve as the canonical safety and correctness rules for:

- protocol implementation
- invariant testing
- fuzz testing
- integration testing
- audit review
- AI-assisted development

All accounting, accrual, settlement, lifecycle, and pool setup logic must
preserve these invariants under all valid execution paths.

---

# Accounting Invariants

- `earnedCoverageStable` must never decrease
- `earnedCoverageStable` must never exceed the configured accrual ceiling
- inactive positions must never accrue coverage
- `pendingPayout` must never be negative
- `bufferBalanceStable` must never be negative
- accrual must never modify entry position snapshots
- `lastAccrualTime` must monotonically increase
- `checkpoint()` must never reduce total earned coverage
- `poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM` must hold for all
  initialized pools — enforced at `stagePoolConfig()` time; the buffer-payout
  settlement invariant (`payout <= bufferBalanceStable`) depends on this bound

---

# Range & Accrual Invariants

- coverage must only accrue while a position is in range
- out-of-range checkpoints must produce zero accrual delta
- zero dt must produce zero accrual delta
- accrual must always use the current derived range status
- accrual eligibility must be derived from:
  - active position
  - in-range status
  - `dt > 0`
- `checkpoint()` must never bypass range gating
- `afterSwap` must never directly accrue positions
- accrual calculations must never iterate over all LP positions
- `earnedCoverageStable` must remain unchanged while out of range

---

# Settlement Invariants

- `IL_raw` must never be negative
- payout must never exceed `IL_covered`
- payout must never exceed `earnedCoverageStable`
- payout must never exceed `bufferCap`
- payout must never exceed `bufferBalanceStable`
- payout must never exceed the configured payout caps
- positions failing `minHoldSeconds` eligibility must always receive zero payout
- settlement must never modify immutable entry snapshots
- `pendingPayout` must be cleared after settlement
- cleared positions must never retain payout state

---

# Authorization Invariants

- `onlyReactive(poolId)` may emit range transition events
- Reactive contracts must never directly mutate accounting state
- only `config.admin` (per-pool) may call `seedBuffer()`
- only `owner` (contract-level) may call `stagePoolConfig()`
- only `owner` (contract-level) may call `setReactiveContract()`
- only the `authorizedInitializer` designated at staging may trigger the
  `_beforeInitialize` commit by calling `PoolManager.initialize()`
- `setReactiveContract()` may only be called once per pool — `_reactiveSet`
  guard permanently prevents any subsequent change to `reactiveContract[poolId]`
- `PoolConfig` parameters must remain immutable after initialization
- `dynamicFeeBps` must always be derived and never independently stored
- unauthorized actors must never trigger payout execution
- unauthorized actors must never mutate position settlement state
- unauthorized actors must never mutate buffer accounting state

---

# Pool Setup Invariants

These invariants govern the three-phase pool initialization sequence.

## Staging invariants (Phase 1)

- `_pendingSetup[id]` may only be written by `owner`
- `stagePoolConfig()` must reject `authorizedInitializer == address(0)` (`ZeroInitializer`)
- `stagePoolConfig()` must reject `expectedSqrtPriceX96 == 0` (`ZeroSqrtPrice`)
- `stagePoolConfig()` must reject `config.admin == address(0)` (`ZeroAdmin`)
- `stagePoolConfig()` must reject `config.maxPayoutPctOfBuffer > BPS_DENOM` (`InvalidPayoutCaps`)
- `stagePoolConfig()` must reject non-dynamic-fee keys (`NotDynamicFee`)
- `stagePoolConfig()` must reject already-initialized pools (`PoolAlreadyInitialized`)
- re-staging is valid only while `_poolInitialized[id] == false`

## Initialization invariants (Phase 2)

- `_beforeInitialize` must revert if `_pendingSetup[id].exists == false` (`PoolNotStaged`)
- `_beforeInitialize` must revert if `sender != _pendingSetup[id].authorizedInitializer`
  (`UnauthorizedInitializer`)
- `_beforeInitialize` must revert if `sqrtPriceX96 != _pendingSetup[id].expectedSqrtPriceX96`
  (`UnexpectedSqrtPrice`)
- `_poolInitialized[id] == true` must imply `_pendingSetup[id].exists == false`
  (pending setup deleted atomically on commit)
- `_poolInitialized[id] == true` must imply `poolConfig[id].admin != address(0)`
  (config was validly committed)
- `_poolInitialized[id] == true` must imply `poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM`
- pool initialization must be triggered by `authorizedInitializer` at exactly `expectedSqrtPriceX96`

## Reactive registration invariants (Phase 3)

- `setReactiveContract()` must reject `reactive == address(0)` (`ZeroReactive`)
- `setReactiveContract()` must reject calls on uninitialized pools (`PoolNotInitialized`)
- `setReactiveContract()` must reject second calls (`ReactiveAlreadySet`)
- `_reactiveSet[id] == true` must imply `reactiveContract[id] != address(0)`
- `_reactiveSet[id] == true` must imply `_poolInitialized[id] == true`
  (reactive can only be set on an already-initialized pool)
- `_reactiveSet[id]` is monotonically true — once set, it can never return to false

---

# Initialization Invariants

- pools must initialize with `DYNAMIC_FEE_FLAG` enabled (`key.fee == 0x800000`)
- initialized pools must always have valid immutable `PoolConfig`
- partially initialized pools must never exist — `_beforeInitialize` is the
  atomic commit point; if it reverts, the pool is never created in PoolManager
- `PoolConfig` commit must occur exactly once per pool (enforced by `_poolInitialized`
  guard — `stagePoolConfig()` reverts on already-initialized pools)
- `reactiveContract[poolId]` registration occurs in Phase 3 (`setReactiveContract()`),
  NOT during `_beforeInitialize` — `reactiveContract[poolId]` is `address(0)` immediately
  after initialization and before `setReactiveContract()` is called

---

# Lifecycle Invariants

- inactive positions must never accrue coverage
- inactive positions must never checkpoint
- inactive positions must never settle
- cleared positions must never retain payout state
- cleared positions must never retain active status
- pending settlements must never continue accruing coverage
- settlement must always finalize before cleanup
- active positions must always have valid entry snapshots
- active positions must always have initialized accrual state
- positions must never transition directly from Cleared to active
- position registration (`afterAddLiquidity`) requires pool to be initialized
  (`_poolInitialized[id] == true`)

---

# Timing Invariants

- `lastAccrualTime` must monotonically increase
- `dt` must never underflow
- zero `dt` must always produce zero accrual delta
- `checkpoint()` must enforce `minCheckpointInterval`
- accrual calculations must always use `block.timestamp` as the current time reference
- settlement accrual must always occur before payout computation
- `minHoldSeconds` eligibility must always be evaluated before payout computation
- accrual calculations must never use stale range status
- checkpoints must never create overlapping accrual periods
