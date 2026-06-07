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
  (NOTE: superseded in Session 12 — migrated to reactive-lib-omni v0.1.0; see Current Session State)

Completed (Phase 3B — continued, Session 11; HOOK SUPERSEDED by the Session-12 Lasna redeploy):

- Sepolia HOOK deployment: hook 0x50cd0E7e046022a9B359ca8725aCb75748FB67C0 live; MockUSDC token1
  0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA (6-dec, permissionless mint, TESTNET ONLY);
  ETH/USDC pool initialized (PoolId 0xe531d420…f2b81cb) at sqrtPriceX96 3543191142285914205922034
  ($2,000/ETH), DYNAMIC_FEE_FLAG, tickSpacing 60; buffer seeded 10,000 USDC real custody (verified).
  New artifacts: src/mocks/MockUSDC.sol, script/DeployMockUSDC.s.sol, script/StageInitSeedPool.s.sol,
  HelperConfig getStableToken()/MOCK_USDC_SEPOLIA. See docs/session-11-sepolia-deployment.md.
  (Session 12 redeployed the hook for Lasna as 0xFead…a7C0 with the new Sepolia callback proxy;
  MockUSDC was reused. The 0x50cd… hook is no longer the active deployment.)

Current implementation target:

- Demo script (RangeGuardDemo.s.sol) — drive the live Sepolia pool end-to-end, then frontend dashboard

Upcoming implementation order:

1. Sepolia hook deployment ✅ (Session 11; REDEPLOYED for Lasna in Session 12 — new hook 0xFead…a7C0)
2. ReactVM (reactive) deployment ✅ (Session 12 — Reactive Lasna 0xC0e6…B70b, live + wired + verified)
3. Demo script (RangeGuardDemo.s.sol) ← current
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

Last completed (Session 12): reactive-lib → reactive-lib-omni (Omni fork) migration + first live
ReactVM deployment on Reactive Lasna. The whole reactive stack is live and verified; the only
remaining piece is the demo script (LP-deposit + swap tooling) to drive the round-trip end-to-end.

Library migration (reactive-lib v0.2.0 → reactive-lib-omni v0.1.0):

- onlyServiceProvider (was authorizedSenderOnly); SYSTEM.requestCallbackV_1_0 (was emit Callback);
  SYSTEM 0x8888…8888 (was service 0x…fffFfF); camelCase LogRecord (contractAddress, topic0…3);
  AbstractCallback ctor now (IPayable, address); local AbstractPausableReactive port at src/base/
  (the lib REMOVED the upstream one), restoring vm / vmOnly / rnOnly / Subscription.
- solc stays 0.8.26 (NOT bumped): v4-core PoolManager pins exact 0.8.26, so reactive-lib-omni's 8
  files were relaxed ^0.8.29→^0.8.26 (it uses no 0.8.27+ features). reactive-lib-omni is **vendored**
  (src committed directly into lib/, NOT a git submodule — same as forge-std/v4-hooks-public), so
  these pragma edits persist on a fresh clone; `forge build`/`test` works with no submodule init.
  See lib/reactive-lib-omni/VENDORED.md (re-apply sed only matters if re-vendoring from upstream).
- Tests: 278 passing, 0 failing (harness etches MockSystemContract at 0x8888 AFTER construction +
  re-emits Callback; 3 hook auth tests now expect the NotAuthorized custom error).

Live deployment (Session 12):

- HOOK REDEPLOYED for Lasna. The Omni fork changed the Sepolia callback proxy to
  0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA; the live 0x50cd… hook authorizes the legacy 0x…fffFfF
  and its auth is IMMUTABLE, so it could not accept Lasna callbacks. New hook
  0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0 (CALLBACK_SENDER updated in DeployRangeGuardHook.s.sol);
  new PoolId 0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a; MockUSDC reused
  0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA; buffer re-seeded 10,000 USDC. Old 0x50cd… SUPERSEDED.
- REACTIVE CONTRACT LIVE on Reactive Lasna (chainId 5318007; RPC https://lasna-omni-rpc.rnk.dev/;
  explorer https://lasna-omni.reactscan.net/): 0xC0e6b70c8FF75962541183fdc247E7B07AD6B70b (tx
  0xed865d580eef19d972436d4e9c9cce40b7359ef393dd3967c9a280e8a22f5329), funded 0.05 lREACT, wired to
  the new hook (hookChainId 11155111, Cron10, minCheckpointInterval 120). Verified by RPC reads.
  owner/admin 0x193D1F3E085efc80e1027891FaA770E81ECC4A1d.
- rGas is per-CALLBACK (300k gas); a no-op heartbeat with 0 positions spends nothing (verified on
  chain). pause()/resume() are owner-only on the Lasna RPC; read pause state from storage slot 0
  byte 21. Lasna ≠ pre-Omni Lasna: both report chainId 5318007 but are separate ledgers — use the
  -omni RPC/explorer.

Docs reconciled this session: spec.md, reactiveSpec.md, project-status.md, context.md, CLAUDE.md,
testing-strategy.md, invariant-mapping.md (state-machine.md reviewed — no change needed). Audit:
docs/reactive-lib-omni-audit.md. Session record: docs/session-12-reactive-deployment.md.

NOT done: Phase-7 end-to-end (LP deposit → swap → PositionTracked → Checkpointed) — needs the demo
script (RangeGuardDemo.s.sol). No live LP-deposit/swap tooling exists yet for the Sepolia pool.

Current target: Demo script (RangeGuardDemo.s.sol), then frontend dashboard.
Carry-ins: payout recipient = v4 sender (owner=sender MVP). The Callback Proxy is PER NETWORK under
Omni — for any future host chain confirm it at dev.reactive.network/origins-and-destinations before
deploying the hook (it is NOT the legacy 0x…fffFfF).

Session 13 carry-ins (live-demo blockers found + fixed):
1. REACTIVE react() vmOnly BUG: the local AbstractPausableReactive port detected the ReactVM via
   `vm = extcodesize(0x8888)==0`. On Lasna Omni's unified CometBFT EVM the system contract 0x8888
   exists in EVERY context, so vm is ALWAYS false and react()'s `vmOnly` reverted "VM only" on every
   delivered event — the reactive could process nothing. FIX: react() now uses `onlySystem`
   (msg.sender == SYSTEM 0x8888), the upstream Omni guard. Redeployed reactive
   0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1 on Lasna; OLD 0xC0e6… is SUPERSEDED + paused.
2. CALLBACK DELIVERY needs a PROXY RESERVE (the big gotcha): reactive callbacks dispatch on Lasna
   (lREACT spent) but only LAND on the Sepolia hook if the hook holds a reserve on the host-chain
   Callback Proxy (0xc9f3…7bDA). The proxy uses a reserve/depositTo model — funding the hook's raw
   balance does NOTHING. Symptom of the gap: reserves(hook)=0, debt=0, no Sepolia tx, no revert
   trace. FIX/STEP (MANDATORY after any hook redeploy): `make fund-hook-proxy`
   (proxy.depositTo{0.05 ETH}(hook)); verify `make reserves-hook`. The hook already inherits
   AbstractPayer (pay()) and all reactive-callable fns take the leading RVM-id address placeholder,
   so neither of those was the issue — only the reserve.
