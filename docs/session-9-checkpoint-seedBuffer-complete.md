# Session 9 — checkpoint() / seedBuffer() Complete

Date: 2026-05-31
Scope: Implement and fully test the two remaining Phase-2 external functions —
`checkpoint()` (the permissionless, accrual-only Reactive Network entry point) and
`seedBuffer()` (admin-only REAL token1 custody backing the IL buffer). `seedBuffer()`
resolves the session-8 R2 carry-in (notional buffer ledger vs. real solvency).
Result: ✅ Complete — implementation + unit + fuzz + invariant + integration tests, all passing.
Advances **Phase 2 (Hook Callbacks)** to its final completed items; next phase is the Reactive contract.

---

## 1. What Was Implemented

### `checkpoint(PoolId poolId, bytes32 positionKey)` — external, permissionless

Accrual ONLY — the lazy-accrual driver between deposit and withdrawal and the Reactive
Network's primary entry point. Never computes IL, never pays out, never moves tokens.

```
!_poolInitialized[poolId]                                          -> revert PoolNotInitialized  (defensive)
!pos.active                                                        -> revert PositionNotActive
block.timestamp - pos.lastAccrualTime < cfg.minCheckpointInterval  -> revert CheckpointTooSoon
_accrue(poolId, positionKey, _getCurrentTick(poolId))              (range-gated, monotonic, ceiling-capped)
emit Checkpointed(poolId, positionKey, block.timestamp)
```

Correctness / safety points:

- **Permissionless is safe.** `_accrue` is monotonic, range-gated, and ceiling-capped, and the
  `minCheckpointInterval` rate-limit bounds call frequency — a caller can only perform the accrual
  the protocol already wants. No external value transfer, no reentrancy surface.
- **Tick read** via the new private `_getCurrentTick(PoolId)` helper (a thin `getSlot0` wrapper;
  storage read via `StateLibrary`, no unlock). Introduced per the user's R1 decision (the spec's
  `_getCurrentTick` was never actually implemented; the three existing callbacks keep their inline
  `getSlot0` reads — refactoring tested code was out of scope).
- **`minCheckpointInterval == 0` is allowed** (no staging lower bound). Same-block re-checkpoints are
  then permitted but harmless: `_accrue` sees `dt == 0` -> zero delta, `lastAccrualTime` unchanged.
  Confirmed acceptable (R3); staging validation left untouched.

### `seedBuffer(PoolKey calldata key, uint256 amount)` — external, admin-only

Funds a pool's IL-coverage buffer with REAL token1 custody — the backing the settlement payout
(`_settleClaim`) transfers from. Pairs with the notional fee skim in `afterSwap`.

```
poolId = key.toId()
!_poolInitialized[poolId]                 -> revert PoolNotInitialized   (before admin read: uninit admin == 0)
msg.sender != poolConfig[poolId].admin    -> revert CallerNotAdmin
amount == 0                               -> revert ZeroAmount
IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount)  -> revert on false
bufferBalanceStable += amount             (credit AFTER the pull; totalSkimmedStable untouched)
emit BufferSeeded(poolId, amount, newBufferBalance)
```

Correctness / safety points:

- **`IERC20Minimal.transferFrom`, not `CurrencyLibrary`.** v4's `CurrencyLibrary` exposes only
  `transfer` (no `transferFrom`) — verified directly. The pull goes through `IERC20Minimal`
  (new import) with a checked bool; the admin must `approve(hook, amount)` on token1 first.
- **Interaction-before-effects on the pull.** Tokens that never arrive are never credited; a
  failed pull reverts and leaves the buffer untouched.
- **Credits `bufferBalanceStable` only** (R4). `totalSkimmedStable` is fee-skim accounting
  (`afterSwap`) and is deliberately NOT touched — `getBufferHealth` reflecting seeds in the
  balance (not in skimmed fees) is the desired behavior.
- **Native token1 cannot be seeded** (no `transferFrom`); out of MVP scope (token1 = ERC20 USDC) —
  documented only (R5).

### Supporting additions to `src/RangeGuardHook.sol`

- Import `{IERC20Minimal}` from `v4-core/interfaces/external/IERC20Minimal.sol`.
- Events: `Checkpointed`, `BufferSeeded`.
- Errors: `CheckpointTooSoon`, `CallerNotAdmin`, `ZeroAmount` (reused `PoolNotInitialized` and
  `PositionNotActive` — no new variants for those).
- Private helper `_getCurrentTick(PoolId)`.
- Inline admin/init checks in `seedBuffer` (no modifier — only one consumer; matches the
  `onlyOwner`-only modifier convention).

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/unit/Checkpoint.t.sol` | 8 unit tests: pool-not-initialized / not-active / too-soon reverts; exactly-at-interval boundary; in-range accrues + emits `AccrualUpdated`+`Checkpointed`; out-of-range zero-delta + clock advance; permissionless caller; called-twice respects interval (per-checkpoint truncation). |
| `test/unit/SeedBuffer.t.sol` | 8 unit tests: not-initialized / not-admin / zero-amount / no-allowance reverts; valid pull + buffer credit + skim/paidOut untouched; accumulation; `BufferSeeded` event; running-balance event. Uses a real `MockERC20` token1. |
| `test/fuzz/CheckpointFuzz.t.sol` | 2 fuzz: interval gate + accrual monotonicity over random elapsed time; out-of-range never accrues for any elapsed time. |
| `test/fuzz/SeedBufferFuzz.t.sol` | 2 fuzz: single seed credits the buffer by exactly the pull and matches real custody (skim untouched); two seeds accumulate additively in ledger and custody. |
| `test/invariant/handlers/CheckpointHandler.sol` | Drives `checkpoint()` over a committed pool (advances >= interval each round so it never reverts), across MAIN (in range), OOR (out of range), INACTIVE (never touched). High-water ghosts. |
| `test/invariant/CheckpointInvariant.t.sol` | 5 invariants: coverage never decreases, never exceeds ceiling, OOR never accrues, clock monotonic, inactive untouched — all through the real `checkpoint()` entry point. |
| `test/invariant/handlers/SeedBufferHandler.sol` | Admin (== handler) seeds randomized amounts, minting exactly what it seeds each round so the pull always succeeds; tracks the running seed sum. |
| `test/invariant/SeedBufferInvariant.t.sol` | 3 invariants: buffer == sum of seeds; skim/paidOut untouched by seeding; **real custody == buffer ledger** (the R2 resolution — every ledgered unit is really held). |
| `test/integration/CheckpointAndSeed.t.sol` | 1 end-to-end test through the REAL PoolManager + routers: add in range → swap (funds notional buffer + moves price → IL) → REAL admin `seedBuffer` (replaces the mint-to-hook stand-in) → `checkpoint` after the interval (intermediate accrual) → warp past hold → full removal settles a capped claim paid from the seeded custody; buffer/totalPaidOut/custody all reconcile. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | `IERC20Minimal` import; 2 events (`Checkpointed`, `BufferSeeded`); 3 errors (`CheckpointTooSoon`, `CallerNotAdmin`, `ZeroAmount`); `checkpoint()` + `seedBuffer()` externals; private `_getCurrentTick`. Accrual/IL/payout cores, pool-setup, swap, and remove callbacks untouched. |
| `context.md`, `project-status.md`, `CLAUDE.md` | Doc updates (see §6). |

---

## 4. Design Decisions / Resolved Risks (confirmed with user)

| Ref | Decision |
|-----|----------|
| **R1: `_getCurrentTick`** | The spec referenced `_getCurrentTick` but it was never implemented (all callbacks inline `getSlot0`). Introduced it as a private helper for `checkpoint()`; existing inline reads left as-is. |
| **R2: token pull** | `CurrencyLibrary` has no `transferFrom` (verified). Use `IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(...)` with a checked bool (revert on false). |
| **R3: `minCheckpointInterval == 0`** | No staging lower bound; same-block re-checkpoints are harmless (`dt == 0` → zero delta). Staging validation NOT changed. |
| **R4: seed credits buffer only** | `bufferBalanceStable += amount`; `totalSkimmedStable` (fee accounting) untouched. `getBufferHealth` reflecting seeds in the balance is desired. |
| **R5: native token1** | Cannot be seeded via `transferFrom`; out of MVP scope (token1 = ERC20). Documented only. |
| **Custody resolution (R2 carry-in from session 8)** | `seedBuffer()` provides the real token1 the payout transfer depends on. The new `SeedBufferInvariant` and the integration test now use REAL seeded custody instead of minting token1 directly to the hook. |

---

## 5. Tests Passing

Full suite: **210 passing, 0 failing.** (+29 from this session: 16 unit + 4 fuzz + 8 invariant +
1 integration.) `forge fmt --check` passes; `forge build` clean.

New invariant runs: 500 runs × 50,000 calls each, **0 reverts**, for all 8 new invariants.

New-suite breakdown:

| Suite | Count |
|-------|-------|
| `test/unit/Checkpoint.t.sol` | 8 |
| `test/unit/SeedBuffer.t.sol` | 8 |
| `test/fuzz/CheckpointFuzz.t.sol` | 2 |
| `test/fuzz/SeedBufferFuzz.t.sol` | 2 |
| `test/invariant/CheckpointInvariant.t.sol` | 5 |
| `test/invariant/SeedBufferInvariant.t.sol` | 3 |
| `test/integration/CheckpointAndSeed.t.sol` | 1 |

Invariant → invariant-mapping.md mapping:
- `invariant_CheckpointNeverDecreasesCoverage` → "checkpoint() must never reduce total earned coverage".
- `invariant_CheckpointOutOfRangeNeverAccrues` → "checkpoint() must never bypass range gating".
- `invariant_CheckpointClockMonotonic` → "lastAccrualTime must monotonically increase".
- `invariant_CheckpointCoverageNeverExceedsCeiling` / `invariant_CheckpointInactiveUntouched` →
  accrual ceiling + "inactive positions must never checkpoint".
- `invariant_RealCustodyBacksBuffer` → ties the (now real) buffer custody to the ledger.

---

## 6. Documentation Updates

Updated this session (per the locked closer scope):
- **context.md** — §2 only: checkpoint()/seedBuffer() moved to completed; next target → Reactive
  contract; planned steps refreshed; recent architecture note records seedBuffer real custody / R2 resolved.
- **project-status.md** — both Phase-2 checkboxes (checkpoint + seedBuffer) ticked, **Now** → Reactive
  contract, date refreshed, test count 210.
- **CLAUDE.md** — the three permitted sections only (Current Implementation Status, Implementation
  Order (Mandatory), Current Session State).

⚠️ **Carried-over doc drift (from session 8, still deferred):** `invariant-mapping.md` /
`state-machine.md` / spec.md §6–§8 narrative reconciliation with the v4-native settlement model and
the `_getCurrentTick` addition — fold into the standalone doc-fix pass alongside the Reactive work.

---

## 7. Deferred to Next Session (Phase 2 complete → Reactive contract)

- **Reactive Network contract** — `onlyReactive(poolId)` guard (on `_reactiveSet[poolId]`),
  `emitOutOfRange` / `emitBackInRange`, subscribe to `TickUpdated`, drive `checkpoint()` on the
  heartbeat + range-crossing triggers. Reactive contracts must never mutate accounting state.
- **Doc-fix pass** — reconcile `invariant-mapping.md`, `state-machine.md`, and spec.md §6–§8 with the
  v4-native settlement model and the `_getCurrentTick` helper.
- **Frontend dashboard** — coverage report rendered from on-chain events.

---

## 8. Roadmap Reassessment (project-status.md)

With Phase 2 (hook callbacks) now complete, we reviewed the cross-cutting Phase 3 (Integration
Testing) and Phase 4 (Protocol Invariants) checkboxes against the suites that actually exist and
updated `project-status.md` accordingly. Verdicts are grounded in the real test files, not intent.

### Phase 3: Integration Testing — 3 of 4 checked

| Item | Status | Basis |
|------|--------|-------|
| Full LP lifecycle | ✅ | `CheckpointAndSeed.t.sol` runs the complete arc through the real PoolManager: setup → in-range add → swap → **real** seedBuffer → checkpoint (mid-life accrual) → full withdrawal → settlement, with buffer/paidOut/custody reconciled. |
| Coverage accrual lifecycle | ☐ left unchecked | Only a single **in-range** checkpoint + the final accrual at settlement are integration-tested. The in→out→in arc (out-of-range pause, back-in-range resume, multi-checkpoint `AccrualUpdated` history) is NOT covered — the swap in `CheckpointAndSeed` deliberately keeps the position in range. Part of this (the `PositionOutOfRange`/`PositionBackInRange` emits) is gated on the not-yet-built Reactive contract. |
| Buffer funding lifecycle | ✅ | Both funding sources covered: notional skim from real swaps (`Swap.t.sol`, asserts the exact `bufferBps` share + `totalSkimmed`) and real admin custody (`CheckpointAndSeed` seedBuffer). |
| Settlement lifecycle | ✅ | `RemoveLiquidity.t.sol` + `CheckpointAndSeed.t.sol` both run full settlement end-to-end (final accrue → IL → three-cap payout → transfer → cleanup), with a settlement event and custody reconciliation. |

Added note in the file: coverage is distributed across per-session integration files rather than a
single dedicated Phase 3 suite; a comprehensive single-test lifecycle covering all callbacks
end-to-end will come with the demo script.

### Phase 4: Protocol Invariants (cross-cutting) — 2 of 4 checked

| Item | Status | Basis |
|------|--------|-------|
| Accounting invariants | ✅ | Now fully proven: `CoverageAccounting` + `Checkpoint` (earned never decreases / exceeds ceiling, inactive never accrues, clock monotonic), `BufferFunding` + `SeedBuffer` (buffer never negative, real custody == ledger), snapshot immutability, `maxPayoutPctOfBuffer <= BPS_DENOM` (`PoolSetup`). The **stale `(partial: ... _accrue())` qualifier was removed** — buffer + checkpoint accounting are now covered too. |
| Lifecycle invariants | ☐ left unchecked | Transitions are proven, but in **separate per-action campaigns** (`PositionLifecycle` = register only; `Checkpoint` = checkpoint only on pre-seeded positions; `SettlementExecution` = register-then-settle per action). TODO: one combined stateful campaign interleaving add → checkpoint → remove on shared keys. |
| Settlement invariants | ✅ | `SettlementInvariant` (IL_raw never negative/bounded, payout ≤ every cap, LimitingFactor matches binding cap) + `SettlementExecutionInvariant` (buffer conserved `buffer+paidOut==seed`, real custody == ledger). |
| Authorization invariants | ☐ left unchecked (blocked) | Leads with `onlyReactive(poolId)` and "Reactive contracts must never mutate accounting state" — but `onlyReactive`/`emitOutOfRange`/`emitBackInRange` **don't exist yet** (they are the next phase). Access checks are unit-tested (owner/admin/initializer) and `_reactiveSet` monotonicity is in `PoolSetupInvariant`, but there is no dedicated authorization-invariant suite. Closes with the Reactive contract. |

### Lifecycle-note caveat (important correction)

An earlier draft of the Lifecycle note proposed a TODO to "assert **Cleared can never re-activate**."
We dropped that wording because it describes a property the protocol **does not** guarantee — and
asserting it would read as a false bug claim:

- Settlement does `delete positions[poolId][positionKey]`, setting `active = false`.
- The re-add guard in `_afterAddLiquidity` reverts `PositionAlreadyRegistered` only **while**
  `pos.active` is true. After a position settles and is cleared, the same key **can** be added again.
- That is intended: a withdrawn LP re-depositing starts a **fresh registration** — not a
  re-activation of the old record. state-machine.md's "Cleared → active is invalid" means the old
  record never silently flips back, not that the key is burned forever.

So the real Lifecycle gap is purely coverage-thoroughness (no single stateful campaign interleaving
the transitions on shared keys), not a missing correctness property.

### New section added: Phase 3B — Protocol Completion

A `Phase 3B: Protocol Completion` block was added to the roadmap for the remaining build-out:

- **Reactive contract** — `onlyReactive(poolId)` guard (on `_reactiveSet[poolId]`),
  `emitOutOfRange()` / `emitBackInRange()` (access-controlled), `TickUpdated` subscription for
  range-crossing detection, `checkpoint()` heartbeat driver (periodic + range-crossing triggers).
  Reactive contracts must never mutate accounting state.
- **Frontend dashboard** — coverage report rendered from on-chain events.
- **Demo script** — `RangeGuardDemo.s.sol` with `vm.warp`, full 45-day lifecycle.

### Convergence insight

Both remaining cross-cutting gaps — Phase 3 "Coverage accrual lifecycle" (the in→out→in arc + its
`PositionOutOfRange`/`PositionBackInRange` emits) and Phase 4 "Authorization invariants"
(`onlyReactive`) — **converge on the Reactive contract**. Building it (Phase 3B item 1) is the
prerequisite that unblocks closing both, so the next phase advances three roadmap items at once.
