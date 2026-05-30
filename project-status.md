# RangeGuard Project Status

Last Updated: 2026-05-29

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

- **Active target:** Phase 1 COMPLETE — next is Phase 2 hook callbacks, starting with
  beforeInitialize() (config decode + DYNAMIC_FEE_FLAG enforcement).
- Carry-ins for Phase 2: `poolState` mapping is now wired (added with \_computePayout);
  `BPS_DENOM` + `LimitingFactor` enum live in src. Open sequencing question for
  beforeRemoveLiquidity: v4 withdrawn out-amounts are known only AFTER removal, but spec
  calls \_computeIL in beforeRemoveLiquidity — resolve when wiring callbacks.
  See docs/session-4-computePayout-complete.md (deferred items).
- Progress (\_computePayout): [x] design  [x] implement  [x] unit  [x] fuzz  [x] invariant
- **Tests:** 78 passing, 0 failing.

---

## Completed

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

All currently PARTIAL — selector-returning skeletons only; no logic wired.

- [ ] beforeInitialize() (config decode + DYNAMIC_FEE_FLAG enforcement)
- [ ] afterAddLiquidity() (register position, baseline \_accrue())
- [ ] beforeSwap() (return derived dynamic fee)
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
