# RangeGuard Project Status

Last Updated: 2026-05-31 (Session 7 — beforeSwap / afterSwap)

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

- **Active target:** `beforeRemoveLiquidity()` — `minHoldSeconds` eligibility gate (→
  `IneligibleClaim`, skip all accrual/IL/payout when not met), then final `_accrue()` →
  `_computeIL()` → `_computePayout()` → store `pendingPayout`; emit `AccrualUpdated`. Then
  `afterRemoveLiquidity()` — execute `pendingPayout`, update buffer + `totalPaidOutStable`,
  clear state; emit `ClaimSettled` / `PartialPayout` / `NoClaim`.
- **Just completed:** `beforeSwap()` + `afterSwap()`. `beforeSwap` (now `view`) returns the
  derived fee `uint24(baseLpFeeBps + bufferBps) | LPFeeLibrary.OVERRIDE_FEE_FLAG` and
  `ZERO_DELTA`; reads `poolConfig` only. `afterSwap` books a NOTIONAL buffer credit
  `contribution = |delta.amount1()| * bufferBps / FEE_DENOM` (FEE_DENOM = 1e6, v4 pips),
  increments `bufferBalanceStable` + `totalSkimmedStable`, emits `BufferFunded` (skipped when 0)
  + `TickUpdated` (every swap, post-swap tick via `getSlot0`); never accrues, never iterates.
  Confirmed with user: add OVERRIDE flag, FEE_DENOM = 1e6, skip BufferFunded on zero contribution.
- **Locked decisions resolved this session (3 v4 risks):**
  - **OVERRIDE_FEE_FLAG required** — without it v4 ignores the returned fee (falls back to
    `slot0.lpFee()` == 0 on a dynamic pool). Differential integration test proves it is charged.
  - **FEE_DENOM = 1_000_000 (v4 pips), NOT BPS_DENOM** — fee fields are pips despite "Bps" names
    (3000 = 0.30%); `BPS_DENOM` (1e4) would credit the buffer 100× too fast. Payout caps still 1e4.
  - **Notional buffer (MVP)** — no token delta taken; real backing via `seedBuffer()`.
- **Carry-ins:**
  - `poolState`, `BPS_DENOM`, `FEE_DENOM`, `LimitingFactor`, `BufferFunded`/`TickUpdated` live in src.
  - Position owner attribution: production should attribute the real LP, not the v4 `sender`
    (router). Documented MVP limitation.
  - **Open sequencing question for `beforeRemoveLiquidity` (active next):** v4 withdrawn
    out-amounts are known only AFTER removal, but spec calls `_computeIL` in
    `beforeRemoveLiquidity` — likely compute IL/payout in `afterRemoveLiquidity` from realized
    out-amounts. See `docs/session-4-computePayout-complete.md`.
  - `afterRemoveLiquidity` is where the notional buffer meets real custody — confirm
    payout-vs-`bufferBalanceStable` solvency handling. `seedBuffer()` still to implement.
- **Tests:** 161 passing, 0 failing.

---

## Completed

- **beforeSwap() / afterSwap()** — swap-path callbacks. `beforeSwap` (`view`) returns the derived
  dynamic fee `(baseLpFeeBps + bufferBps) | OVERRIDE_FEE_FLAG` + `ZERO_DELTA`, reads `poolConfig`
  only. `afterSwap` books the notional buffer credit (`|delta.amount1()| * bufferBps / FEE_DENOM`,
  FEE_DENOM = 1e6), increments `bufferBalanceStable` + `totalSkimmedStable`, emits `BufferFunded`
  (skipped on zero) + `TickUpdated` (every swap); no accrual, no position iteration. Added
  `FEE_DENOM` constant + two events; reused `_absToUint128`. Full test suite: 13 unit + 3 fuzz +
  3 invariant (BufferFundingInvariant + handler) + 2 integration (real swap + differential
  fee-override proof). (+21 tests → 161 total)
  -> docs/session-7-beforeSwap-afterSwap-complete.md
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
- [x] beforeSwap() (return derived dynamic fee + OVERRIDE flag; view, no state touched)
- [x] afterSwap() (notional buffer funding + TickUpdated; no accrual, no iteration; +21 tests)
- [ ] beforeRemoveLiquidity() (eligibility -> \_accrue -> \_computeIL -> \_computePayout) ← current
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
