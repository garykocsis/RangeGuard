# Purpose

This document defines the testing philosophy, coverage goals,
and validation methodology for RangeGuard.

Testing is designed to validate:

- accounting correctness
- lifecycle correctness
- payout correctness
- invariant preservation
- range-gated accrual semantics
- pool setup sequencing and access control
- Reactive Network coordination
- adversarial execution paths

The testing suite should ensure that all protocol invariants remain
preserved across valid execution paths, fuzzed inputs,
and asynchronous state transitions.

# Testing Philosophy

RangeGuard prioritizes:

- deterministic accounting
- explicit lifecycle transitions
- invariant preservation
- range-gated accrual correctness
- predictable settlement behavior
- gas-conscious execution

Testing should focus on:

- correctness first
- adversarial edge cases second
- gas optimization last

All critical accounting paths should have:

- unit coverage
- fuzz coverage
- invariant coverage

Testing infrastructure should prioritize:

- canonical deployment pathways
- reusable setup harnesses
- deterministic environment initialization
- minimal duplicated test setup

# Deployment Testing Pattern

All tests should deploy RangeGuardHook using:

- DeployRangeGuardHook.s.sol
- HelperConfig.s.sol

Tests must avoid ad hoc hook deployment logic unless
explicitly testing deployment failure scenarios.

This ensures:

- hook permission consistency
- deterministic deployment behavior
- CREATE2 consistency
- production-aligned configuration
- consistent hook address derivation

The deployment script should serve as the canonical
deployment pathway for:

- unit tests
- integration tests
- invariant tests
- local development

All test suites should inherit from:

- BaseRangeGuardTest.t.sol

The shared test harness should provide:

- canonical hook deployment
- shared setup logic
- reusable helper functionality
- consistent test initialization

Additional setup logic should extend:

- BaseRangeGuardTest
  via:
- super.setUp()

# Test Categories

## Unit Tests

Validate isolated function correctness:

- `stagePoolConfig()`
- `_beforeInitialize()` commit behavior
- `setReactiveContract()`
- `_accrue()`
- `_computeIL()`
- `_computePayout()`
- PoolConfig validation
- checkpoint interval enforcement
- access control

## Integration Tests

Validate complete protocol flows:

- full pool setup sequence (stagePoolConfig → initialize → setReactiveContract → seedBuffer)
- liquidity lifecycle
- swap interactions
- checkpoint flows
- settlement flows
- range transitions
- Reactive callback coordination

## Invariant Tests

Validate protocol laws remain true under arbitrary execution ordering.

Focus areas:

- pool setup invariants (staged → initialized → reactive registered)
- accounting preservation
- payout caps
- lifecycle correctness
- authorization boundaries
- accrual gating

## Fuzz Tests

Validate protocol correctness under randomized:

- timestamps
- swap amounts
- tick movement
- liquidity ranges
- checkpoint timing
- withdrawal sequencing
- PoolConfig parameter combinations

---

# Pool Setup Function Testing Goals

Pool setup involves three ordered phases. Each phase has its own
access control, validation, and state transition requirements.
Tests for these functions live in `RangeGuardHook.t.sol`.

## stagePoolConfig() (Phase 1)

Tests should validate:

**Access control:**

- reverts when caller is not owner (`NotOwner`)

**Already-initialized guard:**

- reverts when pool is already initialized (`PoolAlreadyInitialized`)

**Zero-value rejections:**

- reverts when `config.admin == address(0)` (`ZeroAdmin`)
- reverts when `authorizedInitializer == address(0)` (`ZeroInitializer`)
- reverts when `expectedSqrtPriceX96 == 0` (`ZeroSqrtPrice`)

**PoolConfig bound validation:**

- reverts on non-dynamic-fee key (`NotDynamicFee`)
- reverts when `baseLpFeeBps > MAX_BASE_FEE_BPS` (`InvalidFeeConfig`)
- reverts when `bufferBps > MAX_BUFFER_BPS` (`InvalidFeeConfig`)
- reverts when `coverageApr == 0` (`InvalidApr`)
- reverts when `coverageApr > MAX_COVERAGE_APR` (`InvalidApr`)
- reverts when `maxPayoutPctOfIl > MAX_PAYOUT_PCT` (`InvalidPayoutCaps`)
- reverts when `maxPayoutPctOfBuffer > BPS_DENOM` (`InvalidPayoutCaps`)
  ← critical: this bound protects the buffer-payout settlement invariant
- reverts when `secondsPerYear` is neither `SECONDS_PER_YEAR_365F`
  nor `SECONDS_PER_YEAR_360` (`UnsupportedDayCount`)

**Success path:**

- valid config stores `_pendingSetup[poolId]` correctly
- `PoolConfigStaged` event emitted with correct parameters
- `authorizedInitializer` and `expectedSqrtPriceX96` stored correctly

**Re-stage behavior:**

- owner may overwrite `_pendingSetup[poolId]` before pool is initialized
- re-staged values replace previous values completely
- re-staging after initialization reverts (`PoolAlreadyInitialized`)

**Fuzz:**

- valid configs across all bound ranges round-trip into `_pendingSetup`
- any out-of-bound parameter value always reverts regardless of other inputs

## setReactiveContract() (Phase 3)

Tests should validate:

**Access control:**

- reverts when caller is not owner (`NotOwner`)

**Ordering guard:**

- reverts when pool is not yet initialized (`PoolNotInitialized`)

**One-time guard:**

- reverts on second call regardless of caller (`ReactiveAlreadySet`)
- `_reactiveSet[poolId]` is true and permanent after first successful call

**Zero-value rejection:**

- reverts when `reactive == address(0)` (`ZeroReactive`)

**Success path:**

- `reactiveContract[poolId]` set to provided address
- `_reactiveSet[poolId]` set to true
- `ReactiveContractSet` event emitted
- `onlyReactive(poolId)` access control functions correctly after registration

---

# \_accrue() Testing Goals

The \_accrue() engine must validate:

- accrual only while in range
- zero dt produces zero accrual
- earnedCoverageStable never decreases
- accrual ceiling enforcement
- correct yearFraction calculation
- correct APR scaling
- proper lastAccrualTime updates
- inactive positions do not accrue
- out-of-range positions accrue zero
- checkpoint ordering correctness

---

# \_computeIL() Testing Goals

The \_computeIL() engine must validate:

- correct spot-price IL calculation
- correct decimal-adjusted price handling
- V_HODL calculation correctness
- V_actual calculation correctness
- IL_raw returns zero when V_actual >= V_HODL
- IL_raw never becomes negative
- deposit edge cases:
  - Case A: 100% token0
  - Case B: mixed deposit
  - Case C: 100% token1
- correct handling of extreme tick values

---

# \_computePayout() Testing Goals

The \_computePayout() engine must validate:

- correct IL cap calculation
- correct buffer cap calculation
- correct payout minimum selection
- payout never exceeds earnedCoverageStable
- payout never exceeds bufferBalanceStable
- payout never exceeds configured payout caps
- correct LimitingFactor selection
- IL_raw == 0 returns:
  - payout = 0
  - LimitingFactor.NONE
- edge cases involving:
  - empty buffer
  - zero earned coverage
  - maximum payout caps

---

# Hook Callback Testing Goals

## beforeInitialize (Phase 2 commit)

Tests should validate:

**PoolManager guard:**

- reverts when called by non-PoolManager address (`onlyPoolManager`)

**Staged config requirement:**

- reverts when no pending setup exists for poolId (`PoolNotStaged`)

**Caller authorization:**

- reverts when `sender != _pendingSetup[poolId].authorizedInitializer`
  (`UnauthorizedInitializer`)
- succeeds when `sender == authorizedInitializer`

**Price integrity:**

- reverts when `sqrtPriceX96 != _pendingSetup[poolId].expectedSqrtPriceX96`
  (`UnexpectedSqrtPrice`)
- succeeds when `sqrtPriceX96 == expectedSqrtPriceX96`

**Dynamic fee validation:**

- reverts when `key.fee != DYNAMIC_FEE_FLAG` (`NotDynamicFee`)

**Success path — commit correctness:**

- `poolConfig[poolId]` populated from staged config
- `_pendingSetup[poolId].exists == false` (deleted on commit)
- `_poolInitialized[poolId] == true`
- `PoolConfigInitialized` event emitted
- correct selector returned

**Reactive state after commit:**

- `reactiveContract[poolId] == address(0)` immediately after init
  (reactive not registered until Phase 3)

**Partial init prevention:**

- if `_beforeInitialize` reverts for any reason, pool is never created
  in PoolManager — no partial state exists

## afterAddLiquidity

Tests should validate:

- correct entryAmt0 and entryAmt1 derivation
- correct entryNotionalStable calculation
- proper PositionState registration
- active flag initialization
- initial \_accrue() call with dt = 0
- correct lastAccrualTime initialization
- PositionRegistered event emission

## beforeSwap

Tests should validate:

- dynamic fee correctly derived as:
  baseLpFeeBps + bufferBps
- no position state mutation occurs
- no accrual logic executes
- returned fee matches PoolConfig values

## afterSwap

Tests should validate:

- correct buffer contribution calculation
- bufferBalanceStable updates correctly
- TickUpdated event emission
- BufferFunded event emission
- no position accrual occurs
- no LP position iteration occurs

## beforeRemoveLiquidity

Tests should validate:

- minHoldSeconds enforcement
- IneligibleClaim behavior
- final \_accrue() execution ordering
- correct \_computeIL() invocation
- correct \_computePayout() invocation
- pendingPayout storage correctness
- AccrualUpdated event emission

## afterRemoveLiquidity

Tests should validate:

- payout transfer execution
- buffer accounting updates
- totalPaidOutStable updates
- PositionState cleanup
- active flag clearing
- pendingPayout clearing
- ClaimSettled / PartialPayout / NoClaim event emission

---

# Invariant Testing Goals

Invariant tests should validate:

**Pool setup invariants:**

- `_poolInitialized[id]` implies `_pendingSetup[id].exists == false`
- `_poolInitialized[id]` implies `poolConfig[id].admin != address(0)`
- `_poolInitialized[id]` implies `poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM`
- `_reactiveSet[id]` implies `reactiveContract[id] != address(0)`
- `_reactiveSet[id]` implies `_poolInitialized[id]`
- `_reactiveSet[id]` is monotonically true (never reverts to false)

**Accounting invariants:**

- earnedCoverageStable never decreases
- inactive positions never accrue
- payout caps always enforced
- immutable snapshots never mutate
- PoolConfig remains immutable after initialization
- afterSwap never iterates LP positions
- Reactive contracts never mutate accounting state
- lifecycle transitions remain valid

---

# Mandatory Edge Cases

Always test:

**Pool setup:**

- pool initialization attempted before staging (`PoolNotStaged`)
- pool initialization by wrong caller (`UnauthorizedInitializer`)
- pool initialization with wrong price (`UnexpectedSqrtPrice`)
- reactive registration before pool initialized (`PoolNotInitialized`)
- reactive registration called twice (`ReactiveAlreadySet`)
- re-staging after pool is initialized (`PoolAlreadyInitialized`)

**Position and accrual:**

- zero dt
- same-block checkpoints
- out-of-range accrual
- minimum hold failures
- maximum APR configuration
- maximum payout caps
- empty buffer conditions
- repeated checkpoint calls
- stale reactive events
- inactive position access

---

# Naming Conventions

## Unit Tests

Pattern:

```
test_Function_WhenCondition_ExpectedBehavior()
```

Examples:

```
test_StagePoolConfig_WhenNotOwner_Reverts()
test_StagePoolConfig_WhenValidConfig_StoresPendingSetup()
test_StagePoolConfig_WhenMaxPayoutPctExceedsDenom_Reverts()
test_BeforeInitialize_WhenPoolNotStaged_Reverts()
test_BeforeInitialize_WhenUnauthorizedInitializer_Reverts()
test_BeforeInitialize_WhenWrongSqrtPrice_Reverts()
test_BeforeInitialize_WhenValid_CommitsConfig()
test_SetReactiveContract_WhenAlreadySet_Reverts()
test_SetReactiveContract_WhenValid_SetsAddress()
test_Accrue_WhenDtZero_DoesNotModifyState()
test_Accrue_WhenInRange_IncreasesCoverage()
test_Accrue_WhenOutOfRange_DoesNotIncreaseCoverage()
```

## Fuzz Tests

Pattern:

```
testFuzz_Function_Property()
```

Examples:

```
testFuzz_StagePoolConfig_ValidConfigAlwaysSucceeds()
testFuzz_StagePoolConfig_InvalidBoundsAlwaysRevert()
testFuzz_Accrue_CoverageNeverDecreases()
testFuzz_Accrue_LargerNotionalProducesMoreCoverage()
```

## Invariant Tests

Pattern:

```
invariant_PropertyName()
```

Examples:

```
invariant_PoolInitializedImpliesPendingSetupDeleted()
invariant_ReactiveSetImpliesInitialized()
invariant_ReactiveSetIsMonotonicallyTrue()
invariant_CoverageNeverDecreases()
invariant_EntrySnapshotsRemainImmutable()
invariant_BufferBalanceNeverNegative()
```

## Integration Tests

Pattern:

```
test_Integration_WhenScenario_ExpectedOutcome()
```

Examples:

```
test_Integration_WhenFullSetupSequence_PoolOperational()
test_Integration_WhenPositionRemoved_ReceivesCoveragePayout()
test_Integration_WhenBufferInsufficient_PayoutIsLimited()
```

---

# Test File Inventory

## Shared Test Harness

- `BaseRangeGuardTest.t.sol`

## Unit Test Suites

- `RangeGuardHook.t.sol` — hook-level tests:
  permissions, `stagePoolConfig`, `_beforeInitialize` commit,
  `setReactiveContract`, `seedBuffer`, access control
- `Accrue.t.sol`
- `ComputeIL.t.sol`
- `ComputePayout.t.sol`

## Invariant Test Suites

Prefer protocol-domain naming:

- `PoolSetupInvariant.t.sol` — pool setup lifecycle invariants
- `CoverageAccountingInvariant.t.sol`
- `SettlementInvariant.t.sol`
- `PositionLifecycleInvariant.t.sol`

Avoid naming invariant suites after individual functions.

## Fuzz Test Suites

- `StagePoolConfigFuzz.t.sol`
- `AccrueFuzz.t.sol`
- `ComputeILFuzz.t.sol`
- `ComputePayoutFuzz.t.sol`

---

# Future Testing Expansion

Future protocol versions should add testing for:

- partial withdrawals
- TWAP/oracle pricing
- volatility-responsive fees
- vault-based buffer custody
- multi-position coordination
- frontend event synchronization
- CREATE2 atomic deployment verification
