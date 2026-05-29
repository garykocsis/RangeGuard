# Session 3 — `_computeIL()` Complete

Date: 2026-05-29
Scope: Implement and fully test the impermanent-loss primitive `_computeIL()` and the
shared tick→price helper `_priceFromTick()`.
Result: ✅ Complete — implementation + unit + fuzz + invariant tests, all passing.

---

## 1. What Was Implemented

**`_computeIL(PositionState memory pos, uint128 outAmt0, uint128 outAmt1, int24 exitTick)`**
— computes raw impermanent loss in stable (token1) units for a settling position:
```
P_exit   = _priceFromTick(exitTick)
V_HODL   = entryAmt1 + entryAmt0 * P_exit / PRICE_PRECISION   // value if entry held
V_actual = outAmt1   + outAmt0   * P_exit / PRICE_PRECISION   // withdrawn value (incl. fees)
IL_raw   = max(0, V_HODL - V_actual)
```
`pure` — reads only the in-memory snapshot, never touches storage, never mutates the entry
snapshot. Uses `FullMath.mulDiv` for every multiplication that could exceed uint256.

**`_priceFromTick(int24 tick)` (internal `pure` helper)** — converts a tick to the raw
token1/token0 ratio scaled by `PRICE_PRECISION`:
```
sqrtP    = TickMath.getSqrtPriceAtTick(tick)
priceX96 = FullMath.mulDiv(sqrtP, sqrtP, Q96)            // raw ratio * 2^96 (overflow-safe)
priceX18 = FullMath.mulDiv(priceX96, PRICE_PRECISION, Q96)
```
Shared so that `afterAddLiquidity` (Phase 2) can compute `P_entry` with the identical
convention — no duplicated price logic. Rounds DOWN (both mulDiv steps truncate).

**Supporting additions:**
- Constant `PRICE_PRECISION = 1e18`.
- Imports `TickMath`, `FullMath`, `FixedPoint96` from v4-core.

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/ComputeIL.t.sol` | 14 unit tests (price anchors/monotonicity, zero-IL floor, loss path, deposit Cases A/B/C, price application, extreme MIN/MAX ticks, 18-decimal numeraire). |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 property fuzz tests (price monotonic in tick; IL <= V_HODL; IL == max(0, V_HODL - V_actual); zero when withdrawal covers entry; IL non-increasing in withdrawal; monotonic in price when losing; scale-invariance + closed form at parity). |
| `test/invariant/SettlementInvariant.t.sol` | 3 settlement invariants, each mapped to invariant-mapping.md. |
| `test/invariant/handlers/ComputeILHandler.sol` | Invariant handler driving randomized IL computation against a fixed seeded snapshot with high-water/relation ghosts. |
| `docs/session-3-computeIL-complete.md` | This summary. |

---

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | Added `_computeIL()` + `_priceFromTick()` + `PRICE_PRECISION` + 3 lib imports. `_accrue()`/state untouched. |
| `test/harness/RangeGuardHookHarness.sol` | Added `exposed_computeIL()` and `exposed_priceFromTick()`. |
| `project-status.md` | Now/Roadmap advanced through impl → unit → fuzz → invariant; `_computeIL()` ticked, `_computePayout()` set as next. |

---

## 4. Design Decisions Made

1. **Raw-ratio pricing (decimal-agnostic)** — `P_exit` is the raw token1/token0 ratio ×
   PRICE_PRECISION. Because `entryAmt*`/`outAmt*` are raw amounts, `rawToken0 * P / PREC`
   lands directly in raw token1 units; token decimals are implicit. **No decimals stored
   or hardcoded.** Resolves Risk 6. Works identically for 6/18 and 18/18 pools.
   Unit check: `1e18 wei × 2e9 / 1e18 = 2000e6 USDC` ✓.
2. **PRICE_PRECISION = 1e18.**
3. **`_computeIL` takes `PositionState memory pos`** — matches spec §7.
4. **`pure`, not `view`** — compiler-enforced no storage access (safer than spec's `view`).
5. **Shared `_priceFromTick` helper** — reused by `afterAddLiquidity` for `P_entry` later;
   avoids duplicated price logic (CLAUDE.md).
6. **Human-readable price view deferred** — frontend/dashboard concern, out of scope.
7. **Rounding DOWN**, applied identically to V_HODL and V_actual (largely offsets); IL
   floored at 0. Documented in NatSpec.
8. **Overflow** — `FullMath.mulDiv` carries the 512-bit intermediate (sqrtP² safe); the
   only uint256 corner is max-uint128 amount AND near-MAX_TICK simultaneously
   (economically unreachable) — handled by bounding fuzz inputs.

---

## 5. Tests Passing

Full suite: **57 passing, 0 failing.**

| Suite | Count | Notes |
|-------|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 1 | permissions |
| `test/unit/Accrue.t.sol` | 17 | (session 2) |
| `test/unit/ComputeIL.t.sol` | 14 | edge cases incl. Cases A/B/C, extremes, 18-dec |
| `test/fuzz/AccrueFuzz.t.sol` | 8 | (session 2) |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 | 1000 runs each |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 | (session 2) |
| `test/invariant/SettlementInvariant.t.sol` | 3 | 500 × 100 = 50,000 calls, 0 reverts |

Settlement invariants → invariant-mapping.md:
- `invariant_ILRawNeverNegative` → "IL_raw must never be negative" (floored difference; no wraparound)
- `invariant_ILNeverExceedsHodlValue` → derived bound supporting the payout caps (payout ≤ IL_raw ≤ V_HODL)
- `invariant_EntrySnapshotsRemainImmutable` → "settlement must never modify immutable entry snapshots"

---

## 6. Deferred to Next Session

- **`_computePayout()`** — next build-order target (Phase 1, last primitive). Three caps:
  `IL_covered = IL_raw * maxPayoutPctOfIl / BPS_DENOM`,
  `bufferCap = bufferBalanceStable * maxPayoutPctOfBuffer / BPS_DENOM`,
  `payout = min(IL_covered, earnedCoverageStable, bufferCap)`, plus the `LimitingFactor`
  enum (NONE / IL_CAP / COVERAGE_CAP / BUFFER_CAP). Will need `BPS_DENOM` constant, the
  `LimitingFactor` enum, and reads of `poolState.bufferBalanceStable` (PoolState mapping
  not yet wired — confirm whether to add it now). The payout-cap invariants referenced
  above get their direct tests here.
- **`getEarnedCoverage()`** — live simulating view (needs current tick / StateLibrary);
  will reuse `_accrueEarned()` read-only.
- **Human-readable price view** (USDC/ETH for dashboard).
- **Hook callback wiring** (Phase 2), incl. resolving the out-amount sequencing question
  (withdrawn amounts known only after removal, but spec calls `_computeIL` in
  `beforeRemoveLiquidity`).
