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

- PROJECT COMPLETE — all roadmap items shipped. The full README write-up was the last item
  (Session 17 ✅). No open implementation work remains.

Roadmap (all complete):

1. Sepolia hook deployment ✅ (Session 11; REDEPLOYED for Lasna in Session 12 — new hook 0xFead…a7C0)
2. ReactVM (reactive) deployment ✅ (Session 12 — Reactive Lasna 0xC0e6…B70b, live + wired + verified)
3. Demo script (RangeGuardDemo.s.sol) ✅ (Session 13)
4. Frontend dashboard ✅ (Session 14 — frontend/, live coverage report; https://range-guard.vercel.app)
5. Presentation deck ✅ (Session 15 — docs/RangeGuard-Demo-Deck.pptx, 6-slide Google-Slides .pptx + logo)
6. Recorded 5-minute demo ✅ (Session 15 — uploaded https://www.youtube.com/watch?v=82_9mEh_POM)
7. Coverage + gas snapshot ✅ (Session 16)
8. Full README write-up ✅ (Session 17 — comprehensive README.md; project complete)

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

PROJECT COMPLETE (Session 17): The full README write-up — the last open roadmap item — is done.
Every roadmap item across all phases is now shipped. `README.md` replaces the placeholder with a
comprehensive, audience-ready document (judges / employers / developers).

README (Session 17) — 13 sections: header (logo + 5 badges + live dashboard/demo links + clickable
Sepolia hook `0xFead…a7C0` AND Lasna-Omni reactive `0x5eb9…Fee1`) → Overview → The Problem → The
Solution (Five Pillars) → Architecture (TWO Mermaid diagrams: two-chain + LP lifecycle, GitHub-native)
→ Technical Deep Dive (6.1 hook mechanics + _accrue snippet · 6.2 reactive · 6.3 day-count · 6.4 gas)
→ Live Deployment (all addresses clickable) → Running Locally → Test Suite → Reactive Network
Integration → Roadmap → Documentation Index → License. Content decisions (all confirmed by the user):
- IL EXAMPLE (rigorous, reconciles cell-by-cell): 1 ETH + 2,000 USDC @ $2,000 ($4,000 notional),
  ETH→$1,000. HODL exit $3,000; LP exit $2,828 (1.414 ETH + 1,414 USDC); IL = $172 (= 5.72% of the
  $3,000 HODL value, NOT 5.72%×$4,000=$229 — that conflates the % base); ~$20 fees; net −$152. 5.72%
  = 2√r/(1+r)−1 at r=0.5. Use THESE numbers everywhere the IL example appears.
- "coverage" NEVER "insurance" (regulatory connotation) — enforced repo-wide in the README.
- LASNA NAMING: always "Reactive Network (Lasna Omni fork)". Migration story told in Section 10
  (Session 12 legacy Lasna / reactive-lib v0.2.0 → Session 13 discovered Omni upgrade → migrate to
  reactive-lib-omni + 2 fixes → redeploy). "ReactVM" used ONLY for the legacy sandbox model.
- LEADING address PLACEHOLDER: KEPT in the shown signatures — it MATCHES the deployed bytecode
  (verified: src/RangeGuardHook.sol checkpointCallback/checkpointAndEmitOutOfRange/…BackInRange all
  take `address /*RVM ID*/`, and RangeGuardReactive encodes address(0) first). The user initially
  asked to remove it (believing Omni dropped it); on-chain evidence showed it is RETAINED, so it
  stays, framed as a "legacy carry-forward" to be removed in the Omni-fork-v2 upgrade (now the FIRST
  Phase-2 roadmap item, with onlyServiceProvider → onlyCallbackSender(rangeGuardReactiveOrigin)).
- LIVE vs DEMO settlement shown honestly: live = PartialPayout/COVERAGE_CAP (entry 228.69 USDC);
  IL_CAP/ClaimSettled (12.51 earned → 2.23 paid) is the labeled ?demo=true fork narrative.
- Spec §11 view fns appear ONLY under Roadmap Phase 2 (not implied to exist on the deployed hook).
- Gas table 6.4: afterSwap 46,414 (O(1), every swap) / checkpoint 56,455 / afterRemoveLiquidity
  61,922 / afterAddLiquidity 163,872 / beforeInitialize 212,967.
- VERIFIED at write time: `make gas-check` exists (Makefile L118), `docs/assets/logo-icon.svg`
  exists — so the README's references are correct as-is.
Branch: docs/readme. -> docs/session-17-readme.md

---

Previously completed (Session 16): Coverage report + committed gas-snapshot baseline + CI gating +
`.env.example`.

COVERAGE — `docs/coverage-summary.md` (and a Production Contract Coverage section): `forge coverage
--report summary --no-match-coverage "(test|script)/"` → total **98.45% lines** / 98.51% statements
/ 92.86% branches / 94.23% functions. The two SHIPPED contracts — RangeGuardHook.sol and
RangeGuardReactive.sol — are at **100% lines AND 100% functions**. The aggregate is below 100% ONLY
because of intentional non-shippable items: `src/mocks/MockUSDC.sol` (0%, testnet-only ERC-20 mock,
never on mainnet) and `src/base/AbstractPausableReactive.sol` vm/vmOnly ReactVM-detection branches
(resolve only on live Reactive Lasna; structurally unreachable in the Foundry EVM). `coverage/` +
`lcov.info` added to .gitignore.

GAS — `.gas-snapshot` committed at repo root (204 entries, DETERMINISTIC tests only) = the baseline
CI checks via `forge snapshot --check`. Top-5 production hook fns by avg gas (source: `forge test
--gas-report`, since .gas-snapshot is per-TEST not per-FUNCTION): beforeInitialize 212,967
(one-time/pool), afterAddLiquidity 163,872 (one-time/position), afterRemoveLiquidity 61,922,
checkpoint 56,455, **afterSwap 46,414** (constant per-swap, O(1), no LP iteration).

DETERMINISTIC-BASELINE GATE (the key gas-baseline gotcha): the baseline + CI gas check exclude
non-reproducible tests via `--no-match-path "test/integration/sepolia/*" --no-match-test
"(testFuzz|invariant)"`. (1) Sepolia fork tests `vm.skip` without SEPOLIA_RPC_URL (absent in CI; a
local `.env` supplies it, so all 292 run locally with 0 skipped) and are fork-block-dependent. (2)
Fuzz/invariant tests report a MEAN gas that is NOT byte-reproducible across environments even with
the pinned `seed = "0x1"` (corpus cache in gitignored `cache/` + platform). The FIRST CI run of the
gas job flaked on four fuzz μ values (1–657 gas drift; all 278 tests passed functionally) — the fix
was to gate deterministic tests only, NOT chase the moving μ. NB: `--no-verify` was NOT the cause —
the pre-push hook runs fmt/build/test, not `forge snapshot --check`, so it can't catch gas drift.
Use `make gas-check` to run the exact CI gate locally before pushing; `make snapshot` regenerates
with the same filters (kept in sync with ci.yml). Concrete unit + integration tests still cover
every production fn; excluded tests still run in the test job + count toward 292.

CI — `.github/workflows/ci.yml` gains `gas-snapshot` (forge snapshot --check, fails on any gas
increase vs baseline) + `coverage` jobs. Both hardened beyond the literal task snippet to match the
existing test job: checkout@v4 + `submodules: recursive` + Foundry pinned `1.3.5` (gas is
toolchain-sensitive), and `forge snapshot --check` (not bare `forge sn`, which wouldn't gate).

README — 5 shields.io badges below the tagline: tests 292 / coverage 98% / MIT / Sepolia / Lasna.
.env.example — copy-to-.env template at repo root with all live deployed addresses (hook 0xFead…a7C0,
MockUSDC 0x04feCef…428CA, DemoLPRouter 0xEA30…1FEa, PoolManager 0xE03A…3543, reactive 0x5eb9c8C0…Fee1,
PoolId, position key); `.env` confirmed gitignored.
-> docs/session-16-coverage-gas.md

---

Previously completed (Session 15): Presentation deck + logo, and the recorded demo (uploaded to YouTube).
The slides are COMPLETE and the 5-minute demo is RECORDED & UPLOADED:
https://www.youtube.com/watch?v=82_9mEh_POM (~3m 53s).

DECK — `docs/RangeGuard-Demo-Deck.pptx`: a 6-slide `.pptx` (python-pptx 1.0.2) that imports directly
into Google Slides. 16:9 (13.33"×7.5"), Calibri, dark-navy design system (bg #0f1117, white #ffffff,
accent #00d395, slate #94a3b8, amber #f59e0b, danger #ef4444, card #1e2433). Slides: 1 Title ·
2 The Solution · 3 Economic Flywheel · 4 Five Pillars · 5 Code Walkthrough · 6 Closing. FULL speaker
notes on every slide. REBUILT from the prior 9-slide version: removed the two IL-explanation slides
(judges know IL) + the two transition slides (demo / coverage-report); added a Title slide.

LOGO — `docs/assets/`: shield (gradient stroke #FF007A→#9B59B6, transparent fill) wrapping three
green #00d395 bar-chart bars. Variants: logo-icon.svg (64²) · favicon.svg (32², 2px) ·
logo-standalone.svg (+ -light) · logo-full.svg (+ -light). Partner logos from official sources:
uniswap-logo.svg (pink unicorn) · reactive-logo.svg (+ -dark wordmark). Usage on slides: shield icon
top-left on content slides; Title + Closing wordmark lockups are NATIVE Calibri text + the shield
icon (crisper than rasterizing, and dodges a faint downscaled-text raster seam); partner logos on
Title + Closing under "Built on" / "Powered by".

RASTERIZE PIPELINE — python-pptx can't embed SVG; `docs/build_assets.py` renders each needed SVG→PNG
on a navy bg (qlmanage composites on white, so we inject a #0f1117 rect, key it to transparent, crop)
→ `docs/build_deck.py` embeds the PNGs. Build order: build_assets.py then build_deck.py. Verified by
rendering the .pptx to slide images via LibreOffice headless (LibreOffice + poppler installed this
session for visual QA). 292 tests cited; demo figures use the REAL fork run (entry 228.38, total
coverage 12.51, payout 2.23 USDC / IL_CAP), matching the frontend ?demo view.
-> docs/session-15-slides.md

Previously completed (Session 14): Frontend dashboard — the LP coverage report (spec §4 Pillar 4).
React 18 + Vite + Tailwind + viem SPA in `frontend/`, NO backend — reads public Sepolia RPC only.
- TWO MODES (Option C): LIVE (default, or `?positionKey=0x…`) renders the real on-chain coverage
  report for any position; `?demo=true` renders a hardcoded fork narrative from
  docs/demo-run-output.md, banner-labeled "Simulated 45-day lifecycle (Sepolia fork)" — never
  presented as live. Live mode is for judges/employers; demo mode is for the 4:15–4:45 recording.
- KEY DESIGN: settlement CLEARS positions[poolId][key] (strict CEI), so a closed position reads
  ALL ZEROS / active=false. The coverage report is therefore reconstructed from EVENT LOGS, not
  the live mapping — PositionSummary rebuilds entry/earned/payout/IL/factor from PositionRegistered
  + the settlement event. This is Pillar 4 made literal: the report lives in events.
- READS: poolState (buffer health), poolConfig (targetBufferSize/coverageApr/secondsPerYear, fee =
  base+buffer), positions (live PositionState). Current tick has no getter → read via PoolManager
  `extsload` at keccak256(abi.encode(poolId, 6)) (v4 StateLibrary POOLS_SLOT=6), unpack Slot0
  sqrtPriceX96(160)|tick(24). Event log fetch: single eth_getLogs with topics [null,null,key]
  (positionKey is topic2 on every position-scoped event), decoded by topic0; floored at
  DEPLOY_BLOCK=11_005_000, chunked 9k blocks; 30s poll.
- VERIFIED live (hook 0xFead…a7C0): PositionRegistered 228.69 USDC / range $1,790–$2,208 →
  Checkpoint +0.02 USDC (dt=0 baseline row skipped) → PartialPayout/COVERAGE_CAP 0.02; buffer
  10,000.81 / health 10.00%. Build + dev server pass.
- DEPLOY: Vercel auto-deploy from `main` → https://range-guard.vercel.app (Framework Vite, root
  `frontend`, build `npm run build`, output `dist`, no env vars; frontend/vercel.json SPA rewrites).
- TWO HONEST NOTES: live range shows $1,790–$2,208 (tick rounding) not $1,800–$2,200; live
  settlement is PartialPayout/COVERAGE_CAP not ClaimSettled/IL_CAP (IL_CAP is the ?demo=true story).
-> docs/session-14-frontend.md

---

Previously completed (Session 12): reactive-lib → reactive-lib-omni (Omni fork) migration + first live
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

Current target: Coverage + gas snapshot, then the full README write-up. (Slides ✅ + demo recorded &
uploaded ✅ in Session 15 — https://www.youtube.com/watch?v=82_9mEh_POM.)
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

Session 14 carry-ins (frontend):
1. SPEC §11 VIEW FUNCTIONS NOT IMPLEMENTED on the deployed hook (mainnet-hardening item):
   getPoolConfig/getBufferHealth/getCurrentFee/getDayCountBasis/getCoverageAPR/getPositionSnapshot/
   getAccrualState/getEarnedCoverage/getEligibility/getEstimatedPayout/getCoverageProgress. The
   frontend works around this by reading the public mappings directly + extsload for the live tick.
   getEarnedCoverage (accrual simulated to block.timestamp) is the one worth adding — it would let an
   OPEN position render live coverage without the client-side extsload/simulation.
2. README is a MINIMAL PLACEHOLDER for now (tagline + live dashboard link + "coming soon"). The full
   write-up lands AFTER the demo recording, together with the demo video link.
3. Frontend is NOT auto-deployed until merged to `main` (Vercel watches main). Live-URL confirmation
   in docs/session-14-frontend.md has an unchecked box to tick once the Vercel deploy is green.
4. Live demo position is CLOSED (settled) on-chain — the live coverage report is honest + sparse;
   the full IL_CAP narrative is the ?demo=true view (clearly labeled simulated).
