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

- **Active target:** \_computePayout() (next). \_computeIL() COMPLETE.
- \_computeIL pricing: raw-ratio, decimal-agnostic (Risk 6 resolved). Shared
  \_priceFromTick() helper (TickMath -> FullMath, raw token1/token0 x PRICE_PRECISION);
  reused later by afterAddLiquidity for P_entry. Both functions pure. NatSpec documents
  spot-price manipulation risk + rounding direction.
- Progress (\_computeIL): [x] design [x] implement [x] unit [x] fuzz [x] invariant
- **Tests:** 57 passing, 0 failing. \_computeIL: unit test/unit/ComputeIL.t.sol (14),
  fuzz test/fuzz/ComputeILFuzz.t.sol (8 @1000 runs), invariant
  test/invariant/SettlementInvariant.t.sol (3 @500x100, 0 reverts).

---

## Completed

- **\_accrue()** — engine + shared pure helper \_accrueEarned(), supporting state
  (PoolConfig/PoolState/PositionState, mappings, AccrualUpdated), full test suite.
  -> docs/session-2-accrue-complete.md, docs/session1-accrue-decisions.md
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
- [ ] \_computePayout() <- NEXT (three-cap logic + LimitingFactor)

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
