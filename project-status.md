RangeGuard Project Status
Last Updated: 2026-06-05 (Session 12 — reactive-lib-omni migration + ReactVM deployment on Lasna)
How to use this file

The Roadmap is the single source of truth for progress — one checkbox per item.
Now holds the active target plus its granular impl/unit/fuzz/invariant sub-status.
Only the in-progress item is tracked at that granularity here.
Completed items collapse to one line and link to a docs/ session doc for detail,
instead of repeating per-item checklists.
Each session: update Now, tick the Roadmap, refresh the date. Do not duplicate
status across sections.
Per-function build order (mandatory, per CLAUDE.md): implement -> unit -> fuzz ->
invariant; correctness before gas.

Now

Active target: Frontend dashboard (coverage report rendered from Sepolia events). The demo tooling is
complete (Session 13): 14 Sepolia fork tests + RangeGuardDemo.s.sol (Option A) + LiveEndToEnd/
LiveWithdraw (Option B) + DemoLPRouter. The frontend should query the live demo positionKey
0x62e2311b3a51692f0f8ce68f4cd03882e163b37aa357431ad14a4f5b41462d88 (hook 0xFead…a7C0) and render
PositionRegistered → AccrualUpdated → settlement from on-chain events.

Just completed (Session 13): demo scripts + live end-to-end, and TWO Reactive Omni-fork blockers found
+ fixed:
- REACTIVE redeploy: the Session-12 reactive 0xC0e6…B70b used the pre-Omni vmOnly ReactVM detection
  (vm = extcodesize(0x8888)==0), which is permanently false on Lasna Omni → react() reverted "VM only"
  on every event. Fixed react() → onlySystem (caller==SYSTEM); redeployed reactive
  0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1 (0.1 lREACT); old 0xC0e6… paused/superseded. 278 tests pass.
- CALLBACK DELIVERY needs a PROXY RESERVE: callbacks dispatch on Lasna (lREACT spent) but only land on
  Sepolia if the hook holds a reserve on the Callback Proxy (proxy.depositTo, NOT the hook's raw
  balance). Added make fund-hook-proxy. Live reserve funded (reserves(hook)=0.05).
- LIVE round-trip: hook lifecycle broadcast on Sepolia; reactive react() proven (tracked the position,
  flipped lastKnownInRange in BOTH directions, dispatched callbacks). The callback LANDING on Sepolia
  was blocked by a transient Lasna→Sepolia observation stall (after block ~11005952) — a testnet infra
  issue, not the contracts. Live withdrawal settled: PartialPayout/COVERAGE_CAP (tx 0x3dbc8b66…).
- New artifacts: src/demo/DemoLPRouter.sol (0xEA30…1FEa on Sepolia), script/RangeGuardDemo.s.sol,
  script/LiveEndToEnd.s.sol, script/LiveWithdraw.s.sol, test/integration/sepolia/* (14 tests),
  Makefile fund-hook-proxy/reserves-hook.
-> docs/session-13-demo-script.md, docs/reactive-evidence.md, docs/demo-run-output.md, docs/demo-narrative.md

Just completed (Session 12): reactive-lib → reactive-lib-omni (Omni fork) migration + first live
ReactVM deployment on Reactive Lasna.
- LIBRARY: removed reactive-lib v0.2.0, installed reactive-lib-omni v0.1.0. API rewrite handled —
  onlyServiceProvider (was authorizedSenderOnly), SYSTEM.requestCallbackV_1_0 (was emit Callback),
  SYSTEM 0x8888…8888 (was service 0x…fffFfF), camelCase LogRecord, local AbstractPausableReactive
  port at src/base/ (the lib removed the upstream one). solc stays 0.8.26 (lib pragma relaxed
  ^0.8.29→^0.8.26; v4-core PoolManager pins 0.8.26). 278 tests passing, 0 failing.
- HOOK REDEPLOYED for Lasna: the Omni fork changed the Sepolia callback proxy to
  0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA, and the live 0x50cd… hook's auth is immutable, so it
  could not accept Lasna callbacks. New hook 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0; new PoolId
  0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a; MockUSDC reused
  0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA; buffer re-seeded 10,000 USDC. The old 0x50cd… hook is
  SUPERSEDED.
- REACTIVE CONTRACT LIVE on Reactive Lasna (chainId 5318007):
  0xC0e6b70c8FF75962541183fdc247E7B07AD6B70b (tx 0xed865d580eef19d972436d4e9c9cce40b7359ef393dd3967c9a280e8a22f5329),
  funded 0.05 lREACT, wired to the new hook (hookChainId 11155111, Cron10, minCheckpointInterval 120).
  Verified by direct RPC reads. Idle cost = 0 (rGas is per-callback; no-op heartbeat spends nothing).
- NOT DONE: Phase-7 end-to-end (LP deposit → swap → Checkpointed) — needs the demo script (next).
-> docs/session-12-reactive-deployment.md

Previously completed (Session 11): First live Ethereum Sepolia HOOK deployment — NOW SUPERSEDED by
the Session-12 redeploy. Old hook 0x50cd0E7e046022a9B359ca8725aCb75748FB67C0; PoolId
0xe531d42027094e6563d0838d0fe1c8705172d4feed0e6a5f48a08ca97f2b81cb; PoolManager
0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; owner/admin 0x193D1F3E085efc80e1027891FaA770E81ECC4A1d.
MockUSDC 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA (reused by the Session-12 redeploy).
-> docs/session-11-sepolia-deployment.md

Previously completed: Reactive Network contract (two workstreams).
Workstream 1 — RangeGuardHook retrofit: inherits AbstractCallback (onlyServiceProvider =
Callback Proxy); constructor gains \_callbackSender (3-arg); added checkpointCallback /
checkpointAndEmitOutOfRange / checkpointAndEmitBackInRange (leading ignored RVM-ID placeholder;
emit-fn guards PositionAlreadyOutOfRange/InRange); \_lastRangeEventInRange alternation guard
(init in afterAddLiquidity); PositionClosed / PositionOutOfRange / PositionBackInRange events;
removed reactiveContract / \_reactiveSet / setReactiveContract.
Workstream 2 — RangeGuardReactive.sol (AbstractPausableReactive, ReactVM): four if(!vm)
subscriptions (PositionRegistered / TickUpdated / PositionClosed + Cron heartbeat); react()
routes by source (service → heartbeat, else topic0); four handlers; getPausableSubscriptions
returns Cron only; activeKeys swap-and-pop; hookChainId parameterizes the destination chain
(4-arg constructor); MAX_POSITIONS_PER_CYCLE = 20; CALLBACK_GAS_LIMIT = 300_000; address(0)
first arg in every payload. reactive-lib-omni v0.1.0 installed (remappings.txt);
DeployRangeGuardReactive.s.sol added (ReactVM, env-driven, dry-run verified).
-> docs/session-10-reactive-contract-complete.md

Carry-ins:

Position owner attribution: payout recipient is the v4 sender (owner=sender MVP).
hookChainId 4-arg constructor — authorized mid-session deviation from the locked 3-arg form;
spec.md + reactiveSpec.md reconciled. Testability: \_lastRangeEventInRange + the three topic0
constants are internal (spec said private).

Spec §11 view functions NOT implemented (future mainnet-hardening item): getCurrentFee,
getBufferHealth, getDayCountBasis, getCoverageAPR, getPositionSnapshot, getAccrualState,
getEarnedCoverage, getEligibility, getEstimatedPayout, getCoverageProgress, getPoolConfig.
The hook exposes only the auto-generated getters for the public mappings (poolConfig / poolState /
positions). All Session-13 tests, scripts, and the demo therefore READ those mappings directly
(derive fee = baseLpFeeBps + bufferBps; buffer health = bufferBalanceStable * 100 / targetBufferSize)
and parse limitingFactor from the ClaimSettled / PartialPayout event logs. The deployed live hook is
NOT being redeployed to add these; implement them in a future hardening pass (they also back the
frontend coverage report — getEarnedCoverage simulating accrual to block.timestamp is the key one).

Tests: 278 passing, 0 failing.

Completed

Reactive Network contract (Phase 3B) — RangeGuardHook retrofit (BaseHook + AbstractCallback,
onlyServiceProvider; checkpointCallback / checkpointAndEmitOutOfRange /
checkpointAndEmitBackInRange; \_lastRangeEventInRange guard; PositionClosed / PositionOutOfRange /
PositionBackInRange events; reactiveContract/setReactiveContract removed) + RangeGuardReactive.sol
(AbstractPausableReactive on ReactVM; 3 hook subscriptions + Cron heartbeat; react() routing; four
handlers; pausable Cron-only; hookChainId-parameterized destination chain). reactive-lib-omni v0.1.0 +
remappings.txt; DeployRangeGuardReactive.s.sol. Pruned 10 obsolete setReactiveContract tests
(210→200), added 78: 30 hook unit + 2 hook fuzz + 3 hook invariant (AuthorizationInvariant) +
40 reactive unit + 2 reactive fuzz + 1 integration (CoverageAccrualLifecycle — closes the Phase 3
in→out→in arc). (+68 net → 278 total)
-> docs/session-10-reactive-contract-complete.md
checkpoint() / seedBuffer() — Phase-2 externals. checkpoint() is the permissionless,
accrual-only Reactive entry point (\_poolInitialized → active → minCheckpointInterval
(CheckpointTooSoon) → \_accrue via new private \_getCurrentTick → Checkpointed).
seedBuffer() is admin-only REAL token1 custody (IERC20Minimal.transferFrom; credits
bufferBalanceStable only), resolving the session-8 R2 carry-in. Full test suite: 16 unit + 4
fuzz + 8 invariant (CheckpointInvariant + SeedBufferInvariant + handlers, 50k calls × 0 reverts) +
1 integration (real seedBuffer custody → checkpoint → settle). (+29 tests → 210 total)
-> docs/session-9-checkpoint-seedBuffer-complete.md
beforeRemoveLiquidity() / afterRemoveLiquidity() — withdrawal/settlement callbacks.
beforeRemoveLiquidity (view) validates only: active position + full-withdrawal gate
(removed == pos.liquidity). afterRemoveLiquidity runs all settlement from the realized
removal BalanceDelta: minHold hard gate (IneligibleClaim + clear), final \_accrue()
(exit tick via getSlot0), \_computeIL() on the fees-included delta, \_computePayout()
three-cap, strict-CEI payout (clear + buffer update before a real token1 transfer),
ClaimSettled / PartialPayout / NoClaim. PositionState dropped pendingPayout, added
uint128 liquidity; re-add now reverts PositionAlreadyRegistered. Full test suite: 14 unit +
2 fuzz + 3 invariant (SettlementExecution + handler) + 1 integration (real add→swap→warp→
remove→ClaimSettled, custody/buffer/paidOut reconciled). (+20 tests → 181 total)
-> docs/session-8-remove-liquidity-complete.md
beforeSwap() / afterSwap() — swap-path callbacks. beforeSwap (view) returns the derived
dynamic fee (baseLpFeeBps + bufferBps) | OVERRIDE_FEE_FLAG + ZERO_DELTA, reads poolConfig
only. afterSwap books the notional buffer credit (|delta.amount1()| \* bufferBps / FEE_DENOM,
FEE_DENOM = 1e6), increments bufferBalanceStable + totalSkimmedStable, emits BufferFunded
(skipped on zero) + TickUpdated (every swap); no accrual, no position iteration. Added
FEE_DENOM constant + two events; reused \_absToUint128. Full test suite: 13 unit + 3 fuzz +
3 invariant (BufferFundingInvariant + handler) + 2 integration (real swap + differential
fee-override proof). (+21 tests → 161 total)
-> docs/session-7-beforeSwap-afterSwap-complete.md
afterAddLiquidity() — position registration + dt=0 accrual baseline. Lifecycle guard
(\_poolInitialized), owner=sender key (MVP), re-add skip (immutable snapshot), principal =
delta - feesAccrued, live entry tick via getSlot0, notional via shared \_priceFromTick,
PositionRegistered event, \_positionKey/\_emitPositionRegistered/\_absToUint128 helpers.
Full test suite: 10 unit + 3 fuzz + 3 invariant (PositionLifecycleInvariant + handler) +
1 integration (real PoolManager + router, live non-zero tick). (+17 tests → 140 total)
-> docs/session-6-afterAddLiquidity-complete.md
Pool setup (two-phase) — stagePoolConfig() + \_beforeInitialize() commit;
owner immutable (explicit ctor arg) + onlyOwner, hard-bound constants, PendingPoolSetup struct,
setup mappings, events, errors. Reactive authorization via AbstractCallback
(onlyServiceProvider — Callback Proxy) replaces setReactiveContract(). Full test suite:
32 unit + 3 fuzz (StagePoolConfigFuzz) + 6 invariant (PoolSetupInvariant + handler) +
4 integration (real PoolManager.initialize round-trip). Deploy script and harness updated
for the owner ctor param. (+45 tests → 123 total)
-> docs/session-5-pool-setup-complete.md
\_accrue() — engine + shared pure helper \_accrueEarned(), supporting state
(PoolConfig/PoolState/PositionState, mappings, AccrualUpdated), full test suite.
-> docs/session-2-accrue-complete.md, docs/session1-accrue-decisions.md
\_computeIL() — IL primitive + shared pure \_priceFromTick() helper (raw-ratio,
decimal-agnostic; resolves Risk 6); full test suite (14 unit + 8 fuzz + 3 invariant).
-> docs/session-3-computeIL-complete.md
\_computePayout() — three-cap logic + LimitingFactor enum; pure \_computePayoutAmount()
core + storage-reading wrapper; added BPS_DENOM, LimitingFactor enum, poolState mapping;
full test suite (15 unit + 4 fuzz + 2 settlement invariants).
-> docs/session-4-computePayout-complete.md
Scaffold & infra — hook skeleton, getHookPermissions(), deploy scripts
(DeployRangeGuardHook.s.sol, HelperConfig.s.sol), BaseRangeGuardTest, RangeGuardHookHarness,
DYNAMIC_FEE_FLAG enforcement, documentation system.
CI / process — GitHub Actions (fmt + build + test, Foundry pinned 1.3.5); deploy flow
runs without PRIVATE_KEY (envOr fallback); main protected (PR + green CI required).

Roadmap
Phase 1: Core Accounting Primitives

\_accrue() (impl + unit + fuzz + invariant)
\_computeIL() (impl + unit + fuzz + invariant; shared \_priceFromTick helper)
\_computePayout() (impl + unit + fuzz + invariant; three-cap logic + LimitingFactor)

Phase 2: Hook Callbacks
Pool setup + afterAddLiquidity wired; remaining callbacks are selector-returning skeletons.

Pool setup: stagePoolConfig() + \_beforeInitialize() commit
(two-phase pool bring-up; Reactive authorization via AbstractCallback;
see docs/spec-amendment-beforeInitialize-config-split.md)
afterAddLiquidity() (register position, baseline \_accrue(); +17 tests, live-tick integration)
beforeSwap() (return derived dynamic fee + OVERRIDE flag; view, no state touched)
afterSwap() (notional buffer funding + TickUpdated; no accrual, no iteration; +21 tests)
beforeRemoveLiquidity() (validation only: active + full-withdrawal gate; +6 unit tests)
afterRemoveLiquidity() (v4-native settlement: minHold gate -> final \_accrue -> \_computeIL ->
\_computePayout -> strict-CEI payout; ClaimSettled/PartialPayout/NoClaim; +14 tests)
checkpoint() (permissionless accrual-only Reactive entry point; \_poolInitialized/active/
minCheckpointInterval gates, \_getCurrentTick + \_accrue, Checkpointed; +19 tests)
seedBuffer() (admin-only real token1 custody via IERC20Minimal.transferFrom; credits
bufferBalanceStable only; BufferSeeded; resolves R2 real-custody carry-in; +10 tests)

Phase 3: Integration Testing

Full LP lifecycle (CheckpointAndSeed: add→swap→seed→checkpoint→remove→settle, reconciled)
Coverage accrual lifecycle ✅ (CoverageAccrualLifecycle: register → heartbeat → range-out →
range-back-in → heartbeat → close, driving hook + RangeGuardReactive with a faithful Callback-
Proxy relay; monotonic accrual + guard flips both sides + real ClaimSettled + activeKeys empty.
Closes the in→out→in arc previously gated on the Reactive contract's PositionOutOfRange/BackInRange)
Buffer funding lifecycle (Swap: notional skim from real swaps; CheckpointAndSeed: real seed custody)
Settlement lifecycle (RemoveLiquidity + CheckpointAndSeed: final accrue→IL→payout→transfer→cleanup)

Note: coverage is distributed across per-session integration files rather
than a single dedicated Phase 3 suite. A comprehensive single-test lifecycle
covering all callbacks end-to-end will come with the demo script.
Phase 3B: Protocol Completion

Reactive contract ✅ (complete — see Completed section / session-10 doc)

- RangeGuardHook retrofit: AbstractCallback (onlyServiceProvider); checkpointCallback /
  checkpointAndEmitOutOfRange / checkpointAndEmitBackInRange; \_lastRangeEventInRange guard;
  PositionClosed / PositionOutOfRange / PositionBackInRange; reactiveContract removed
- RangeGuardReactive.sol: AbstractPausableReactive on ReactVM; 3 hook subscriptions + Cron
  heartbeat; react() routing; hookChainId parameterized; reactive never mutates accounting

- [x] Sepolia HOOK deployment (Session 11: hook → Sepolia → pool → buffer seeded — REDEPLOYED in
      Session 12 for Lasna as 0xFead…a7C0; old 0x50cd… superseded — see session-11/12 docs)
- [x] ReactVM deployment (Session 12: Reactive → Reactive Lasna 0xC0e6…B70b, funded + wired to the
      new hook, verified by RPC — see session-12 doc)
- [x] Demo script (Session 13): RangeGuardDemo.s.sol (Option A, fork+vm.warp, spec §14) + LiveEndToEnd.s.sol
      / LiveWithdraw.s.sol (Option B live broadcast) + DemoLPRouter.sol + 14 Sepolia fork tests. Live
      lifecycle broadcast on Sepolia; reactive react() proven (after the vmOnly→onlySystem fix +
      redeploy). See docs/session-13-demo-script.md, docs/reactive-evidence.md.
- [ ] Frontend dashboard (coverage report rendered from Sepolia events) ← NOW

Phase 4: Protocol Invariants (cross-cutting)

Accounting invariants (coverage + buffer + checkpoint: CoverageAccounting/Checkpoint/
BufferFunding/SeedBuffer — earned never decreases/exceeds ceiling, inactive never accrues,
clock monotonic, buffer never negative, snapshots immutable, maxPayoutPctOfBuffer<=BPS_DENOM)
Lifecycle invariants (transitions proven in separate per-action campaigns
(PositionLifecycle/Checkpoint/SettlementExecution); TODO: one combined stateful
add→checkpoint→remove campaign on shared keys)
Settlement invariants (SettlementInvariant + SettlementExecutionInvariant: IL_raw never
negative/bounded, payout <= every cap, buffer conserved (buffer+paidOut==seed), real custody==
ledger, LimitingFactor matches binding cap)
Authorization invariants ✅ (AuthorizationInvariant + RangeEventHandler: the three reactive
functions are callable ONLY via the Callback Proxy — no unauthorized call succeeds across ~50k
calls — the \_lastRangeEventInRange guard alternates correctly, and reactive/unauthorized calls
never deactivate a position. Per-actor access checks (owner/admin/initializer/callbackProxy)
remain unit-tested.)

Phase 5: Deployment Readiness on Anvil

Anvil deployment
Security review

Phase 6: Deployment Readiness on Sepolia

Sepolia deployment
Security review
Mainnet readiness review

Testing Infrastructure
Status: COMPLETE

Deployment: DeployRangeGuardHook.s.sol (host chain, CREATE2 + HookMiner, 3-arg ctor),
DeployRangeGuardReactive.s.sol (ReactVM, env-driven, 4-arg ctor incl. hookChainId, rGas via
--value), HelperConfig.s.sol
Dependency: reactive-lib-omni v0.1.0 (remappings.txt: reactive-lib/=lib/reactive-lib-omni/)
Shared harness: BaseRangeGuardTest (canonical deployment for all suites), ReactiveTestBase
(reactive harness + manual LogRecord builders + event mirrors)
Internal-access harness: RangeGuardHookHarness, RangeGuardReactiveHarness (exposed internals;
test-only), MockSystemContract (etched at 0x..fffFfF for the vm==false pause/resume path)
CI: .github/workflows/ci.yml — fmt check + build + test on every PR (Foundry pinned 1.3.5)
