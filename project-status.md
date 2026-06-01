# RangeGuard Project Status

Last Updated: 2026-05-31 (Session 8 — beforeRemoveLiquidity / afterRemoveLiquidity)

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

- **Active target:** `checkpoint()` — permissionless single-position accrual driver and primary
  Reactive Network entry point. `require(pos.active)`, `block.timestamp - lastAccrualTime >=
  cfg.minCheckpointInterval` (else `TOO_SOON`), read current tick via `getSlot0`, `_accrue(poolId,
  positionKey, currentTick)`, emit `Checkpointed`. Pairs next with `seedBuffer()` (real custody).
- **Just completed:** `beforeRemoveLiquidity()` + `afterRemoveLiquidity()`. The settlement split is
  v4-native: `beforeRemoveLiquidity` (now `view`) is VALIDATION ONLY — `PositionNotActive` if
  inactive, `PartialWithdrawalNotSupported` if `uint256(-liquidityDelta) != pos.liquidity` (MVP
  full-withdrawal). ALL settlement runs in `afterRemoveLiquidity`, because withdrawn out-amounts
  exist only in the removal `BalanceDelta`: minHold hard gate (→ `IneligibleClaim` + clear), then
  final `_accrue()` (exit tick via `getSlot0`) → `_computeIL()` on the FULL delta (fees included)
  → `_computePayout()` (three caps) → strict-CEI payout (clear position + update buffer BEFORE the
  real token1 transfer) → `ClaimSettled` / `PartialPayout` / `NoClaim`.
- **Locked decisions resolved this session:**
  - **PositionState change** — dropped `pendingPayout`, added `uint128 liquidity` (full position
    liquidity, captured at registration; the withdrawal gate compares against it).
  - **R1: re-add reverts `PositionAlreadyRegistered`** — one add per position (a silent skip would
    desync `pos.liquidity` and brick withdrawal).
  - **R3: `IL_raw > 0` but `payout == 0` → `PartialPayout(requested=IL_covered, actual=0)`**;
    `NoClaim` strictly for `IL_raw == 0`.
  - **Strict CEI** — buffer/`totalPaidOut` updates moved BEFORE the transfer (superset of the
    locked "clear state before transfer"; safer vs reentrant tokens).
  - **R2: notional buffer vs real custody** — accepted/documented; payout is a real token1 transfer
    of the hook's own balance; ledger solvency ≠ real solvency until `seedBuffer()`.
- **Carry-ins:**
  - **`seedBuffer()` still to implement** — provides the real token1 custody the payout transfer
    depends on (integration test mints token1 to the hook to stand in for it).
  - Position owner attribution: payout recipient is the v4 `sender` (owner=sender MVP).
  - **Doc drift (R5, deferred):** `invariant-mapping.md` + `state-machine.md` still reference
    `pendingPayout` / `PendingSettlement`; spec.md §6/§7 still narrate the old flow. Fix in a
    separate doc pass.
- **Tests:** 181 passing, 0 failing.

---

## Completed

- **beforeRemoveLiquidity() / afterRemoveLiquidity()** — withdrawal/settlement callbacks.
  `beforeRemoveLiquidity` (`view`) validates only: active position + full-withdrawal gate
  (`removed == pos.liquidity`). `afterRemoveLiquidity` runs all settlement from the realized
  removal `BalanceDelta`: minHold hard gate (`IneligibleClaim` + clear), final `_accrue()`
  (exit tick via `getSlot0`), `_computeIL()` on the fees-included delta, `_computePayout()`
  three-cap, strict-CEI payout (clear + buffer update before a real token1 transfer),
  `ClaimSettled` / `PartialPayout` / `NoClaim`. PositionState dropped `pendingPayout`, added
  `uint128 liquidity`; re-add now reverts `PositionAlreadyRegistered`. Full test suite: 14 unit
  + 2 fuzz + 3 invariant (SettlementExecution + handler) + 1 integration (real add→swap→warp→
  remove→ClaimSettled, custody/buffer/paidOut reconciled). (+20 tests → 181 total)
  -> docs/session-8-remove-liquidity-complete.md
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
- [x] beforeRemoveLiquidity() (validation only: active + full-withdrawal gate; +6 unit tests)
- [x] afterRemoveLiquidity() (v4-native settlement: minHold gate -> final \_accrue -> \_computeIL ->
      \_computePayout -> strict-CEI payout; ClaimSettled/PartialPayout/NoClaim; +14 tests)

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
