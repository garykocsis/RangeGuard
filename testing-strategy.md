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
- settlement atomicity and event semantics
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

All test suites should inherit from:

- BaseRangeGuardTest.t.sol

The shared test harness should provide:

- canonical hook deployment
- shared setup logic
- reusable helper functionality
- consistent test initialization

Additional setup logic should extend BaseRangeGuardTest via super.setUp().

# Test Categories

## Unit Tests

Validate isolated function correctness:

- `stagePoolConfig()`
- `_beforeInitialize()` commit behavior
- `setReactiveContract()`
- `_accrue()`
- `_computeIL()`
- `_computePayout()`
- `_beforeRemoveLiquidity()` (validation only)
- `_afterRemoveLiquidity()` (all settlement logic)
- PoolConfig validation
- checkpoint interval enforcement
- access control

## Integration Tests

Validate complete protocol flows:

- full pool setup sequence (stagePoolConfig → initialize → setReactiveContract → seedBuffer)
- full LP lifecycle (add → checkpoint → warp → remove → ClaimSettled)
- swap interactions and buffer funding
- range transition flows
- Reactive callback coordination

## Invariant Tests

Validate protocol laws remain true under arbitrary execution ordering.

Focus areas:

- pool setup invariants
- accounting preservation
- settlement invariants (buffer conservation, payout caps, real custody)
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

## stagePoolConfig() (Phase 1)

Tests should validate:

- Reverts when caller is not owner (`NotOwner`)
- Reverts when pool is already initialized (`PoolAlreadyInitialized`)
- Reverts when `config.admin == address(0)` (`ZeroAdmin`)
- Reverts when `authorizedInitializer == address(0)` (`ZeroInitializer`)
- Reverts when `expectedSqrtPriceX96 == 0` (`ZeroSqrtPrice`)
- Reverts on non-dynamic-fee key (`NotDynamicFee`)
- Reverts on each invalid bound including `maxPayoutPctOfBuffer > BPS_DENOM`
- Success: `_staged[poolId]` populated, `PoolConfigStaged` emitted
- Re-stage before init: owner overwrites successfully
- Fuzz: valid configs round-trip; out-of-bound values always revert

## setReactiveContract() (Phase 3)

Tests should validate:

- Reverts when caller is not owner (`NotOwner`)
- Reverts when pool not initialized (`PoolNotInitialized`)
- Reverts on second call (`ReactiveAlreadySet`)
- Reverts when `reactive == address(0)` (`ZeroReactive`)
- Success: `reactiveContract[id]` set, `_reactiveSet[id]` true, event emitted

---

# \_accrue() Testing Goals

- accrual only while in range
- zero dt produces zero accrual
- earnedCoverageStable never decreases
- accrual ceiling enforcement
- correct yearFraction and APR scaling
- proper lastAccrualTime updates
- inactive positions do not accrue
- out-of-range positions accrue zero

---

# \_computeIL() Testing Goals

- correct spot-price IL calculation
- correct decimal-adjusted price handling
- V_HODL and V_actual calculation correctness
- IL_raw returns zero when V_actual >= V_HODL
- IL_raw never becomes negative
- all three deposit cases (A: 100% token0, B: mixed, C: 100% token1)
- extreme tick values handled correctly

---

# \_computePayout() Testing Goals

- correct IL cap, buffer cap, coverage cap calculations
- correct payout minimum selection
- payout never exceeds earnedCoverageStable, bufferBalanceStable, or payout caps
- correct LimitingFactor selection
- IL_raw == 0 → payout = 0, LimitingFactor.NONE
- edge cases: empty buffer, zero earned coverage, maximum payout caps

---

# Hook Callback Testing Goals

## beforeInitialize (Phase 2 commit)

- Reverts when called by non-PoolManager
- Reverts when no pending setup (`PoolNotStaged`)
- Reverts when wrong sender (`UnauthorizedInitializer`)
- Reverts when wrong sqrtPrice (`UnexpectedSqrtPrice`)
- Reverts on non-dynamic-fee key (`NotDynamicFee`)
- Success: config committed, pending setup deleted, pool initialized, event emitted
- `reactiveContract[id] == address(0)` after init (Phase 3 not yet run)

## afterAddLiquidity

- Reverts (PositionAlreadyRegistered) on second add to same position key (MVP one-add rule)
- Correct entryAmt0/entryAmt1 derivation from BalanceDelta
- Correct entryNotionalStable calculation (all three deposit cases)
- `pos.liquidity` stored correctly from `params.liquidityDelta`
- `_accrue()` called with dt=0, initializes lastAccrualTime
- PositionRegistered event emitted
- Fuzz: snapshot immutability after registration

## beforeSwap

- Dynamic fee correctly derived as `baseLpFeeBps + bufferBps` with OVERRIDE_FEE_FLAG
- No position state mutation
- Returned fee matches PoolConfig values

## afterSwap

- Buffer contribution calculated using FEE_DENOM (1e6 pips, not BPS_DENOM)
- `bufferBalanceStable` updates correctly
- `BufferFunded` emitted on non-zero contribution
- `TickUpdated` emitted on every swap
- No position accrual; no LP iteration

## beforeRemoveLiquidity (validation only)

- Reverts when position is not active (`PositionNotActive`)
- Reverts when `uint128(-params.liquidityDelta) != pos.liquidity` (`PartialWithdrawalNotSupported`)
- Does NOT mutate accrual state, IL, payout, or buffer state
- Does NOT check minHoldSeconds
- Returns correct selector on valid full withdrawal of active position

## afterRemoveLiquidity (all settlement logic)

**Extraction:**

- Extracts `outAmt0` and `outAmt1` correctly from BalanceDelta (fees included)

**Eligibility gate:**

- Emits `IneligibleClaim` and clears PositionState when `minHoldSeconds` not met
- No accrual, IL, or payout computation when ineligible

**Settlement path:**

- Performs final `_accrue()` before computing payout
- Computes IL using actual `outAmt0`/`outAmt1` from BalanceDelta
- Applies three-cap logic correctly

**Event semantics:**

- `NoClaim` emitted when `IL_raw == 0`
- `ClaimSettled` emitted when `IL_CAP` is binding and `payout > 0`
- `PartialPayout` emitted when `COVERAGE_CAP` or `BUFFER_CAP` is binding
- `PartialPayout(requested=IL_covered, actual=0)` when `IL_raw > 0` but `payout == 0`

**CEI and cleanup:**

- PositionState cleared (active=false) BEFORE payout transfer
- Buffer accounting updated BEFORE payout transfer (strict CEI)
- `bufferBalanceStable` decremented by payout
- `totalPaidOutStable` incremented by payout
- USDC transferred to LP after state is cleared

**Defensive path:**

- No-op return when position not active (before's gate already caught this)

---

# Invariant Testing Goals

**Pool setup:**

- `_poolInitialized[id]` implies pending setup deleted and config live
- `_reactiveSet[id]` implies reactive non-zero and pool initialized
- `_reactiveSet[id]` is monotonically true

**Accounting:**

- earnedCoverageStable never decreases
- inactive positions never accrue
- payout caps always enforced
- immutable snapshots never mutate
- PoolConfig remains immutable after initialization
- afterSwap never iterates LP positions

**Settlement execution:**

- `bufferBalance + totalPaidOut == initial seed` (conservation)
- buffer never grows under settlement-only operations
- real token custody matches ledger payouts

---

# Mandatory Edge Cases

**Pool setup:**

- Init before staging (`PoolNotStaged`)
- Init by wrong caller (`UnauthorizedInitializer`)
- Init with wrong price (`UnexpectedSqrtPrice`)
- Reactive registration before init (`PoolNotInitialized`)
- Reactive registration twice (`ReactiveAlreadySet`)
- Re-staging after initialization (`PoolAlreadyInitialized`)

**Position:**

- Second add to same position key (`PositionAlreadyRegistered`)
- Partial removal attempt (`PartialWithdrawalNotSupported`)
- Removal of inactive position (`PositionNotActive`)
- minHoldSeconds gate: ineligible withdrawal → `IneligibleClaim`, zero payout
- IL_raw == 0 → `NoClaim`
- IL_raw > 0, payout == 0 → `PartialPayout(requested, actual=0)`
- Zero dt accrual
- Same-block checkpoints
- Out-of-range accrual
- Empty buffer conditions
- Maximum APR and payout caps

---

# Naming Conventions

## Unit Tests

```
test_Function_WhenCondition_ExpectedBehavior()
```

Examples:

```
test_StagePoolConfig_WhenNotOwner_Reverts()
test_BeforeInitialize_WhenPoolNotStaged_Reverts()
test_BeforeInitialize_WhenValid_CommitsConfig()
test_SetReactiveContract_WhenAlreadySet_Reverts()
test_AfterAddLiquidity_WhenPositionExists_RevertsAlreadyRegistered()
test_BeforeRemoveLiquidity_WhenInactive_RevertsPositionNotActive()
test_BeforeRemoveLiquidity_WhenPartial_RevertsPartialWithdrawal()
test_BeforeRemoveLiquidity_WhenValid_MutatesNoState()
test_AfterRemoveLiquidity_WhenIneligible_EmitsIneligibleClaim()
test_AfterRemoveLiquidity_WhenILZero_EmitsNoClaim()
test_AfterRemoveLiquidity_WhenILCap_EmitsClaimSettled()
test_AfterRemoveLiquidity_WhenCoverageCap_EmitsPartialPayout()
test_Accrue_WhenDtZero_DoesNotModifyState()
test_Accrue_WhenInRange_IncreasesCoverage()
```

## Fuzz Tests

```
testFuzz_Function_Property()
```

## Invariant Tests

```
invariant_PropertyName()
```

Examples:

```
invariant_PoolInitializedImpliesPendingSetupDeleted()
invariant_ReactiveSetImpliesInitialized()
invariant_CoverageNeverDecreases()
invariant_BufferConservedAcrossSettlements()
invariant_EntrySnapshotsRemainImmutable()
invariant_BufferBalanceNeverNegative()
```

## Integration Tests

```
test_Integration_WhenScenario_ExpectedOutcome()
```

---

# Test File Inventory

## Shared Test Harness

- `BaseRangeGuardTest.t.sol`

## Unit Test Suites

- `RangeGuardHook.t.sol` — setup functions, access control
- `Accrue.t.sol`
- `ComputeIL.t.sol`
- `ComputePayout.t.sol`
- `AfterAddLiquidity.t.sol`
- `BeforeSwap.t.sol`
- `AfterSwap.t.sol`
- `BeforeRemoveLiquidity.t.sol`
- `AfterRemoveLiquidity.t.sol`

## Invariant Test Suites

- `PoolSetupInvariant.t.sol`
- `CoverageAccountingInvariant.t.sol`
- `SettlementInvariant.t.sol`
- `SettlementExecutionInvariant.t.sol`
- `PositionLifecycleInvariant.t.sol`
- `BufferFundingInvariant.t.sol`

## Fuzz Test Suites

- `StagePoolConfigFuzz.t.sol`
- `AccrueFuzz.t.sol`
- `ComputeILFuzz.t.sol`
- `ComputePayoutFuzz.t.sol`
- `AfterAddLiquidityFuzz.t.sol`
- `BeforeSwapFuzz.t.sol`
- `AfterSwapFuzz.t.sol`
- `AfterRemoveLiquidityFuzz.t.sol`

## Integration Test Suites

- `PoolSetup.t.sol`
- `AfterAddLiquidity.t.sol`
- `Swap.t.sol`
- `RemoveLiquidity.t.sol`

# Future Testing Expansion

Future protocol versions should add testing for:

- partial withdrawals
- TWAP/oracle pricing
- volatility-responsive fees
- vault-based buffer custody
- multi-position coordination
- CREATE2 atomic deployment verification
