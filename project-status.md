RangeGuard Project Status
Last Updated: 2026-06-04 (Design session — Reactive contract architecture)
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

Active target: Reactive Network contract — two workstreams:
Workstream 1 — Hook changes (retrofit to RangeGuardHook.sol):

AbstractCallback inheritance; constructor gains \_callbackSender arg
Remove reactiveContract[poolId] and \_reactiveSet[poolId] mappings
checkpointCallback(address, PoolId, bytes32) — permissionless RVM heartbeat entry point
checkpointAndEmitOutOfRange(address, PoolId, bytes32) — authorizedSenderOnly, atomic
checkpointAndEmitBackInRange(address, PoolId, bytes32) — authorizedSenderOnly, atomic
\_lastRangeEventInRange mapping; initialized in afterAddLiquidity
PositionClosed event emitted in afterRemoveLiquidity on ALL settlement paths
New errors: PositionAlreadyOutOfRange, PositionAlreadyInRange

Workstream 2 — RangeGuardReactive.sol (new contract, ReactVM chain):

Inherits IReactive + AbstractPausableReactive
3 hook subscriptions: PositionRegistered, TickUpdated, PositionClosed
Cron10 heartbeat (~1 min); checkpointCallback per active position
react() routing: Cron10 → heartbeat, TickUpdated → range transitions,
PositionRegistered → add tracking, PositionClosed → remove tracking
MAX_POSITIONS_PER_CYCLE = 20; CALLBACK_GAS_LIMIT = 300_000
RVM ID placeholder rule: address(0) first arg in ALL callback payloads

Just completed: checkpoint() + seedBuffer(). checkpoint(poolId, positionKey) is
permissionless and accrual-ONLY (no IL/payout/transfer): guards \_poolInitialized →
PositionNotActive → block.timestamp - lastAccrualTime < minCheckpointInterval
(CheckpointTooSoon), reads the live tick via the new private \_getCurrentTick(poolId), calls
\_accrue, emits Checkpointed. seedBuffer(key, amount) is admin-only (config.admin) REAL
token1 custody: guards \_poolInitialized → CallerNotAdmin → ZeroAmount, pulls via
IERC20Minimal.transferFrom (CurrencyLibrary has no transferFrom), credits
bufferBalanceStable ONLY (not totalSkimmedStable), emits BufferSeeded.
Locked decisions resolved this session:

R1: \_getCurrentTick — the spec referenced it but it was never implemented (callbacks
inline getSlot0); added as a private helper for checkpoint(); existing inline reads kept.
R2: token pull — IERC20Minimal.transferFrom with a checked bool (revert on false); admin
must approve(hook, amount) first.
R3: minCheckpointInterval == 0 allowed (no staging bound); same-block re-checkpoints are
harmless (dt == 0 → zero delta). Staging validation NOT touched.
R4: seed credits bufferBalanceStable only — totalSkimmedStable is fee accounting;
getBufferHealth reflecting seeds in the balance is desired.
R5: native token1 can't be seeded (no transferFrom); out of MVP scope, documented only.

R2 carry-in (from session 8) RESOLVED: seedBuffer() provides the real token1 custody the
payout transfer depends on. The new SeedBufferInvariant and the new integration test use real
seeded custody instead of minting token1 directly to the hook.
Carry-ins:

Position owner attribution: payout recipient is the v4 sender (owner=sender MVP).

Tests: 210 passing, 0 failing.

Completed

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
(authorizedSenderOnly — Callback Proxy) replaces setReactiveContract(). Full test suite:
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
Coverage accrual lifecycle (only single in-range checkpoint + final accrual covered;
TODO: out-of-range pause / back-in-range resume / multi-checkpoint history — the in→out→in
arc, partly gated on the Reactive contract's PositionOutOfRange/BackInRange emits)
Buffer funding lifecycle (Swap: notional skim from real swaps; CheckpointAndSeed: real seed custody)
Settlement lifecycle (RemoveLiquidity + CheckpointAndSeed: final accrue→IL→payout→transfer→cleanup)

Note: coverage is distributed across per-session integration files rather
than a single dedicated Phase 3 suite. A comprehensive single-test lifecycle
covering all callbacks end-to-end will come with the demo script.
Phase 3B: Protocol Completion

Reactive contract

- AbstractCallback inheritance; constructor adds \_callbackSender arg
- checkpointCallback(address, PoolId, bytes32) — authorizedSenderOnly, atomic
- checkpointAndEmitOutOfRange(address, PoolId, bytes32) — authorizedSenderOnly, atomic
- checkpointAndEmitBackInRange(address, PoolId, bytes32) — authorizedSenderOnly, atomic
- \_lastRangeEventInRange guard initialized in afterAddLiquidity
- PositionClosed event emitted in afterRemoveLiquidity on all settlement paths
- RangeGuardReactive.sol: IReactive + AbstractPausableReactive, 3 subscriptions
  (PositionRegistered / TickUpdated / PositionClosed) + Cron10 heartbeat
- Reactive contracts must never mutate accounting state
  Frontend dashboard (coverage report rendered from on-chain events)
  Demo script (RangeGuardDemo.s.sol with vm.warp, full 45-day lifecycle)

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
Authorization invariants (blocked on Reactive phase: authorizedSenderOnly/
checkpointAndEmitOutOfRange/checkpointAndEmitBackInRange not built yet; access checks are
unit-tested (owner/admin/initializer/callbackProxy) but no dedicated authorization-invariant
suite and no "reactive never mutates accounting" coverage until Reactive contract exists)

Phase 5: Deployment Readiness on Anvil

Anvil deployment
Security review

Phase 6: Deployment Readiness on Sepolia

Sepolia deployment
Security review
Mainnet readiness review

Testing Infrastructure
Status: COMPLETE

Deployment: DeployRangeGuardHook.s.sol (runs without PRIVATE_KEY via envOr), HelperConfig.s.sol
Shared harness: BaseRangeGuardTest (canonical deployment for all suites)
Internal-access harness: RangeGuardHookHarness (seeders + exposed internals; test-only)
CI: .github/workflows/ci.yml — fmt check + build + test on every PR (Foundry pinned 1.3.5)
