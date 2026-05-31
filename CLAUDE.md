# CLAUDE.md

# RangeGuard Development Guidelines

RangeGuard is a Uniswap v4 hook providing native LP impermanent loss
coverage funded through dynamic fee skimming.

This repository follows a spec-driven development workflow.

Authoritative documents:

- spec.md
- context.md
- state-machine.md
- invariant-mapping.md
- testing-strategy.md
- project-status.md

Claude must treat these files as canonical sources of truth.

---

# Current Implementation Status

Completed (Phase 1):

- Foundry scaffold
- hook skeleton
- getHookPermissions()
- deployment script
- documentation architecture
- \_accrue()
- \_computeIL()
- \_computePayout()

Completed (Phase 2 — hook callbacks):

- Pool setup functions: stagePoolConfig() + \_beforeInitialize() + setReactiveContract()
  (three-phase bring-up; owner as explicit constructor arg)
- afterAddLiquidity() (register position + dt=0 accrual baseline; owner=sender MVP,
  re-add skip, live entry tick via getSlot0, PositionRegistered; 140 tests passing)

Current implementation target:

- beforeSwap() / afterSwap()

Upcoming implementation order:

1. beforeSwap() / afterSwap() ← current
2. beforeRemoveLiquidity() / afterRemoveLiquidity()
3. checkpoint()
4. Reactive Network contract
5. Frontend dashboard

---

# Core Architecture Rules

Pool setup (three-phase pattern — mandatory):

- pool setup follows three ordered phases:
  Phase 1: stagePoolConfig() — onlyOwner, called before PoolManager.initialize()
  Phase 2: \_beforeInitialize() — PoolManager callback, commits staged config atomically
  Phase 3: setReactiveContract() — onlyOwner, one-time, called after reactive deployment
- stagePoolConfig() is external and onlyOwner (NOT internal-only)
- \_beforeInitialize() validates: DYNAMIC_FEE_FLAG, staged config exists, sender ==
  authorizedInitializer, sqrtPriceX96 == expectedSqrtPriceX96 — revert on any failure
- PoolConfig is committed atomically inside \_beforeInitialize(); pool never exists
  without valid PoolConfig (PoolNotStaged revert prevents this)
- setReactiveContract() is one-time only — \_reactiveSet guard permanently locks
  reactiveContract[poolId] after initial registration
- pools must initialize with DYNAMIC_FEE_FLAG enabled
- DYNAMIC_FEE_FLAG enforcement is mandatory at both stagePoolConfig() and \_beforeInitialize()
- pools must never exist without valid immutable PoolConfig

Accounting rules:

- afterSwap must never iterate all LP positions
- accrual is always lazy
- afterSwap must never directly accrue positions
- PoolConfig is immutable after initialization
- dynamicFeeBps is always derived and never stored
- Reactive contracts must never mutate accounting state
- settlement ordering must follow:
  final \_accrue() -> \_computeIL() -> \_computePayout()
- immutable snapshots must never mutate after registration

---

# Solidity Development Standards

- Use Solidity >=0.8.x safety guarantees
- Prefer custom errors over revert strings
- Use explicit visibility on all functions and state variables
- Use CEI (Checks-Effects-Interactions) ordering
- Use storage pointers carefully and explicitly
- Minimize storage writes whenever possible
- Avoid unnecessary memory allocation
- Use uint256 unless smaller packing provides meaningful benefit
- Use NatSpec comments for all external/public functions
- Keep functions focused and single-responsibility
- Avoid duplicated accounting logic
- Prefix immutable variables with i\_ example i_manager
- Constants should be all upper case

---

# Additional Solidity Standards

Ensure sections are in this order:
Pragma statements
Import statements
Events
Errors
Interfaces
Libraries
Contracts

Inside each contract, library or interface, use the following order:
Type declarations
State variables
Events
Errors
Modifiers
Functions

Place functions in this order:
Constructor
Fallback
Receive
External
Public
Internal
Private

For section headers use the following format:

```
    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/
```

---

# Hook Architecture Expectations

Internal accounting engines:

- \_accrue()
- \_computeIL()
- \_computePayout()

Hook callbacks should orchestrate lifecycle flow only.

Callbacks must:

- remain lightweight
- preserve invariants
- avoid hidden side effects
- emit deterministic events

beforeSwap:

- derive fee only
- no accrual
- no position mutation

afterSwap:

- buffer accounting only
- emit TickUpdated
- never iterate LP positions

---

# Testing Requirements

- all test suites should inherit from BaseRangeGuardTest.t.sol
- reuse canonical deployment flow from DeployRangeGuardHook.s.sol
- avoid duplicating deployment/setup logic in test contracts

All accounting logic changes require:

- unit tests
- fuzz tests
- invariant tests

Critical lifecycle flows require:

- integration tests

Generated tests should follow naming conventions in:

- testing-strategy.md

All implementations must preserve:

- invariant-mapping.md
- state-machine.md

---

# Gas & Performance Constraints

Optimize for:

- predictable execution
- bounded complexity
- minimal storage writes
- no unbounded iteration
- deterministic callback execution

Never introduce:

- O(N) LP iteration
- dynamic array scans in swap paths
- unnecessary external calls

---

# Forbidden Patterns

Never:

- mutate immutable snapshots
- bypass minHoldSeconds eligibility
- store dynamicFeeBps independently
- accrue while out of range
- allow inactive positions to accrue
- allow settlement without final accrual
- bypass payout caps
- duplicate accrual logic across callbacks
- mutate accounting state from Reactive contracts
- treat stagePoolConfig() as internal-only (it is external, onlyOwner)
- call setReactiveContract() more than once per pool
- allow PoolManager.initialize() to succeed without a staged config
- allow PoolManager.initialize() from an unauthorized caller or with wrong sqrtPrice

---

# Development Workflow

Implementation order:

1. implement function
2. generate unit tests
3. generate fuzz tests
4. generate invariant tests
5. run forge test
6. optimize gas only after correctness

Correctness and invariant preservation take priority over optimization.

Do not introduce architectural changes without updating:

- spec.md
- state-machine.md
- invariant-mapping.md
- testing-strategy.md

---

# Implementation Order (Mandatory)

1. Core accounting primitives ✅
   - \_accrue()
   - \_computeIL()
   - \_computePayout()

2. Unit, fuzz, and invariant testing for each primitive ✅

3. Hook pool setup functions ✅
   - stagePoolConfig() — Phase 1: external, onlyOwner, validates and stages config
   - \_beforeInitialize() — Phase 2: PoolManager callback, validates + commits staged config
   - setReactiveContract() — Phase 3: external, onlyOwner, one-time reactive registration

4. Hook callback implementation (current)
   - afterAddLiquidity() ✅ (register position + dt=0 baseline)
   - beforeSwap() ← current
   - afterSwap()
   - beforeRemoveLiquidity()
   - afterRemoveLiquidity()

5. Callback-specific tests

6. End-to-end integration testing

Do not begin implementation of a later phase until the current phase is complete and tested.

---

# Build & Test Commands

- Build: forge build
- Test single: forge test --match-test testFunctionName -vvv
- Test file: forge test --match-path test/YourTest.t.sol -vvv
- Fuzz tests: forge test --match-test testFuzz -vvv
- Invariant tests: forge test --match-test invariant -vvv
- Coverage: forge coverage
- Gas snapshot: forge snapshot

---

# Session Startup Protocol

At the start of every session, Claude must:

1. Read spec.md, context.md, state-machine.md, invariant-mapping.md
2. Read project-status.md to understand current implementation state
3. Read the current hook contract in src/
4. Confirm current implementation target before writing any code

---

# Current Session State

Last completed: afterAddLiquidity() — position registration + dt=0 accrual baseline
(140 tests passing). See docs/session-6-afterAddLiquidity-complete.md.
Current target: beforeSwap() (return derived dynamic fee), then afterSwap() (buffer
funding + TickUpdated; no accrual, no position iteration).
Next up: beforeRemoveLiquidity() / afterRemoveLiquidity()
Notes: afterAddLiquidity uses owner=sender (the v4 router/caller, MVP limitation — production
should attribute the real LP); skips re-registration on an active position to keep the entry
snapshot immutable; reads the live entry tick via getSlot0 (StateLibrary); writes the snapshot
with lastAccrualTime=now BEFORE the baseline \_accrue() so dt=0. Stack-too-deep avoided by
scoping intermediates + a \_emitPositionRegistered helper (repo keeps via_ir=false). Carry-in:
\_computeIL sequencing in beforeRemoveLiquidity (v4 out-amounts known only after removal).
