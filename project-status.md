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

- **Active target:** \_computeIL()
- **Needs a design pass first** — pulls in deferred Risk 6 work: tickToPrice() and
  ETH(18)/USDC(6) decimal adjustment. (See docs/session1-accrue-decisions.md Risk 6.)
- Progress: [ ] design  [ ] implement  [ ] unit  [ ] fuzz  [ ] invariant
- **Tests:** 32 passing, 0 failing (1 permissions + 17 unit + 8 fuzz @1000 runs +
  6 invariant @500x100, 0 reverts).

---

## Completed

- **\_accrue()** — engine + shared pure helper \_accrueEarned(), supporting state
  (PoolConfig/PoolState/PositionState, mappings, AccrualUpdated), full test suite.
  -> docs/session-2-accrue-complete.md, docs/session1-accrue-decisions.md
- **Scaffold & infra** — hook skeleton, getHookPermissions(), deploy scripts
  (DeployRangeGuardHook.s.sol, HelperConfig.s.sol), BaseRangeGuardTest, RangeGuardHookHarness,
  DYNAMIC_FEE_FLAG enforcement, documentation system.

---

## Roadmap

### Phase 1: Core Accounting Primitives

- [x] \_accrue() (impl + unit + fuzz + invariant)
- [ ] \_computeIL() <- NEXT (needs design pass: tickToPrice + decimal adjustment)
- [ ] \_computePayout() (three-cap logic + LimitingFactor)

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

- Deployment: DeployRangeGuardHook.s.sol, HelperConfig.s.sol
- Shared harness: BaseRangeGuardTest (canonical deployment for all suites)
- Internal-access harness: RangeGuardHookHarness (seeders + exposed internals; test-only)
