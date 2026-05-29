# Purpose

This document defines the testing philosophy, coverage goals,
and validation methodology for RangeGuard.

Testing is designed to validate:

- accounting correctness
- lifecycle correctness
- payout correctness
- invariant preservation
- range-gated accrual semantics
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

- \_accrue()
- \_computeIL()
- \_computePayout()
- PoolConfig validation
- checkpoint interval enforcement
- access control

## Integration Tests

Validate complete protocol flows:

- liquidity lifecycle
- swap interactions
- checkpoint flows
- settlement flows
- range transitions
- Reactive callback coordination

## Invariant Tests

Validate protocol laws remain true under arbitrary execution ordering.

Focus areas:

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

# Hook Callback Testing Goals

## beforeInitialize

Tests should validate:

- initialization reverts if DYNAMIC_FEE_FLAG is not enabled
- valid PoolConfig initializes successfully
- invalid PoolConfig bounds revert
- hookData decoding succeeds correctly
- initializePoolConfig() cannot be externally called
- pool initialization occurs exactly once
- reactiveContract registers correctly
- partially initialized pools cannot exist

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

# Invariant Testing Goals

Invariant tests should validate:

- earnedCoverageStable never decreases
- inactive positions never accrue
- payout caps always enforced
- immutable snapshots never mutate
- PoolConfig remains immutable
- afterSwap never iterates LP positions
- Reactive contracts never mutate accounting state
- lifecycle transitions remain valid

# Mandatory Edge Cases

Always test:

- zero dt
- same-block checkpoints
- out-of-range accrual
- minimum hold failures
- maximum APR configuration
- maximum payout caps
- empty buffer conditions
- repeated checkpoint calls
- stale reactive events
- invalid pool initialization
- inactive position access

# Naming Conventions

## Unit Tests

Pattern:

test_Function_WhenCondition_ExpectedBehavior()

Examples:

- test_Accrue_WhenDtZero_DoesNotModifyState()
- test_Accrue_WhenInRange_IncreasesCoverage()
- test_Accrue_WhenOutOfRange_DoesNotIncreaseCoverage()

## Fuzz Tests

Pattern:

testFuzz_Function_Property()

Examples:

- testFuzz_Accrue_CoverageNeverDecreases()
- testFuzz_Accrue_LargerNotionalProducesMoreCoverage()

## Invariant Tests

Pattern:

invariant_PropertyName()

Examples:

- invariant_CoverageNeverDecreases()
- invariant_EntrySnapshotsRemainImmutable()
- invariant_BufferBalanceNeverNegative()

## Integration Tests

Pattern:

test_Integration_WhenScenario_ExpectedOutcome()

Examples:

- test_Integration_WhenPositionRemoved_ReceivesCoveragePayout()
- test_Integration_WhenBufferInsufficient_PayoutIsLimited()

## Shared Test Harness

- BaseRangeGuardTest.t.sol

## Unit Test Suites

- Accrue.t.sol
- ComputeIL.t.sol
- ComputePayout.t.sol

## Invariant Test Suites

Prefer protocol-domain naming:

- CoverageAccountingInvariant.t.sol
- SettlementInvariant.t.sol
- PositionLifecycleInvariant.t.sol

Avoid naming invariant suites after individual functions.

## Fuzz Test Suites

- AccrueFuzz.t.sol
- ComputeILFuzz.t.sol
- ComputePayoutFuzz.t.sol

# Future Testing Expansion

Future protocol versions should add testing for:

- partial withdrawals
- TWAP/oracle pricing
- volatility-responsive fees
- vault-based buffer custody
- multi-position coordination
- frontend event synchronization
