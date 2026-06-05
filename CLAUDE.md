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
  carry-in)

Completed (Phase 3B — Reactive Network):

- RangeGuardHook retrofit (BaseHook + AbstractCallback, authorizedSenderOnly; 3-arg ctor with
  \_callbackSender; checkpointCallback / checkpointAndEmitOutOfRange / checkpointAndEmitBackInRange;
  \_lastRangeEventInRange guard; PositionClosed / PositionOutOfRange / PositionBackInRange;
  reactiveContract/setReactiveContract removed)
- RangeGuardReactive.sol (AbstractPausableReactive on ReactVM; 4 subscriptions; react() routing;
  four handlers; pausable Cron-only; hookChainId-parameterized destination chain; 4-arg ctor)
- reactive-lib v0.2.0 + remappings.txt; DeployRangeGuardReactive.s.sol; 278 tests passing

Completed (Phase 3B — continued, Session 11):

- Sepolia HOOK deployment: hook 0x50cd0E7e046022a9B359ca8725aCb75748FB67C0 live; MockUSDC token1
  0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA (6-dec, permissionless mint, TESTNET ONLY);
  ETH/USDC pool initialized (PoolId 0xe531d420…f2b81cb) at sqrtPriceX96 3543191142285914205922034
  ($2,000/ETH), DYNAMIC_FEE_FLAG, tickSpacing 60; buffer seeded 10,000 USDC real custody (verified).
  New artifacts: src/mocks/MockUSDC.sol, script/DeployMockUSDC.s.sol, script/StageInitSeedPool.s.sol,
  HelperConfig getStableToken()/MOCK_USDC_SEPOLIA. See docs/session-11-sepolia-deployment.md.

Current implementation target:

- ReactVM (reactive) deployment, then demo script

Upcoming implementation order:

1. Sepolia hook deployment ✅ (Session 11 — hook live, pool seeded)
2. ReactVM (reactive) deployment ← current (confirm Cron topic + rGas + Callback Proxy first)
3. Demo script (RangeGuardDemo.s.sol)
4. Frontend dashboard

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

6. Reactive Network contract ✅ — RangeGuardHook AbstractCallback retrofit (authorizedSenderOnly;
   checkpointCallback / checkpointAndEmitOutOfRange / checkpointAndEmitBackInRange;
   \_lastRangeEventInRange guard; PositionClosed/OutOfRange/BackInRange) + RangeGuardReactive.sol
   (AbstractPausableReactive on ReactVM; hookChainId-parameterized; reactive-lib v0.2.0).
   Next: Sepolia/ReactVM deployment, then demo script, then frontend dashboard.

7. Callback-specific + reactive tests ✅ (278 passing)

8. End-to-end integration testing ✅ (CoverageAccrualLifecycle closes the in→out→in arc)

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

Last completed (Session 11): First live Ethereum Sepolia HOOK deployment — MockUSDC → hook →
pool staged → initialized → buffer seeded, all verified on-chain. Hook
0x50cd0E7e046022a9B359ca8725aCb75748FB67C0; MockUSDC 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;
PoolId 0xe531d42027094e6563d0838d0fe1c8705172d4feed0e6a5f48a08ca97f2b81cb; owner/admin
0x193D1F3E085efc80e1027891FaA770E81ECC4A1d. Buffer = 10,000 USDC real custody. No production hook
source changed (new testnet mock + 2 deploy scripts + HelperConfig getter only). 278 tests passing.
See docs/session-11-sepolia-deployment.md.
Current target: ReactVM (reactive) deployment, then demo script.

Delivered this session:

- RangeGuardHook: BaseHook + AbstractCallback (authorizedSenderOnly = Callback Proxy 0x..fffFfF);
  3-arg constructor (IPoolManager, owner, \_callbackSender); checkpointCallback /
  checkpointAndEmitOutOfRange / checkpointAndEmitBackInRange (leading ignored RVM-ID placeholder);
  \_lastRangeEventInRange alternation guard (init in afterAddLiquidity); PositionClosed /
  PositionOutOfRange / PositionBackInRange events; PositionAlreadyOutOfRange/InRange errors;
  reactiveContract / \_reactiveSet / setReactiveContract removed.
- RangeGuardReactive.sol: AbstractPausableReactive on ReactVM; constructor
  (address \_hookAddress, uint256 \_hookChainId, uint256 \_cronTopic, uint256 \_minCheckpointInterval)
  payable; four if(!vm) subscriptions; react() vmOnly routes by source (service → heartbeat,
  else topic0); four handlers; getPausableSubscriptions returns Cron only; activeKeys swap-and-pop;
  MAX_POSITIONS_PER_CYCLE=20; CALLBACK_GAS_LIMIT=300_000; address(0) first arg in every payload.
- Infra: reactive-lib v0.2.0 (remappings.txt: reactive-lib/=lib/reactive-lib/);
  DeployRangeGuardReactive.s.sol (ReactVM, env-driven, dry-run verified);
  RangeGuardReactiveHarness + MockSystemContract + ReactiveTestBase.

Mid-session deviations (authorized):

- hookChainId: the reactive constructor is 4-arg (host chain parameterized as the subscription
  source + callback destination), NOT the originally locked 3-arg. spec.md + reactiveSpec.md
  reconciled.
- Testability: \_lastRangeEventInRange and the three topic0 constants are internal (spec said
  private) so the harness can assert them; RangeGuardReactive uses MIT / pragma 0.8.26.

Next up: Sepolia deployment (hook → Sepolia, Reactive → ReactVM; deploy scripts ready) → demo
script → frontend dashboard.
Carry-ins: payout recipient = v4 sender (owner=sender MVP). Before deploying, confirm the Cron
topic value, rGas funding amount, and the Callback Proxy address on the target network
(reactiveSpec §18.3 / §18.7 / §18.9).
