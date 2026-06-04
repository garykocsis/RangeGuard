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

- Pool setup functions: stagePoolConfig() + \_beforeInitialize()
  (two-phase bring-up; owner as explicit constructor arg)
- afterAddLiquidity() (register position + dt=0 accrual baseline; owner=sender MVP,
  re-add skip, live entry tick via getSlot0, PositionRegistered)
- beforeSwap() / afterSwap() (derived fee + OVERRIDE_FEE_FLAG; notional buffer funding via
  FEE_DENOM=1e6 v4 pips, BufferFunded + TickUpdated; no accrual, no iteration)
- beforeRemoveLiquidity() / afterRemoveLiquidity() (v4-native settlement: beforeRemove is
  validation-only — active + full-withdrawal gate; afterRemove runs minHold gate -> final
  \_accrue -> \_computeIL (fees-included delta) -> \_computePayout -> strict-CEI payout;
  ClaimSettled/PartialPayout/NoClaim; PositionState dropped pendingPayout, added uint128
  liquidity; re-add reverts PositionAlreadyRegistered; 181 tests passing)

Completed (Phase 2 — continued):

- checkpoint() (permissionless, accrual-only Reactive entry point: \_poolInitialized -> active ->
  minCheckpointInterval (CheckpointTooSoon) gates, \_getCurrentTick + \_accrue, Checkpointed)
- seedBuffer() (admin-only real token1 custody via IERC20Minimal.transferFrom; credits
  bufferBalanceStable only — totalSkimmedStable untouched; BufferSeeded; resolves R2 real-custody
  carry-in; 210 tests passing)

Current implementation target:

- Reactive Network contract

Upcoming implementation order:

1. Reactive Network contract ← current
2. Frontend dashboard

---

# Core Architecture Rules

Pool setup (two-phase pattern — mandatory):

- pool setup follows two ordered phases:
  Phase 1: stagePoolConfig() — onlyOwner, called before PoolManager.initialize()
  Phase 2: \_beforeInitialize() — PoolManager callback, commits staged config atomically
- stagePoolConfig() is external and onlyOwner (NOT internal-only)
- \_beforeInitialize() validates: DYNAMIC_FEE_FLAG, staged config exists, sender ==
  authorizedInitializer, sqrtPriceX96 == expectedSqrtPriceX96 — revert on any failure
- PoolConfig commit is atomic in \_beforeInitialize (Phase 2); Reactive contract
  authorization is via AbstractCallback (authorizedSenderOnly — Callback Proxy); pool never exists
  without valid PoolConfig (PoolNotStaged revert prevents this)
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
- allow PoolManager.initialize() to succeed without a staged config
- allow PoolManager.initialize() from an unauthorized caller or with wrong sqrtPrice
- omit leading address RVM ID placeholder on any Reactive-callable hook function
- omit address(0) as first argument in any Reactive callback payload encoding
- use onlyReactive(poolId) — use authorizedSenderOnly from AbstractCallback instead

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

4. Hook callback implementation ✅
   - afterAddLiquidity() ✅ (register position + dt=0 baseline; re-add reverts PositionAlreadyRegistered)
   - beforeSwap() ✅ (derived fee + OVERRIDE flag; view, no state touched)
   - afterSwap() ✅ (notional buffer funding + TickUpdated; no accrual, no iteration)
   - beforeRemoveLiquidity() ✅ (validation only: active + full-withdrawal gate; view)
   - afterRemoveLiquidity() ✅ (v4-native settlement: minHold gate -> final \_accrue -> \_computeIL
     -> \_computePayout -> strict-CEI payout; ClaimSettled/PartialPayout/NoClaim)

5. checkpoint() ✅ (permissionless accrual driver; Reactive entry point) + seedBuffer() ✅
   (admin-only real token1 custody) — both complete and tested.
   Next: Reactive Network contract (AbstractCallback + authorizedSenderOnly +
   checkpointCallback/checkpointAndEmitOutOfRange/checkpointAndEmitBackInRange)

6. Callback-specific tests

7. End-to-end integration testing

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

Last completed: checkpoint() + seedBuffer() (210 tests passing). See
docs/session-9-checkpoint-seedBuffer-complete.md.
Current target: Reactive Network contract. Two workstreams in this session:

WORKSTREAM 1 — Hook changes (retrofit to existing RangeGuardHook.sol):

- AbstractCallback inheritance: RangeGuardHook inherits BaseHook AND AbstractCallback
- Constructor gains third arg: address \_callbackSender (Callback Proxy)
  constructor(IPoolManager \_manager, address \_owner, address \_callbackSender)
- Remove: reactiveContract[poolId] mapping, \_reactiveSet[poolId] mapping
- Remove: any custom onlyReactive modifier — replaced by authorizedSenderOnly (AbstractCallback)
- afterAddLiquidity: add \_lastRangeEventInRange[poolId][positionKey] initialization
  (true if entryTick in range, false if not)
- afterRemoveLiquidity: emit PositionClosed(poolId, positionKey, owner) on ALL settlement
  paths (after ClaimSettled/NoClaim/IneligibleClaim/PartialPayout)
- New functions:
  checkpointCallback(address /_sender_/, PoolId, bytes32) — permissionless, same gates
  as checkpoint(), RVM ID placeholder first arg
  checkpointAndEmitOutOfRange(address /_sender_/, PoolId, bytes32) — authorizedSenderOnly,
  not rate-limited, atomic: \_accrue + \_lastRangeEventInRange=false + PositionOutOfRange
  guard: revert PositionAlreadyOutOfRange if \_lastRangeEventInRange already false
  checkpointAndEmitBackInRange(address /_sender_/, PoolId, bytes32) — authorizedSenderOnly,
  not rate-limited, atomic: \_accrue + \_lastRangeEventInRange=true + PositionBackInRange
  guard: revert PositionAlreadyInRange if \_lastRangeEventInRange already true
- New state: mapping(PoolId => mapping(bytes32 => bool)) private \_lastRangeEventInRange
- New errors: PositionAlreadyOutOfRange, PositionAlreadyInRange
- New event: PositionClosed(PoolId indexed, bytes32 indexed positionKey, address owner)

WORKSTREAM 2 — RangeGuardReactive.sol (new contract, ReactVM chain):

- Inherits: IReactive, AbstractPausableReactive
- Constructor args: address \_owner, address \_hookAddress, uint256 \_cronTopic
- Subscriptions in constructor (inside if (!vm)):
  service.subscribe(SEPOLIA_CHAIN_ID, hookAddress, POSITION_REGISTERED_TOPIC_0, ...)
  service.subscribe(SEPOLIA_CHAIN_ID, hookAddress, TICK_UPDATED_TOPIC_0, ...)
  service.subscribe(SEPOLIA_CHAIN_ID, hookAddress, POSITION_CLOSED_TOPIC_0, ...)
  service.subscribe(block.chainid, address(service), cronTopic, ...)
- State: mapping(bytes32 => PositionInfo) positions, bytes32[] activeKeys
  struct PositionInfo { PoolId poolId; int24 tickLower; int24 tickUpper;
  bool lastKnownInRange; bool active; uint256 lastCheckpointTime; }
- react(LogRecord calldata log) external vmOnly — routes to four handlers
- Cron10 handler: iterate activeKeys (cap MAX_POSITIONS_PER_CYCLE=20), emit
  Callback per position exceeding minCheckpointInterval
- TickUpdated handler: detect range transitions, emit Callback for
  checkpointAndEmitOutOfRange or checkpointAndEmitBackInRange
- PositionRegistered handler: add to tracking, init lastKnownRangeStatus
- PositionClosed handler: remove from tracking
- CALLBACK_GAS_LIMIT = 300_000; MAX_POSITIONS_PER_CYCLE = 20
- RVM ID placeholder RULE (CRITICAL): address(0) MUST be first arg in every
  abi.encodeWithSignature payload — network overwrites it with ReactVM contract ID

Next up: Frontend dashboard, then demo script.
Notes: Doc-fix pass complete — all docs reconciled with final Reactive design.
Carry-ins: payout recipient = v4 sender (owner=sender MVP).
checkpoint/seedBuffer implementation details preserved from session 9 — see
docs/session-9-checkpoint-seedBuffer-complete.md for full carry-in context.
