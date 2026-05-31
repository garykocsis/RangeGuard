# Session 6 — afterAddLiquidity() Complete

Date: 2026-05-30
Scope: Implement and fully test `afterAddLiquidity()` — the first LP lifecycle callback:
derive entry amounts from the liquidity delta, snapshot the position, seed the accrual
baseline at `dt == 0`, and emit `PositionRegistered`.
Result: ✅ Complete — implementation + unit + fuzz + invariant + integration tests, all
passing. Advances **Phase 2 (Hook Callbacks)** to its second completed item.

---

## 1. What Was Implemented

**`_afterAddLiquidity(address sender, PoolKey key, ModifyLiquidityParams params, BalanceDelta delta, BalanceDelta feesAccrued, bytes)`**
— `internal override`, PoolManager-gated by `BaseHook.afterAddLiquidity`'s `onlyPoolManager`.
Flow (CEI, snapshot written before the baseline accrual):

```
!_poolInitialized[id]                 -> PoolNotInitialized   (lifecycle guard)
positionKey = _positionKey(sender, tickLower, tickUpper, salt)
pos.active                            -> early-return (skip re-registration; snapshot preserved)
principal      = delta - feesAccrued            (nets fees out of the entry snapshot)
entryAmt0/1    = |principal.amount0/1|          (adds make caller delta negative)
currentTick    = i_manager.getSlot0(id)         (live entry tick)
entryNotional  = entryAmt1 + entryAmt0 * _priceFromTick(currentTick) / PRICE_PRECISION
write snapshot: entryAmt0/1, entryTick, tickLower/Upper, depositTime=now,
                lastAccrualTime=now, active=true, entryNotionalStable
emit PositionRegistered(...)
_accrue(id, positionKey, currentTick)           (dt == 0 -> opening AccrualUpdated, zero delta)
return (afterAddLiquidity.selector, delta)
```

Key correctness points:

- **`dt == 0` ordering:** `lastAccrualTime` is set to `block.timestamp` *before* `_accrue()`,
  so the baseline call observes `dt == 0` and accrues nothing — it only emits the opening
  `AccrualUpdated` line for the coverage report. (A fresh slot's `lastAccrualTime == 0` would
  otherwise have produced a huge `dt`.)
- **Principal vs fees:** entry amounts record `delta - feesAccrued` (fresh adds have
  `feesAccrued == 0`; the subtraction is the correct general form so prior fees never inflate
  the snapshot).
- **Re-add guard:** a top-up to an already-active position is a no-op for accounting — the
  immutable entry snapshot is preserved (single-range / full-withdrawal MVP scope).
- **Unconditional registration:** out-of-range deposits still register; `_accrue` gates the
  delta to zero (`isInRange == false`).
- **Shared price convention:** `entryNotionalStable` uses the same `_priceFromTick` helper as
  `_computeIL`, so entry and settlement can never diverge.

**Supporting additions to `src/RangeGuardHook.sol`:**
- `import {StateLibrary}` + `using StateLibrary for IPoolManager;` (live tick via `getSlot0`).
- `event PositionRegistered(poolId, positionKey, owner, tickLower, tickUpper, entryAmt0,
  entryAmt1, entryNotionalStable, entryTick, depositTime, coverageApr, secondsPerYear)` — every
  field sourced from the immutable snapshot so the coverage report renders the entry line from
  this one event.
- `_positionKey(owner_, tickLower, tickUpper, salt)` — internal pure; `keccak256(abi.encode(...))`,
  pool-scoped by the outer `positions[poolId]` mapping.
- `_emitPositionRegistered(...)` (private) — isolates the 12-field emit in its own stack frame.
- `_absToUint128(int128)` (private) — magnitude via `int256` widening (avoids the
  `type(int128).min` negation edge); new PRIVATE section header per CLAUDE.md ordering.

**Stack-too-deep:** the repo keeps `via_ir = false`; resolved by scoping the entry-amount
intermediates in a `{}` block and moving the emit into `_emitPositionRegistered` — no build
config change.

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/AfterAddLiquidity.t.sol` | 10 unit tests: not-initialized guard, registration (amounts/ticks/notional), dt=0 baseline, `PositionRegistered` + baseline `AccrualUpdated` emission, fee-netting, re-add immutability, out-of-range registration, key derivation. |
| `test/fuzz/AfterAddLiquidityFuzz.t.sol` | 3 fuzz tests: snapshot consistency (amounts == |delta|, notional, seeded clock), notional monotonic in the stable leg, re-add never mutates the snapshot. |
| `test/invariant/handlers/AfterAddLiquidityHandler.sol` | Registration handler over a self-owned harness; randomized owners/amounts/ranges/salts + re-adds; ghost snapshot of each key's first registration. |
| `test/invariant/PositionLifecycleInvariant.t.sol` | 3 invariants: entry snapshot immutable after registration, registered positions active with a deposit-seeded clock, registration accrues nothing. |
| `docs/session-6-afterAddLiquidity-complete.md` | This summary. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | StateLibrary import + using; `PositionRegistered` event; implemented `_afterAddLiquidity`; added `_positionKey`, `_emitPositionRegistered`, `_absToUint128` (+ PRIVATE section). Accrual/IL/payout and pool-setup untouched. |
| `test/harness/RangeGuardHookHarness.sol` | Added `exposed_afterAddLiquidity` and `exposed_positionKey`; imports for `PoolKey`/`ModifyLiquidityParams`/`BalanceDelta`. |
| `test/integration/AfterAddLiquidity.t.sol` | 1 end-to-end test through the REAL PoolManager + modify-liquidity router: proves the live (non-zero) entry tick via `getSlot0` and the real router-produced principal delta. |
| `project-status.md` | `afterAddLiquidity()` ticked; Now advanced to `beforeSwap()`; 140 tests recorded. |
| `CLAUDE.md` | Three sections updated (Current Implementation Status, Implementation Order, Current Session State). |

---

## 4. Design Decisions Made (confirmed with user)

1. **`owner == sender`** for the position key — the v4 `sender` is the router/caller to the
   PoolManager, not necessarily the end LP. Accepted for MVP; documented as a known limitation
   (production would attribute the real LP, e.g. via `hookData` or a posm integration).
2. **Skip re-registration** on an already-active position — preserves the immutable entry
   snapshot; consistent with single-range / full-withdrawal-only MVP scope.
3. **`_poolInitialized` guard** retained (lifecycle invariant) even though v4 cannot add
   liquidity to an uninitialized pool — cheap defense-in-depth + precise error.
4. **Unconditional registration** — registration does not gate on in-range status at deposit;
   `_accrue` handles range-gating (Cases A/C start out of range and accrue zero).

---

## 5. Tests Passing

Full suite: **140 passing, 0 failing.** (+17 from this session: 10 unit + 3 fuzz + 3 invariant
+ 1 integration.)

| Suite | Count |
|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 33 |
| `test/unit/Accrue.t.sol` | 17 |
| `test/unit/ComputeIL.t.sol` | 14 |
| `test/unit/ComputePayout.t.sol` | 15 |
| `test/unit/AfterAddLiquidity.t.sol` | 10 |
| `test/fuzz/AccrueFuzz.t.sol` | 8 |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 |
| `test/fuzz/StagePoolConfigFuzz.t.sol` | 3 |
| `test/fuzz/AfterAddLiquidityFuzz.t.sol` | 3 |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 |
| `test/invariant/SettlementInvariant.t.sol` | 5 |
| `test/invariant/PoolSetupInvariant.t.sol` | 6 |
| `test/invariant/PositionLifecycleInvariant.t.sol` | 3 |
| `test/integration/PoolSetup.t.sol` | 4 |
| `test/integration/AfterAddLiquidity.t.sol` | 1 |

Position-lifecycle invariants → invariant-mapping.md:
- `invariant_EntrySnapshotImmutableAfterRegistration` → "accrual must never modify entry
  position snapshots" / "immutable snapshots must never mutate after registration"
- `invariant_RegisteredPositionsActiveWithSeededClock` → "active positions must always have
  valid entry snapshots" / "active positions must always have initialized accrual state"
- `invariant_RegistrationAccruesNothing` → "earnedCoverageStable must never decrease" /
  "zero dt must produce zero accrual delta"

Invariant run: 500 runs × 50,000 calls, **0 reverts**. `forge fmt --check` passes; `forge build`
clean (only the expected "restrict to pure" notes on the remaining unimplemented stubs).

**Test seam note:** unit/fuzz/invariant suites drive the harness internal directly, so the
underlying PoolManager pool is never initialized and `getSlot0` returns tick 0 (P_entry == 1e18).
This is a real call to the real PoolManager's `extsload` (not a stub); non-zero-tick behavior is
covered end-to-end by the integration test (entry tick ~99 at price 1.01).

---

## 6. Deferred to Next Session (Phase 2 — `beforeSwap()` / `afterSwap()`)

- **`beforeSwap()`** — return the derived dynamic fee (`baseLpFeeBps + bufferBps`); no position
  state touched, no accrual.
- **`afterSwap()`** — buffer funding only (`bufferBalanceStable += contribution`,
  `BufferFunded`) + `TickUpdated` for the Reactive Network; never iterate positions, never accrue.
- **IL settlement sequencing** (carried from sessions 3–4) — spec calls `_computeIL` in
  `beforeRemoveLiquidity`, but v4 withdrawn `outAmt0/outAmt1` are known only *after* removal;
  resolve when wiring `beforeRemoveLiquidity` / `afterRemoveLiquidity`.
- **`onlyReactive` + `emitOutOfRange`/`emitBackInRange`** — implement with the reactive phase;
  guard on `_reactiveSet[id]`.
- **Position owner attribution** — production should attribute the real LP rather than the v4
  `sender` (router).
