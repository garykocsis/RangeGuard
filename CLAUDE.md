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

Completed:

- Foundry scaffold
- hook skeleton
- getHookPermissions()
- deployment script
- documentation architecture

Current implementation target:

- \_accrue()

Upcoming implementation order:

1. \_accrue()
2. \_computeIL()
3. \_computePayout()
4. hook callback wiring
5. checkpoint()
6. Reactive Network contract
7. frontend dashboard

---

# Core Architecture Rules

- pools must initialize with DYNAMIC_FEE_FLAG enabled
- DYNAMIC_FEE_FLAG enforcement is mandatory
- pools must initialize atomically during beforeInitialize()
- PoolConfig initialization is internal-only
- pools must never exist without valid immutable PoolConfig
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

---

# Additional Solidity standards

Ensure sections are in this order  
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
Place functions in this order  
Constructor
Fallback
Receive
External
Public
Internal
Private

For section header use the following for an example

```
    /*//////////////////////////////////////////////////////////////
                                 Header description
    //////////////////////////////////////////////////////////////*/
```

Replace header description with the actual description - for example EVENTS

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

# Implementation Order (Mandatory)

1. Core accounting primitives
   - \_accrue()
   - \_computeIL()
   - \_computePayout()

2. Unit, fuzz, and invariant testing for each primitive

3. Hook callback implementation
   - beforeInitialize()
   - afterAddLiquidity()
   - beforeSwap()
   - afterSwap()
   - beforeRemoveLiquidity()
   - afterRemoveLiquidity()

4. Callback-specific tests

5. End-to-end integration testing

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

Last completed: getHookPermissions()
Current target: \_accrue()
Next up: \_computeIL()
Notes: [update this before ending each session]
