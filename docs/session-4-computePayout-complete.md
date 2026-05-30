# Session 4 — `_computePayout()` Complete

Date: 2026-05-29
Scope: Implement and fully test the three-cap settlement payout primitive `_computePayout()`
and its pure core `_computePayoutAmount()`, plus the supporting `LimitingFactor` enum,
`BPS_DENOM` constant, and `poolState` mapping.
Result: ✅ Complete — implementation + unit + fuzz + invariant tests, all passing.
This closes **Phase 1 (Core Accounting Primitives)**.

---

## 1. What Was Implemented

**`_computePayoutAmount(uint256 ILRaw, uint256 earned, uint256 bufferBalance, uint16 maxPayoutPctOfIl, uint16 maxPayoutPctOfBuffer)`**
— `pure` core implementing the three caps and `LimitingFactor` selection:

```
if ILRaw == 0: return (0, NONE)            // only NONE path
IL_covered = mulDiv(ILRaw,  maxPayoutPctOfIl,     BPS_DENOM)   // round down
bufferCap  = mulDiv(buffer, maxPayoutPctOfBuffer, BPS_DENOM)   // round down
payout = IL_covered;        factor = IL_CAP
if earned    < payout: payout = earned;    factor = COVERAGE_CAP
if bufferCap < payout: payout = bufferCap; factor = BUFFER_CAP
```

Strict `<` ⇒ ties resolve to the earlier (higher-precedence) cap: `IL_CAP → COVERAGE_CAP → BUFFER_CAP`.

**`_computePayout(PoolId poolId, PositionState memory pos, uint256 ILRaw)`** — `view` wrapper
(spec §7 shape) that loads `maxPayoutPctOfIl`/`maxPayoutPctOfBuffer` from `poolConfig`,
`bufferBalanceStable` from `poolState`, and `earnedCoverageStable` from the in-memory
snapshot, then delegates to the pure core. Read-only: no state mutation, no buffer
decrement, no events. Same drift-free split as `_accrue`/`_accrueEarned` and
`_computeIL`/`_priceFromTick`.

**Supporting additions:**
- `enum LimitingFactor { NONE, IL_CAP, COVERAGE_CAP, BUFFER_CAP }` (TYPE DECLARATIONS).
- `uint256 internal constant BPS_DENOM = 10_000;`
- `mapping(PoolId => PoolState) public poolState;` (the `PoolState` struct already existed).

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/ComputePayout.t.sol` | 15 unit tests (zero-IL→NONE; each cap binding; empty buffer; zero earned; IL-rounds-to-zero quirk; three tie permutations; max caps; near-uint256-max overflow safety; 3 wrapper-wiring tests). |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 property fuzz tests (payout ≤ every cap and ≤ raw buffer; payout == min of the three; factor names a cap whose value == payout; zero IL ⇒ (0, NONE)). |
| `test/invariant/handlers/ComputePayoutHandler.sol` | Invariant handler driving randomized payout computation with independently-derived cap ghosts; caps bounded to the valid `[0, 10000]` config domain. |
| `docs/session-4-computePayout-complete.md` | This summary. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | Added `LimitingFactor` enum, `BPS_DENOM`, `poolState` mapping, `_computePayout()` + `_computePayoutAmount()`. `_accrue`/`_computeIL`/state untouched. |
| `test/harness/RangeGuardHookHarness.sol` | Added `seedPoolState()`, `exposed_computePayout()`, `exposed_computePayoutAmount()`. |
| `test/invariant/SettlementInvariant.t.sol` | Added `ComputePayoutHandler` as a second target + 2 invariants (`invariant_PayoutNeverExceedsAnyCap`, `invariant_PayoutFactorMatchesBindingCap`). |
| `project-status.md` | Phase 1 closed; `_computePayout()` ticked; Now advanced to Phase 2 beforeInitialize(). |

---

## 4. Design Decisions Made

1. **Pure core + view wrapper** (confirmed with user) — mirrors the established pattern so a
   future `getEstimatedPayout()` view can reuse the exact cap logic without drift.
2. **`poolState` mapping wired now** (confirmed with user) — `_computePayout` reads the real
   `bufferBalanceStable`; no stubbing/rework when callbacks land.
3. **`FullMath.mulDiv` for both caps** — a 100% cap on a near-uint256-max IL or buffer cannot
   overflow (verified by `test_..._WhenLargeILAtMaxCap_DoesNotOverflow`).
4. **Round DOWN** — consistent with `_accrueEarned`/`_priceFromTick`; conservative for the
   buffer.
5. **`LimitingFactor` precedence + semantics** — ties go to the earlier cap; `NONE` is
   returned **iff** `ILRaw == 0`. Documented quirk: `ILRaw > 0` but `IL_covered`
   rounds to 0 ⇒ `(0, IL_CAP)` (never NONE).
6. **Compute-only** — `_computePayout` never decrements the buffer or writes `pendingPayout`;
   those belong to `afterRemoveLiquidity` (Phase 2).
7. **`payout ≤ bufferBalanceStable`** holds transitively because `maxPayoutPctOfBuffer ≤
   BPS_DENOM` is the config bound (enforced at init in Phase 2). Fuzz/invariant inputs are
   bounded to `[0, 10000]` to stay in that valid-config domain.

---

## 5. Tests Passing

Full suite: **78 passing, 0 failing.** (+21 from this session: 15 unit + 4 fuzz + 2 invariant.)

| Suite | Count |
|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 1 |
| `test/unit/Accrue.t.sol` | 17 |
| `test/unit/ComputeIL.t.sol` | 14 |
| `test/unit/ComputePayout.t.sol` | 15 |
| `test/fuzz/AccrueFuzz.t.sol` | 8 |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 |
| `test/invariant/SettlementInvariant.t.sol` | 5 (3 IL + 2 payout) |

Payout invariants → invariant-mapping.md (Settlement):
- `invariant_PayoutNeverExceedsAnyCap` → "payout must never exceed IL_covered / earnedCoverageStable / bufferCap / bufferBalanceStable / configured payout caps"
- `invariant_PayoutFactorMatchesBindingCap` → supports an unambiguous LimitingFactor per settlement

`forge fmt --check` passes.

---

## 6. Deferred to Next Session (Phase 2 — Hook Callbacks)

- **beforeInitialize()** — decode `PoolConfig`/`reactiveContract` from hookData, enforce
  `DYNAMIC_FEE_FLAG`, validate config bounds (incl. `maxPayoutPct* ≤ BPS_DENOM`, on which the
  buffer-payout invariant depends), atomic init.
- **IL settlement sequencing** — spec calls `_computeIL` in `beforeRemoveLiquidity`, but v4
  withdrawn `outAmt0/outAmt1` are only known *after* removal. Resolve the ordering when
  wiring `beforeRemoveLiquidity`/`afterRemoveLiquidity` (still carried from session 3).
- **`_computePayout` caller contract** — must run final `_accrue()` first and pass the
  post-accrual `pos` (or reload `earnedCoverageStable`) so the wrapper reads the fresh value.
- **`getEstimatedPayout()` view** — will reuse `_computePayoutAmount` read-only (and
  `_computeIL` + a simulated final accrual).

---

## 7. Note for Maintainer

`project-status.md` was found with stray/truncated text (~lines 85–91: "the file is fine.",
"wait, ignore that", "... (rest unchanged)") and a missing Phase 6 / full Testing
Infrastructure section, present at the start of this session and not introduced by this work.
Only the Now/Completed/Roadmap sections were edited (targeted edits); the stray region was
left untouched for the maintainer to restore.
