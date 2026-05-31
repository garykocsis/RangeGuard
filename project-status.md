# RangeGuard Project Status

Last Updated: 2026-05-30 (Session 6 — afterAddLiquidity)

## How to use this file

- The **Roadmap** is the single source of truth for progress — one checkbox per item.
- **Now** holds the active target plus its granular impl/unit/fuzz/invariant sub-status.
  Only the in-progress item is tracked at that granularity here.
- **Completed** items collapse to one line and link to a `docs/` session doc for detail,
  instead of repeating per-item checklists.
- Each session: update **Now**, tick the **Roadmap**, refresh the date. Do not duplicate
  status across sections.
- Per-function build order (mandatory, per CLAUDE.md): implement -> unit -> fuzz ->
  invariant; correctness before gas.

---

## Now

- **Active target:** `beforeSwap()` — return the derived dynamic fee
  (`baseLpFeeBps + bufferBps`); no position state touched, no accrual. Then `afterSwap()`
  — buffer funding only (`bufferBalanceStable += contribution`, `BufferFunded`) +
  `TickUpdated` for the Reactive Network; never iterate positions, never accrue.
- **Just completed:** `afterAddLiquidity()` — `_poolInitialized` guard, position-key from the
  v4 `sender` (MVP `owner=sender`), skip re-registration on an active position (snapshot
  preserved), principal = `delta - feesAccrued`, live entry tick via `getSlot0`,
  `entryNotionalStable` via the shared `_priceFromTick()`, snapshot written before the
  `dt=0` baseline `_accrue()`, `PositionRegistered` emitted. Stack-too-deep (repo keeps
  `via_ir=false`) handled by scoping intermediates + a `_emitPositionRegistered` helper.
  Confirmed with user: owner=sender (MVP), skip re-registration, keep the init guard,
  unconditional registration.
- **Key design points for beforeSwap/afterSwap:**
  - `dynamicFeeBps` always derived (`baseLpFeeBps + bufferBps`), never stored.
  - `afterSwap` must NOT accrue and must NOT iterate positions (O(N) forbidden); it buffers
    accounting and emits `TickUpdated` (lightweight, for Reactive) + `BufferFunded`.
  - `BufferFunded` / `TickUpdated` events and the buffer-contribution math are not yet in src.
- **Carry-ins:**
  - `poolState` mapping wired; `BPS_DENOM` + `LimitingFactor` enum live in src.
  - Position owner attribution: production should attribute the real LP, not the v4 `sender`
    (router). Documented MVP limitation.
  - Open sequencing question for `beforeRemoveLiquidity`: v4 withdrawn out-amounts are
    known only AFTER removal, but spec calls `_computeIL` in `beforeRemoveLiquidity` —
    resolve when wiring those callbacks. See `docs/session-4-computePayout-complete.md`.
- **Tests:** 140 passing, 0 failing.

---

## Completed

- **afterAddLiquidity()** — position registration + `dt=0` accrual baseline. Lifecycle guard
  (`_poolInitialized`), `owner=sender` key (MVP), re-add skip (immutable snapshot), principal =
  `delta - feesAccrued`, live entry tick via `getSlot0`, notional via shared `_priceFromTick`,
  `PositionRegistered` event, `_positionKey`/`_emitPositionRegistered`/`_absToUint128` helpers.
  Full test suite: 10 unit + 3 fuzz + 3 invariant (PositionLifecycleInvariant + handler) +
  1 integration (real PoolManager + router, live non-zero tick). (+17 tests → 140 total)
  -> docs/session-6-afterAddLiquidity-complete.md
- **Pool setup (three-phase)** — stagePoolConfig() + \_beforeInitialize() commit +
  setReactiveContract(); owner immutable (explicit ctor arg) + onlyOwner, hard-bound
  constants, PendingPoolSetup struct, setup mappings, 3 events, 16 errors. Full test
  suite: 32 unit + 3 fuzz (StagePoolConfigFuzz) + 6 invariant (PoolSetupInvariant +
  handler) + 4 integration (real PoolManager.initialize round-trip). Deploy script and
  harness updated for the owner ctor param. (+45 tests → 123 total)
  -> docs/session-5-pool-setup-complete.md
- **\_accrue()** — engine + shared pure helper \_accrueEarned(), supporting state
  (PoolConfig/PoolState/PositionState, mappings, AccrualUpdated), full test suite.
  -> docs/session-2-accrue-complete.md, docs/session1-accrue-decisions.md
- **\_computeIL()** — IL primitive + shared pure \_priceFromTick() helper (raw-ratio,
  decimal-agnostic; resolves Risk 6); full test suite (14 unit + 8 fuzz + 3 invariant).
  -> docs/session-3-computeIL-complete.md
- **\_computePayout()** — three-cap logic + LimitingFactor enum; pure \_computePayoutAmount()
  core + storage-reading wrapper; added BPS_DENOM, LimitingFactor enum, poolState mapping;
  full test suite (15 unit + 4 fuzz + 2 settlement invariants).
  -> docs/session-4-computePayout-complete.md
- **Scaffold & infra** — hook skeleton, getHookPermissions(), deploy scripts
  (DeployRangeGuardHook.s.sol, HelperConfig.s.sol), BaseRangeGuardTest, RangeGuardHookHarness,
  DYNAMIC_FEE_FLAG enforcement, documentation system.
- **CI / process** — GitHub Actions (fmt + build + test, Foundry pinned 1.3.5); deploy flow
  runs without PRIVATE_KEY (envOr fallback); main protected (PR + green CI required).

---

## Roadmap

### Phase 1: Core Accounting Primitives

- [x] \_accrue() (impl + unit + fuzz + invariant)
- [x] \_computeIL() (impl + unit + fuzz + invariant; shared \_priceFromTick helper)
- [x] \_computePayout() (impl + unit + fuzz + invariant; three-cap logic + LimitingFactor)

### Phase 2: Hook Callbacks

Pool setup + afterAddLiquidity wired; remaining callbacks are selector-returning skeletons.

- [x] Pool setup: stagePoolConfig() + \_beforeInitialize() commit + setReactiveContract()
      (three-phase pool bring-up; replaces original "beforeInitialize config decode" design;
      see docs/spec-amendment-beforeInitialize-config-split.md)
- [x] afterAddLiquidity() (register position, baseline \_accrue(); +17 tests, live-tick integration)
- [ ] beforeSwap() (return derived dynamic fee) ← current
- [ ] afterSwap() (buffer funding + TickUpdated; no accrual)
- [ ] beforeRemoveLiquidity() (eligibility -> \_accrue -> \_computeIL -> \_computePayout)
- [ ] afterRemoveLiquidity() (execute payout, update buffer, clear state)

### Phase 3: Integration Testing

- [ ] Full LP lifecycle
- [ ] Coverage accrual lifecycle
- [ ] Buffer funding lifecycle
- [ ] Settlement lifecycle

### Phase 4: Protocol Invariants (cross-cutting)

- [ ] Accounting invariants (partial: coverage accounting done with \_accrue())
- [ ] Lifecycle invariants
- [ ] Settlement invariants
- [ ] Authorization invariants

### Phase 5: Deployment Readiness on Anvil

- [ ] Anvil deployment
- [ ] Security review

### Phase 6: Deployment Readiness on Sepolia

- [ ] Sepolia deployment
- [ ] Security review
- [ ] Mainnet readiness review

---

## Testing Infrastructure

Status: COMPLETE

- Deployment: DeployRangeGuardHook.s.sol (runs without PRIVATE_KEY via envOr), HelperConfig.s.sol
- Shared harness: BaseRangeGuardTest (canonical deployment for all suites)
- Internal-access harness: RangeGuardHookHarness (seeders + exposed internals; test-only)
- CI: .github/workflows/ci.yml — fmt check + build + test on every PR (Foundry pinned 1.3.5)
