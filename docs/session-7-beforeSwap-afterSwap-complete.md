# Session 7 — beforeSwap() / afterSwap() Complete

Date: 2026-05-31
Scope: Implement and fully test the two swap-path callbacks — `beforeSwap()` (return the
derived dynamic LP fee) and `afterSwap()` (book the notional buffer contribution + emit the
lightweight `TickUpdated` for the Reactive Network). No accrual, no position iteration.
Result: ✅ Complete — implementation + unit + fuzz + invariant + integration tests, all
passing. Advances **Phase 2 (Hook Callbacks)** to its third and fourth completed items.

---

## 1. What Was Implemented

**`_beforeSwap(address, PoolKey key, SwapParams, bytes)`** — `internal view override`,
PoolManager-gated by `BaseHook.beforeSwap`'s `onlyPoolManager`. Reads `poolConfig[poolId]`
only; touches zero position/accounting state.

```
derivedFee = uint24(cfg.baseLpFeeBps + cfg.bufferBps) | LPFeeLibrary.OVERRIDE_FEE_FLAG
return (beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, derivedFee)
```

**`_afterSwap(address, PoolKey key, SwapParams, BalanceDelta delta, bytes)`** — `internal
override`. Buffer funding ONLY; never accrues, never iterates positions.

```
stableVolume = |delta.amount1()|                       (token1 = stable numeraire)
contribution = FullMath.mulDiv(stableVolume, cfg.bufferBps, FEE_DENOM)   (rounds down)
if contribution > 0:
    bufferBalanceStable += contribution
    totalSkimmedStable  += contribution
    emit BufferFunded(poolId, contribution, newBufferBalance)
(, newTick,,) = i_manager.getSlot0(poolId)             (post-swap tick)
emit TickUpdated(poolId, newTick, block.timestamp)     (every swap)
return (afterSwap.selector, 0)
```

### Locked design decisions (confirmed with user before coding)

1. **`beforeSwap` returns the OVERRIDE-flagged fee.** The originally-locked return value
   `uint24(base + buffer)` is inert in v4: `Pool.swap` uses
   `lpFeeOverride.isOverride() ? lpFeeOverride.removeOverrideFlag() : slot0.lpFee()`, and
   `isOverride()` tests the `LPFeeLibrary.OVERRIDE_FEE_FLAG` (`0x400000`) bit. Without it v4
   falls back to `slot0.lpFee()` == 0 on a dynamic-fee pool, so swappers would pay 0% and the
   self-funding narrative would be false. **Risk 1 → add the flag.**
2. **`FEE_DENOM = 1_000_000` (v4 pips), not `BPS_DENOM`.** v4 fees are hundredths of a bip
   (`LPFeeLibrary.MAX_LP_FEE == 1_000_000` == 100%), so the config's `baseLpFeeBps`/`bufferBps`
   (3000 = 0.30%, 1000 = 0.10%) are pips despite the "Bps" field names. Buffer-contribution math
   divides by `1_000_000`; using `BPS_DENOM` (10_000) would credit the buffer 100× too fast.
   Payout-cap percentages remain `BPS_DENOM`-based. **Risk 2 → FEE_DENOM = 1e6.**
3. **Skip `BufferFunded` on zero contribution; always emit `TickUpdated`.** A zero-stable-leg or
   sub-threshold swap (`stableVol * bufferBps < 1e6`) writes nothing and emits no `BufferFunded`
   (minimize storage writes), but `TickUpdated` fires on every swap for deterministic Reactive
   subscription. **Risk 3.**

### Key correctness points

- **Notional buffer (MVP).** No token delta is taken (`ZERO_DELTA` / `0` returns;
  `beforeSwapReturnDelta`/`afterSwapReturnDelta` stay `false`). `bufferBalanceStable` is a ledger
  credit; real payout backing comes from `seedBuffer()`. The `maxPayoutPctOfBuffer <= BPS_DENOM`
  bound still caps a single payout at the ledger buffer. Documented MVP limitation.
- **Stable-leg as volume proxy.** Using `|delta.amount1()|` keeps the contribution in the stable
  numeraire with no price conversion and is direction-agnostic (input leg negative, output leg
  positive — magnitude is identical either way). Reuses the existing `_absToUint128(int128)`.
- **No accrual / no iteration.** `afterSwap` has no position key and reads no position storage —
  structurally incapable of accruing or scanning the LP set (O(N) forbidden in the swap path).
- **`totalSkimmedStable`** is incremented alongside `bufferBalanceStable` (cumulative-from-fees
  counter that `getBufferHealth()` will read); additive, does not conflict with the locked
  3-field `BufferFunded` signature.

**Supporting additions to `src/RangeGuardHook.sol`:**
- `FEE_DENOM = 1_000_000` constant (NatSpec explains the pip-vs-bps distinction).
- `event BufferFunded(PoolId indexed poolId, uint256 contribution, uint256 newBufferBalance)`.
- `event TickUpdated(PoolId indexed poolId, int24 newTick, uint256 timestamp)`.
- `_beforeSwap` made `view` (more restrictive override of the non-view base — allowed).
- Reuses `LPFeeLibrary.OVERRIDE_FEE_FLAG`, `FullMath.mulDiv`, `StateLibrary.getSlot0`, and the
  existing `_absToUint128` helper — no new helpers required.

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/BeforeSwap.t.sol` | 4 unit tests: derived fee + override flag, selector + ZERO_DELTA, fee tracks config, no state mutation. |
| `test/unit/AfterSwap.t.sol` | 9 unit tests: buffer increment, pre-seeded add-on-top, direction independence, BufferFunded + TickUpdated emission, zero-stable-leg (no BufferFunded, TickUpdated still fires; verified via recorded logs), sub-threshold rounds to zero, never touches positions, selector + zero hook delta. |
| `test/fuzz/BeforeSwapFuzz.t.sol` | 1 fuzz: fee always == base + buffer with override flag, within v4 bounds, across all valid configs. |
| `test/fuzz/AfterSwapFuzz.t.sol` | 2 fuzz: contribution == \|stableLeg\| * bufferBps / FEE_DENOM (any sign/magnitude/bufferBps); buffer monotonic non-decreasing across swaps. |
| `test/invariant/handlers/AfterSwapHandler.sol` | Swap handler over a self-owned harness; randomized swap deltas + time; ghost sum of contributions; one seeded active position to prove non-accrual. |
| `test/invariant/BufferFundingInvariant.t.sol` | 3 invariants: buffer == summed skims, buffer never exceeds skims, afterSwap never accrues/touches positions. |
| `test/integration/Swap.t.sol` | 2 end-to-end tests through the REAL PoolManager + swap router: (a) a real swap funds the buffer by the realized stable-volume share and TickUpdated reflects the live post-swap tick; (b) **differential proof** that the override fee is actually charged — a fee'd pool returns strictly less output than an identical zero-fee pool for the same input. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | `FEE_DENOM` constant; `BufferFunded`/`TickUpdated` events; implemented `_beforeSwap` (view) + `_afterSwap`. Accrual/IL/payout, pool-setup, and afterAddLiquidity untouched. |
| `test/harness/RangeGuardHookHarness.sol` | Added `exposed_beforeSwap` / `exposed_afterSwap`; imports for `SwapParams` / `BeforeSwapDelta`. |
| `project-status.md` | `beforeSwap()` + `afterSwap()` ticked; Now advanced to `beforeRemoveLiquidity()`; 161 tests recorded. |
| `CLAUDE.md` | Three sections updated (Current Implementation Status, Implementation Order, Current Session State). |

---

## 4. v4-Specific Risks Resolved

| Risk | Resolution |
|------|------------|
| **Fee return mechanism** | OVERRIDE_FEE_FLAG OR'd into the derived fee; differential integration test proves it is charged on-chain. |
| **Fee units (pips vs bps)** | `FEE_DENOM = 1_000_000` for buffer math; `BPS_DENOM` retained for payout caps only. |
| **BalanceDelta sign in afterSwap** | Use `|delta.amount1()|` (stable numeraire); direction-agnostic; FullMath guards overflow. |
| **Notional buffer vs custody** | Documented MVP limitation; `seedBuffer()` provides real backing; per-payout cap ≤ ledger buffer. |

### ⚠️ Two-denominator finding (load-bearing — read before touching fee math)

The contract uses **two different denominators**, and conflating them is a 100× accounting bug:

- **Fee pip values** — `baseLpFeeBps`, `bufferBps` — use **`FEE_DENOM = 1_000_000`** (v4 pips)
  for the buffer-contribution calculation (`|delta.amount1()| * bufferBps / FEE_DENOM`). These are
  hundredths of a bip: `3000` = 0.30%, `1000` = 0.10% (matching `LPFeeLibrary.MAX_LP_FEE == 1e6`).
- **Payout cap percentages** — `maxPayoutPctOfIl`, `maxPayoutPctOfBuffer` — use
  **`BPS_DENOM = 10_000`** (true basis points): `5000` = 50%, `1000` = 10%.
- **The "Bps" suffix on the fee fields is a misnomer** — `baseLpFeeBps`/`bufferBps` are *pip*
  values (1e6 denominator), NOT true basis points. The names predate this finding and are kept
  for spec compatibility; the magnitudes are correct only under the pip interpretation.
- **Future sessions MUST NOT use `BPS_DENOM` for any fee/buffer math.** Using `BPS_DENOM` (1e4)
  on `bufferBps` would credit the buffer 100× too fast (10% of volume instead of 0.10%),
  instantly outrunning any seeded backing. Fee math → `FEE_DENOM`; cap math → `BPS_DENOM`.

---

## 5. Tests Passing

Full suite: **161 passing, 0 failing.** (+21 from this session: 13 unit + 3 fuzz + 3 invariant
+ 2 integration.)

| Suite | Count |
|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 33 |
| `test/unit/Accrue.t.sol` | 17 |
| `test/unit/ComputeIL.t.sol` | 14 |
| `test/unit/ComputePayout.t.sol` | 15 |
| `test/unit/AfterAddLiquidity.t.sol` | 10 |
| `test/unit/BeforeSwap.t.sol` | 4 |
| `test/unit/AfterSwap.t.sol` | 9 |
| `test/fuzz/AccrueFuzz.t.sol` | 8 |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 |
| `test/fuzz/StagePoolConfigFuzz.t.sol` | 3 |
| `test/fuzz/AfterAddLiquidityFuzz.t.sol` | 3 |
| `test/fuzz/BeforeSwapFuzz.t.sol` | 1 |
| `test/fuzz/AfterSwapFuzz.t.sol` | 2 |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 |
| `test/invariant/SettlementInvariant.t.sol` | 5 |
| `test/invariant/PoolSetupInvariant.t.sol` | 6 |
| `test/invariant/PositionLifecycleInvariant.t.sol` | 3 |
| `test/invariant/BufferFundingInvariant.t.sol` | 3 |
| `test/integration/PoolSetup.t.sol` | 4 |
| `test/integration/AfterAddLiquidity.t.sol` | 1 |
| `test/integration/Swap.t.sol` | 2 |

Buffer-funding invariants → invariant-mapping.md:
- `invariant_BufferEqualsSummedSkims` → buffer funded purely by swap skims (Pillar 2 accounting).
- `invariant_BufferNeverExceedsSkimmed` → "bufferBalanceStable must never be negative".
- `invariant_AfterSwapNeverAccruesPositions` → "afterSwap must never directly accrue positions" /
  "accrual calculations must never iterate over all LP positions".

Invariant run: 500 runs × 50,000 calls, **0 reverts**. `forge fmt --check` passes; `forge build`
clean (only the expected "restrict to pure" notes on the remaining unimplemented stubs).

**Test seam note:** unit/fuzz/invariant suites drive the harness internal directly, so the
underlying PoolManager pool is never initialized and `getSlot0` returns tick 0 (TickUpdated
`newTick == 0`). The buffer math is tick-independent; non-zero-tick behavior and the real fee
charge are covered end-to-end by `test/integration/Swap.t.sol`.

---

## 6. Deferred to Next Session (Phase 2 — `beforeRemoveLiquidity()` / `afterRemoveLiquidity()`)

- **`beforeRemoveLiquidity()`** — `minHoldSeconds` eligibility gate (→ `IneligibleClaim`, skip
  all accrual/IL/payout), then final `_accrue()` → `_computeIL()` → `_computePayout()` → store
  `pendingPayout`; emit `AccrualUpdated`.
- **IL settlement sequencing (carried from sessions 3–4, 6):** the spec calls `_computeIL` in
  `beforeRemoveLiquidity`, but v4 withdrawn `outAmt0/outAmt1` are known only *after* removal.
  Resolve when wiring the remove callbacks (likely compute IL/payout in `afterRemoveLiquidity`
  using the realized out-amounts, or pass through hookData).
- **`afterRemoveLiquidity()`** — execute `pendingPayout`, update buffer + `totalPaidOutStable`,
  clear position state; emit `ClaimSettled` / `PartialPayout` / `NoClaim`. This is where the
  notional buffer meets real custody — confirm payout-vs-`bufferBalanceStable` solvency handling.
- **`onlyReactive` + `emitOutOfRange`/`emitBackInRange`** — implement with the reactive phase;
  guard on `_reactiveSet[id]`. `TickUpdated` (this session) is the event they subscribe to.
- **`seedBuffer()`** — admin-only real buffer funding; pairs with the notional skim accounting.
