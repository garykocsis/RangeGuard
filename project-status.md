RangeGuard Project Status
Last Updated: 2026-06-09 (Session 16 — coverage + gas snapshot)
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

Active target: Full README write-up. All protocol code, deployment, demo tooling, the frontend
dashboard, the presentation deck, the recorded demo, AND the coverage + gas snapshot are complete.

Just completed (Session 16): Coverage report + gas snapshot baseline + CI gating + .env.example.
- COVERAGE: forge coverage → docs/coverage-summary.md. Total 98.45% lines / 98.51% statements /
  92.86% branches / 94.23% functions. The two SHIPPED contracts — RangeGuardHook.sol and
  RangeGuardReactive.sol — are at 100% lines AND 100% functions. The aggregate is below 100% only
  from intentional non-shippable items: MockUSDC.sol (0%, testnet-only mock) and the vendored
  AbstractPausableReactive ReactVM-detection branches (resolve only on live Lasna, unreachable in
  the Foundry EVM). coverage/ + lcov.info gitignored.
- GAS: forge snapshot → committed .gas-snapshot baseline (277 entries). Top-5 production hook
  functions by avg gas: beforeInitialize 212,967 (one-time/pool), afterAddLiquidity 163,872
  (one-time/position), afterRemoveLiquidity 61,922, checkpoint 56,455, afterSwap 46,414 (constant
  per-swap, O(1) — no LP iteration). Source: forge test --gas-report (per-function; .gas-snapshot
  is per-test).
- SEPOLIA FORK EXCLUSION: the 14 test/integration/sepolia/* tests are excluded from the baseline +
  CI gas check — they vm.skip without SEPOLIA_RPC_URL (absent in CI) and their gas is
  fork-block-dependent, so they can't be part of a deterministic gate. They still run locally (.env
  supplies the RPC) and count toward the 292 total.
- CI: .github/workflows/ci.yml gains a gas-snapshot job (forge snapshot --check --no-match-path
  sepolia → fails on any gas increase vs baseline) and a coverage job. Both pinned to Foundry 1.3.5
  + checkout@v4 + recursive submodules (matching the test job; hardened beyond the literal snippet).
- README: 5 shields.io badges below the tagline (tests 292 / coverage 98% / MIT / Sepolia / Lasna).
- .env.example: copy-to-.env template at repo root with all live deployed addresses; .env confirmed
  gitignored.
-> docs/session-16-coverage-gas.md

Just completed (Session 15): Presentation deck + RangeGuard logo, and the recorded 5-minute demo
(uploaded to YouTube). The deck was REBUILT from the original 9-slide version to a tighter 6-slide
narrative (Title / The Solution / Economic Flywheel / Five Pillars / Code Walkthrough / Closing),
a custom logo was designed, and the demo was recorded and published.
- DEMO VIDEO: https://www.youtube.com/watch?v=82_9mEh_POM (~3m 53s; linked in README.md).
- DECK (docs/RangeGuard-Demo-Deck.pptx): 16:9, dark-navy design system, Calibri, full speaker notes
  on every slide (incl. verbal transitions + IDE narration). Title + Closing wordmark lockups are
  native Calibri text + the shield icon (crisper); shield icon top-left on content slides; Uniswap +
  Reactive partner logos on Title + Closing. 292 tests cited.
- LOGO (docs/assets/): shield (gradient stroke #FF007A→#9B59B6) wrapping three green #00d395
  bar-chart bars. SVGs: logo-icon.svg, favicon.svg, logo-standalone.svg(+ -light),
  logo-full.svg(+ -light). Partner logos from official sources: uniswap-logo.svg (pink unicorn),
  reactive-logo.svg(+ -dark wordmark).
- RASTERIZE PIPELINE: python-pptx can't embed SVG; docs/build_assets.py renders each needed SVG→PNG
  on a navy bg (qlmanage composites on white, so we inject a #0f1117 rect, key to transparent, crop)
  → build_deck.py embeds the PNGs. Build order: build_assets.py then build_deck.py. Verified by
  rendering to slide images via LibreOffice headless.
-> docs/session-15-slides.md

Just completed (Session 14): Frontend dashboard — coverage report (frontend/, React 18 + Vite +
Tailwind + viem, no backend). Renders the LP coverage report from LIVE Sepolia on-chain events;
verified end-to-end against hook 0xFead…a7C0. Two modes (Option C):
- LIVE (default, or ?positionKey=0x…): real on-chain events for any position — honest + verifiable.
  Settlement CLEARS positions[…], so a closed position reads zero from the mapping; the dashboard
  reconstructs entry/earned/payout from EVENT HISTORY (PositionRegistered + settlement). Buffer
  health from poolState; current tick via PoolManager extsload (Slot0). Polls every 30s.
- DEMO (?demo=true): hardcoded fork narrative from docs/demo-run-output.md, banner-labeled
  "Simulated 45-day lifecycle (Sepolia fork)" — never presented as live. Used for the recording's
  4:15–4:45 coverage-report segment.
Live data verified: PositionRegistered (228.69 USDC, range $1,790–$2,208) → Checkpoint +0.02 USDC →
PartialPayout/COVERAGE_CAP 0.02 USDC; buffer 10,000.81 / health 10.00%. Two honest notes: live range
reads $1,790–$2,208 (tick rounding, not the nominal $1,800–$2,200); live settlement is
PartialPayout/COVERAGE_CAP, not ClaimSettled/IL_CAP (the IL_CAP story is the ?demo=true view).
Deployed via Vercel (auto-deploy from main): https://range-guard.vercel.app — Framework Vite, root
frontend, build npm run build, output dist, no env vars.
-> docs/session-14-frontend.md

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
- [x] Frontend dashboard (Session 14: coverage report from LIVE Sepolia events; React+Vite+viem at
      frontend/; live mode + ?demo=true simulated mode; Vercel https://range-guard.vercel.app —
      see docs/session-14-frontend.md)
- [x] Presentation deck + logo (Session 15): docs/RangeGuard-Demo-Deck.pptx — REBUILT to a 6-slide
      Google-Slides-ready .pptx (Title / Solution / Flywheel / Five Pillars / Code Walkthrough /
      Closing; 16:9, dark-navy design system, Calibri, full speaker notes, embedded logos). Custom
      RangeGuard logo (shield + bar-chart) in docs/assets/ — logo-icon.svg, favicon.svg,
      logo-standalone.svg (+ -light), logo-full.svg (+ -light), plus Uniswap (uniswap-logo.svg) +
      Reactive (reactive-logo.svg, + -dark) partner logos. Built via docs/build_assets.py (SVG→PNG) +
      docs/build_deck.py — see docs/session-15-slides.md
- [x] Recorded 5-minute demo (spec §15) (Session 15): recorded + uploaded to YouTube
      https://www.youtube.com/watch?v=82_9mEh_POM (~3m 53s); linked in README.md
- [x] Coverage + gas snapshot (Session 16: `.gas-snapshot` committed baseline + CI gas-regression
      gate + coverage job; docs/coverage-summary.md — 98.45% lines (core hook + reactive at 100%);
      afterSwap 46,414 avg gas; README badges; .env.example — see docs/session-16-coverage-gas.md)
- [ ] Full README write-up ← NOW

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
