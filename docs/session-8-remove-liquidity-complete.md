# Session 8 — beforeRemoveLiquidity() / afterRemoveLiquidity() Complete

Date: 2026-05-31
Scope: Implement and fully test the two withdrawal-path callbacks — `beforeRemoveLiquidity()`
(validation only) and `afterRemoveLiquidity()` (the v4-native settlement point: final accrual,
IL, three-cap payout, transfer, cleanup). Includes the locked `PositionState` struct change
(drop `pendingPayout`, add `liquidity`), the `afterAddLiquidity` re-add policy flip, and the
two-event settlement vocabulary.
Result: ✅ Complete — implementation + unit + fuzz + invariant + integration tests, all passing.
Advances **Phase 2 (Hook Callbacks)** to its fifth and sixth (final) completed items.

---

## 1. What Was Implemented

### Settlement-flow resolution (v4-native, amends the original spec)

In v4, `beforeRemoveLiquidity` can only **allow or revert** — it cannot conditionally skip a
payout while allowing the withdrawal, and the **withdrawn out-amounts only exist in the
`BalanceDelta` of `afterRemoveLiquidity`**. The original spec (settlement computed in `before`,
executed in `after`) is therefore impossible. All settlement moved to `afterRemoveLiquidity`.

**`_beforeRemoveLiquidity(sender, key, params, bytes)`** — `internal view override`. Validation
only; writes nothing.

```
positionKey = _positionKey(sender, tickLower, tickUpper, salt)
!pos.active                                   -> revert PositionNotActive
uint256(-params.liquidityDelta) != pos.liquidity -> revert PartialWithdrawalNotSupported  (MVP full-withdrawal only)
return beforeRemoveLiquidity.selector
```

**`_afterRemoveLiquidity(sender, key, params, delta, _, bytes)`** — `internal override`. The
settlement point. Ordering preserves the mandated `final _accrue -> _computeIL -> _computePayout`.

```
!pos.active                                   -> no-op return (defensive; `before` already gated)
block.timestamp - depositTime < minHoldSeconds -> emit IneligibleClaim, clear, return  (HARD GATE, no accrual/IL/payout)
_settle(...):                                 (split out to bound the stack, no via-IR)
  outAmt0/1 = |delta.amount0/1|               (FULL delta — fees INCLUDED, per IL spec; removal delta is positive)
  exitTick  = getSlot0                        (a removal never moves the pool price)
  _accrue(poolId, key, exitTick)              (final accrual; closing AccrualUpdated line)
  ilRaw = _computeIL(pos, outAmt0, outAmt1, exitTick)
  ilRaw == 0                                  -> emit NoClaim(vHodl, vActual), clear, return
  (payout, factor) = _computePayout(poolId, pos, ilRaw)
  _settleClaim(...):  strict CEI
    capture tickLower/tickUpper/earned/requested(=IL_covered)
    delete positions[poolId][positionKey]     (clear position BEFORE transfer)
    bufferBalanceStable -= payout; totalPaidOutStable += payout   (buffer update BEFORE transfer)
    if payout > 0: key.currency1.transfer(owner=sender, payout)   (real ERC20 of the hook's own token1)
    payout>0 && factor==IL_CAP -> ClaimSettled  else -> PartialPayout(requested=IL_covered, actual=payout)
return (afterRemoveLiquidity.selector, delta)   (no hook delta; afterRemoveLiquidityReturnDelta stays false)
```

Key correctness points:

- **Withdrawn amounts include fees.** `_afterRemoveLiquidity` uses the FULL caller `delta` (not
  `delta - feesAccrued` as on entry), so `V_actual` includes earned fees per the IL spec.
- **exitTick is stable.** `modifyLiquidity` (add or remove) never moves `sqrtPriceX96`/tick in
  v4 — only swaps do — so the `getSlot0` exit tick is the correct settlement tick and is shared
  cleanly by the final `_accrue` and `_computeIL`.
- **Strict CEI (deliberate, see §4).** Both the position clear AND the buffer/paidOut updates
  happen BEFORE the external transfer — a superset of the locked "clear state before transfer"
  rule, safer against a reentrant token. `payout <= bufferCap <= bufferBalanceStable` (from the
  `maxPayoutPctOfBuffer <= BPS_DENOM` staging bound), so the buffer decrement cannot underflow.
- **Event vocabulary (locked):** `IneligibleClaim` (min-hold), `NoClaim` (IL == 0), `ClaimSettled`
  (full coverage, IL cap bound, payout > 0), `PartialPayout` (coverage/buffer cap bound, OR the
  `IL_raw > 0 but payout == 0` edge → `PartialPayout(requested=IL_covered, actual=0)`; `NoClaim`
  is strictly `IL_raw == 0`).
- **No iteration / single position.** Settlement touches only the one position.

### PositionState struct change (locked)

- **Removed** `uint256 pendingPayout` — payout is computed and executed entirely within
  `afterRemoveLiquidity`; no before→after handoff exists, so no stored pending value is needed.
- **Added** `uint128 liquidity` — full position liquidity, captured at registration; the
  `beforeRemoveLiquidity` gate compares the removed liquidity against it to enforce full
  withdrawal.

### afterAddLiquidity re-add policy flip (R1)

The session-6 re-add path silently **skipped** a top-up (preserving the snapshot). With the new
full-withdrawal gate that compares removed-vs-stored liquidity, a silently-skipped top-up would
desync `pos.liquidity` from the live v4 position and permanently block withdrawal. The path now
**reverts `PositionAlreadyRegistered()`** — MVP is one add per position, made explicit.

`pos.liquidity = uint128(uint256(params.liquidityDelta))` is now stored at registration.

### Supporting additions to `src/RangeGuardHook.sol`

- Import `{Currency, CurrencyLibrary}` + `using CurrencyLibrary for Currency;` (payout transfer).
- Constant `REASON_MIN_HOLD_NOT_MET = "MIN_HOLD_NOT_MET"`.
- Events: `ClaimSettled`, `PartialPayout`, `NoClaim`, `IneligibleClaim`.
- Errors: `PositionAlreadyRegistered`, `PositionNotActive`, `PartialWithdrawalNotSupported`.
- Private helpers: `_settle`, `_settleClaim`, `_emitNoClaimAndClear`, `_emitIneligibleAndClear`
  (the splits keep `_afterRemoveLiquidity` under the stack limit without via-IR).

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/BeforeRemoveLiquidity.t.sol` | 6 unit tests: inactive revert, partial/over/zero-liquidity reverts, full-withdrawal selector, no-state-mutation (validation-only purity). |
| `test/unit/AfterRemoveLiquidity.t.sol` | 8 unit tests: ineligible→IneligibleClaim+clear, NoClaim+valuations, ClaimSettled (IL cap) pays+buffer+clears, PartialPayout (coverage cap / buffer cap), payout==0-with-IL→PartialPayout(0), final-accrue feeds payout, inactive no-op. Uses a real MockERC20 token1 minted to the harness so payouts transfer. |
| `test/fuzz/AfterRemoveLiquidityFuzz.t.sol` | 2 fuzz: payout == three-cap minimum and buffer/paidOut/transfer all conserve; ineligible always pays zero and clears. |
| `test/invariant/handlers/SettlementHandler.sol` | Settlement handler: each action registers a fresh position and settles it end-to-end; per-call asserts buffer decrement == payout and the slot is cleared. |
| `test/invariant/SettlementExecutionInvariant.t.sol` | 3 invariants: buffer conservation (`buffer + paidOut == initial seed`), buffer never grows under settlement, real custody matches ledger payouts (LP balance == paidOut, hook balance == backing − paidOut). |
| `test/integration/RemoveLiquidity.t.sol` | 1 end-to-end test through the REAL PoolManager + LP/swap routers: add in range → swap (funds buffer + moves price → IL) → warp past hold → fund hook token1 → full removal settles a positive capped claim, buffer/custody/totalPaidOut all reconcile, position cleared, settlement event emitted. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | Struct change (drop `pendingPayout`, add `liquidity`); re-add path reverts `PositionAlreadyRegistered`; store `pos.liquidity`; implemented `_beforeRemoveLiquidity` + `_afterRemoveLiquidity` + 4 private helpers; Currency import/using; reason constant; 4 events; 3 errors. Accrual/IL/payout cores, pool-setup, swap callbacks untouched. |
| `test/harness/RangeGuardHookHarness.sol` | Added `exposed_beforeRemoveLiquidity` / `exposed_afterRemoveLiquidity`. |
| `test/unit/AfterAddLiquidity.t.sol` | Re-add test flipped to expect `PositionAlreadyRegistered`; `pendingPayout` assertion replaced with a `liquidity` assertion. |
| `test/fuzz/AfterAddLiquidityFuzz.t.sol` | Re-add fuzz flipped to expect the revert + snapshot immutability after revert. |
| `test/invariant/handlers/AfterAddLiquidityHandler.sol` | Registers each key once (re-adds would now revert); re-add rejection covered by the dedicated tests. |
| `test/unit/Accrue.t.sol`, `test/fuzz/AccrueFuzz.t.sol`, `test/invariant/handlers/AccrueHandler.sol`, `test/invariant/PositionLifecycleInvariant.t.sol`, `test/invariant/BufferFundingInvariant.t.sol`, `test/integration/AfterAddLiquidity.t.sol` | Dropped `.pendingPayout` references; the integration positional getter destructure updated to read `liquidity`. |
| `spec.md`, `context.md`, `project-status.md`, `CLAUDE.md` | Doc updates (see §6). |

---

## 4. Design Decisions / Resolved Risks (confirmed with user)

| Ref | Decision |
|-----|----------|
| **Settlement split** | All settlement in `afterRemoveLiquidity`; `beforeRemoveLiquidity` validates only. A v4 architectural constraint (out-amounts unknown in `before`), not a preference. |
| **R1** | Re-add reverts `PositionAlreadyRegistered()` (explicit one-add-per-position MVP rule), preventing a `pos.liquidity` desync that would brick withdrawal. |
| **R2** | Notional buffer vs real custody: accepted & documented. `payout <= bufferBalanceStable` (ledger) does NOT imply real solvency (afterSwap inflates the ledger without tokens); MVP relies on `seedBuffer()` backing. The integration test mints real token1 to the hook to stand in for `seedBuffer`. |
| **R3** | `IL_raw > 0` but `payout == 0` → `PartialPayout(requested=IL_covered, actual=0)`. `NoClaim` is strictly `IL_raw == 0`. |
| **R4** | Payout recipient is the v4 `sender` (owner=sender MVP). A different remover than adder would not match the key → `beforeRemoveLiquidity` reverts (blocks the withdrawal); acceptable for MVP (same router does both). |
| **CEI** | Strict CEI chosen over the locked literal ordering: buffer/paidOut updates moved BEFORE the transfer (alongside the position clear). Safer against reentrant tokens; a superset of the locked "clear state before transfer" requirement. Flagged pre-implementation; no objection raised. |
| **`PositionNotActive` error** | Added beyond the locked error list — needed for the `beforeRemoveLiquidity` active-position requirement (the locked list only named `PartialWithdrawalNotSupported`). |

---

## 5. Tests Passing

Full suite: **181 passing, 0 failing.** (+20 from this session: 14 unit + 2 fuzz + 3 invariant +
1 integration.)

| Suite | Count |
|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 33 |
| `test/unit/Accrue.t.sol` | 17 |
| `test/unit/ComputeIL.t.sol` | 14 |
| `test/unit/ComputePayout.t.sol` | 15 |
| `test/unit/AfterAddLiquidity.t.sol` | 10 |
| `test/unit/BeforeSwap.t.sol` | 4 |
| `test/unit/AfterSwap.t.sol` | 9 |
| `test/unit/BeforeRemoveLiquidity.t.sol` | 6 |
| `test/unit/AfterRemoveLiquidity.t.sol` | 8 |
| `test/fuzz/AccrueFuzz.t.sol` | 8 |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 |
| `test/fuzz/StagePoolConfigFuzz.t.sol` | 3 |
| `test/fuzz/AfterAddLiquidityFuzz.t.sol` | 3 |
| `test/fuzz/BeforeSwapFuzz.t.sol` | 1 |
| `test/fuzz/AfterSwapFuzz.t.sol` | 2 |
| `test/fuzz/AfterRemoveLiquidityFuzz.t.sol` | 2 |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 |
| `test/invariant/SettlementInvariant.t.sol` | 5 |
| `test/invariant/PoolSetupInvariant.t.sol` | 6 |
| `test/invariant/PositionLifecycleInvariant.t.sol` | 3 |
| `test/invariant/BufferFundingInvariant.t.sol` | 3 |
| `test/invariant/SettlementExecutionInvariant.t.sol` | 3 |
| `test/integration/PoolSetup.t.sol` | 4 |
| `test/integration/AfterAddLiquidity.t.sol` | 1 |
| `test/integration/Swap.t.sol` | 2 |
| `test/integration/RemoveLiquidity.t.sol` | 1 |

Settlement-execution invariants → invariant-mapping.md (Settlement):
- `invariant_BufferConservedAcrossSettlements` → "bufferBalanceStable must never be negative" /
  "payout must never exceed bufferBalanceStable".
- `invariant_BufferNeverGrowsUnderSettlement` → supports "payout must never exceed bufferBalanceStable".
- `invariant_RealCustodyMatchesLedgerPayouts` → ties the notional ledger to real ERC20 custody.

Invariant run: 500 runs × 50,000 calls, **0 reverts**. `forge fmt --check` passes; `forge build`
clean (the swap/remove "restrict to pure/view" stub notes are gone now that the callbacks are
implemented).

---

## 6. Documentation Updates & Known Drift

Updated this session (per the locked closer scope):
- **spec.md** — §3 Pillar 3 settlement-flow block rewritten (validation-only `before`, full
  settlement in `after`); §5 PositionState struct (`pendingPayout` → `liquidity`); §10 event
  table `IneligibleClaim` source `beforeRemoveLiquidity` → `afterRemoveLiquidity` (R6).
- **context.md** — §2 status/target/steps + recent architecture note; §8 PositionState struct.
- **project-status.md** — both remove checkboxes ticked, Now → `checkpoint()`, 181 tests.
- **CLAUDE.md** — the three permitted sections only.

⚠️ **Known doc drift, deferred (R5) to a separate doc-fix pass — NOT changed this session:**
- **`invariant-mapping.md`** still references `pendingPayout` ("must never be negative", "must be
  cleared after settlement"). With the field removed, these should be reworded to the new model
  (settlement is atomic in `afterRemoveLiquidity`; cleared positions retain no payout state).
- **`state-machine.md`** still describes a `PendingSettlement` state with a computed
  `pendingPayout` and `Registered`/`Cleared` with `pendingPayout == 0`. The new design collapses
  `PendingSettlement → Settled` into one atomic `afterRemoveLiquidity` call.
- **spec.md §6 (callback table)** and **§7 (core internal functions)** still narrate the
  pre-amendment "`beforeRemoveLiquidity` computes settlement" flow. Out of the locked closer scope
  for this session; fix alongside the two files above.

---

## 7. Deferred to Next Session (Phase 2 → `checkpoint()`)

- **`checkpoint()`** — permissionless single-position accrual driver; `require(active)`,
  `block.timestamp - lastAccrualTime >= minCheckpointInterval`, `_accrue(poolId, key, currentTick)`,
  emit `Checkpointed`. Primary Reactive Network entry point.
- **`seedBuffer()`** — admin-only REAL buffer funding; pairs with the notional skim accounting and
  provides the custody this session's payout transfer depends on (R2).
- **`onlyReactive` + `emitOutOfRange`/`emitBackInRange`** — implement with the reactive phase;
  guard on `_reactiveSet[id]`; subscribe to `TickUpdated`.
- **Doc-fix pass (R5)** — reconcile `invariant-mapping.md`, `state-machine.md`, and spec.md
  §6/§7 with the v4-native settlement model.
