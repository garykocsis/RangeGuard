# Session 5 — Pool Setup (Three-Phase) Complete

Date: 2026-05-30
Scope: Implement and fully test the three-phase pool bring-up:
`stagePoolConfig()` (Phase 1) + `_beforeInitialize()` commit (Phase 2) +
`setReactiveContract()` (Phase 3), plus all supporting state, errors, events, the
`owner` access-control tier, and the `PendingPoolSetup` struct.
Result: ✅ Complete — implementation + unit + fuzz + invariant + integration tests, all
passing. This opens and completes the first item of **Phase 2 (Hook Callbacks)**.

---

## 1. What Was Implemented

**`stagePoolConfig(PoolKey key, PoolConfig config, address authorizedInitializer, uint160 expectedSqrtPriceX96)`**
— `external onlyOwner`. Fail-fast validation ladder (CEI, no storage write until all pass):

```
onlyOwner                                        -> NotOwner
_poolInitialized[id]                             -> PoolAlreadyInitialized
config.admin == 0                                -> ZeroAdmin
authorizedInitializer == 0                       -> ZeroInitializer
expectedSqrtPriceX96 == 0                        -> ZeroSqrtPrice
!isDynamicFee(key.fee)                           -> NotDynamicFee
baseLpFeeBps > MAX_BASE_FEE_BPS (10_000)         -> InvalidFeeConfig
bufferBps    > MAX_BUFFER_BPS   (5_000)          -> InvalidFeeConfig
coverageApr == 0 || > MAX_COVERAGE_APR (0.5e18)  -> InvalidApr
maxPayoutPctOfIl     > MAX_PAYOUT_PCT (10_000)   -> InvalidPayoutCaps
maxPayoutPctOfBuffer > BPS_DENOM      (10_000)   -> InvalidPayoutCaps  (protects buffer-payout invariant)
secondsPerYear not in {365F, 360}                -> UnsupportedDayCount
```

On success: writes `_pendingSetup[id] = {config, authorizedInitializer, expectedSqrtPriceX96, exists:true}`,
emits `PoolConfigStaged`. Re-stageable (overwrites) until init.

**`_beforeInitialize(address sender, PoolKey key, uint160 sqrtPriceX96)`** — `internal override`,
PoolManager-gated by `BaseHook.beforeInitialize`'s `onlyPoolManager`. The atomic commit point:

```
!isDynamicFee(key.fee)                  -> NotDynamicFee   (authoritative)
!_pendingSetup[id].exists               -> PoolNotStaged
sender != pending.authorizedInitializer -> UnauthorizedInitializer
sqrtPriceX96 != pending.expectedSqrtPriceX96 -> UnexpectedSqrtPrice  (exact, no tolerance)
commit: poolConfig[id] = pending.config; delete _pendingSetup[id]; _poolInitialized[id] = true
emit PoolConfigInitialized; return this.beforeInitialize.selector
```

Any revert reverts `PoolManager.initialize()` in full ⇒ no partial pool. `reactiveContract[id]`
stays `address(0)` until Phase 3.

**`setReactiveContract(PoolKey key, address reactive)`** — `external onlyOwner`, one-time:

```
onlyOwner               -> NotOwner   (runs before the one-time guard)
!_poolInitialized[id]   -> PoolNotInitialized
_reactiveSet[id]        -> ReactiveAlreadySet
reactive == 0           -> ZeroReactive
set reactiveContract[id] = reactive; _reactiveSet[id] = true; emit ReactiveContractSet
```

**Supporting additions to `src/RangeGuardHook.sol`:**
- `using PoolIdLibrary for PoolKey;` + `import LPFeeLibrary` (for `DYNAMIC_FEE_FLAG`/`isDynamicFee`).
- Constructor gains `address _owner`; `address public immutable owner`; `onlyOwner` modifier.
- Constants: `MAX_BASE_FEE_BPS`, `MAX_BUFFER_BPS`, `MAX_COVERAGE_APR`, `MAX_PAYOUT_PCT`,
  `SECONDS_PER_YEAR_365F`, `SECONDS_PER_YEAR_360`.
- `struct PendingPoolSetup`.
- State: `_pendingSetup`, `_poolInitialized`, `_reactiveSet` (all `internal`), `reactiveContract` (public).
- Events: `PoolConfigStaged`, `PoolConfigInitialized`, `ReactiveContractSet`.
- 16 custom errors (new ERRORS section) + new MODIFIERS section — all in CLAUDE.md section order.

---

## 2. Files Created

| File | Purpose |
|------|---------|
| `test/fuzz/StagePoolConfigFuzz.t.sol` | 3 fuzz tests: valid config always stages & round-trips; `maxPayoutPctOfBuffer > BPS_DENOM` always reverts; `coverageApr` 0-or-above-MAX always reverts. |
| `test/invariant/handlers/PoolSetupHandler.sol` | Invariant handler driving stage→initialize→setReactive across 4 fixed pools; owner-gated calls pranked as `harness.owner()`, commit pranked as the PoolManager; always stages a VALID config. |
| `test/invariant/PoolSetupInvariant.t.sol` | 6 pool-setup invariants (pending-deleted, admin-non-zero, buffer-pct≤denom, reactive-non-zero, reactive⇒initialized, reactive-monotonic). |
| `test/integration/PoolSetup.t.sol` | 4 integration tests through the REAL PoolManager.initialize(): full lifecycle + atomic partial-init prevention (unauthorized caller / wrong price / not-staged). |
| `docs/session-5-pool-setup-complete.md` | This summary. |

## 3. Files Modified

| File | Change |
|------|--------|
| `src/RangeGuardHook.sol` | Added owner tier, constants, `PendingPoolSetup`, setup state, events, errors, `onlyOwner`; implemented `stagePoolConfig`/`_beforeInitialize`/`setReactiveContract`. Accrual/IL/payout untouched. Dropped the unused `owner` param name in the `_afterAddLiquidity` skeleton to avoid shadowing the new state var. |
| `script/DeployRangeGuardHook.s.sol` | Pass `vm.addr(pk)` as the owner ctor arg (mining + deployment); logs owner address. |
| `test/harness/RangeGuardHookHarness.sol` | Constructor takes `_owner`; added `exposed_poolInitialized`, `exposed_reactiveSet`, `exposed_pendingSetup` getters. |
| `test/unit/RangeGuardHook.t.sol` | Added 32 pool-setup unit tests alongside the existing permissions test. |
| 6 existing test suites (Accrue/ComputeIL/ComputePayout unit+fuzz, Coverage/Settlement invariant) | Updated `new RangeGuardHookHarness(...)` call sites to pass `address(this)` as owner. |
| `project-status.md` | Pool-setup ticked; Now advanced to `afterAddLiquidity()`; 123 tests recorded. |
| `CLAUDE.md` | Three sections updated (Current Implementation Status, Implementation Order, Current Session State). |

---

## 4. Design Decisions Made

1. **`owner` as an explicit constructor arg** (confirmed with user). The salted `new ...{salt}`
   in the deploy script is routed through the canonical CREATE2 factory `0x4e59…4956C`, so
   `msg.sender` inside the constructor is the *factory*, not the deploying EOA. Setting
   `owner = msg.sender` would have bricked `stagePoolConfig`/`setReactiveContract` in any real
   deployment. The deploy script passes `vm.addr(pk)`; mining uses the same args so the
   predicted address still matches.
2. **Setup flags `internal`, not `private`** (deviation from the amendment's literal `private`).
   The project's testing pattern reaches non-public state via a `RangeGuardHookHarness`
   subclass; `private` blocks subclass reads. `internal` keeps them externally opaque (no
   public getter) while enabling the six invariants to assert on them. `reactiveContract`
   stays `public` (spec) and `poolConfig` already public.
3. **`onlyReactive` deferred** (confirmed with user). `emitOutOfRange`/`emitBackInRange` are a
   later phase, so there is nothing for the modifier to guard yet. The testing-strategy line
   "onlyReactive functions correctly after registration" is deferred with this note.
4. **No `minHoldSeconds` bound** (confirmed with user). The locked validation ladder has no
   such check; `MAX_HOLD_SECONDS` from the spec constants list is intentionally unused for
   now. `minCheckpointInterval` / `targetBufferSize` likewise unbounded per the locked list.
5. **`NotDynamicFee` kept in `_beforeInitialize` despite redundancy.** `PoolId = key.toId()`
   hashes the full key incl. `fee`, so a non-dynamic-fee init derives a different poolId and
   would hit `PoolNotStaged`. The explicit fee check is retained first as defense-in-depth and
   for the precise error, matching the spec's "authoritative" designation.
6. **`onlyOwner` precedence in `setReactiveContract`.** `onlyOwner` runs before the one-time
   guard, so a *non-owner* second caller reverts `NotOwner`, not `ReactiveAlreadySet`. The
   one-time test therefore has the owner call twice.

---

## 5. Tests Passing

Full suite: **123 passing, 0 failing.** (+45 from this session: 32 unit + 3 fuzz + 6 invariant + 4 integration.)

| Suite | Count |
|-------|-------|
| `test/unit/RangeGuardHook.t.sol` | 33 (1 permissions + 32 pool setup) |
| `test/unit/Accrue.t.sol` | 17 |
| `test/unit/ComputeIL.t.sol` | 14 |
| `test/unit/ComputePayout.t.sol` | 15 |
| `test/fuzz/AccrueFuzz.t.sol` | 8 |
| `test/fuzz/ComputeILFuzz.t.sol` | 8 |
| `test/fuzz/ComputePayoutFuzz.t.sol` | 4 |
| `test/fuzz/StagePoolConfigFuzz.t.sol` | 3 |
| `test/invariant/CoverageAccountingInvariant.t.sol` | 6 |
| `test/invariant/SettlementInvariant.t.sol` | 5 |
| `test/invariant/PoolSetupInvariant.t.sol` | 6 |
| `test/integration/PoolSetup.t.sol` | 4 |

Pool-setup invariants → invariant-mapping.md (Pool Setup / Initialization / Reactive registration):
- `invariant_PoolInitializedImpliesPendingSetupDeleted` → "`_poolInitialized[id]` ⟹ `!_pendingSetup[id].exists`"
- `invariant_PoolInitializedImpliesAdminNonZero` → "`_poolInitialized[id]` ⟹ `poolConfig[id].admin != 0`"
- `invariant_PoolInitializedImpliesBufferPctWithinDenom` → "`_poolInitialized[id]` ⟹ `maxPayoutPctOfBuffer ≤ BPS_DENOM`"
- `invariant_ReactiveSetImpliesReactiveNonZero` → "`_reactiveSet[id]` ⟹ `reactiveContract[id] != 0`"
- `invariant_ReactiveSetImpliesInitialized` → "`_reactiveSet[id]` ⟹ `_poolInitialized[id]`"
- `invariant_ReactiveSetIsMonotonicallyTrue` → "`_reactiveSet[id]` is monotonically true"

Invariant run: 500 runs × 50,000 calls each, **0 reverts** (handler advances the state machine
cleanly under randomized ordering). `forge fmt --check` passes; `forge build` clean.

**Integration note:** PoolManager wraps hook reverts in `WrappedError`, so the three init-path
negative tests use `vm.expectRevert()` (any revert) — the specific inner causes
(`PoolNotStaged` / `UnauthorizedInitializer` / `UnexpectedSqrtPrice`, confirmed by selector in
the wrapped payload) are pinned by the unit suite. The integration point is that
`initialize()` reverts wholesale ⇒ no pool created.

---

## 6. Deferred to Next Session (Phase 2 — `afterAddLiquidity()`)

- **`afterAddLiquidity()`** — derive `entryAmt0`/`entryAmt1` from the liquidity delta, compute
  `entryNotionalStable = entryAmt1 + entryAmt0 * P_entry` via the shared `_priceFromTick()`
  helper (same price convention as `_computeIL`), register `PositionState` (active=true),
  call `_accrue()` with dt=0 to seed `lastAccrualTime`, emit `PositionRegistered`. Requires
  `_poolInitialized[id] == true` (lifecycle invariant).
- **Position key** — `keccak256(abi.encode(owner, tickLower, tickUpper, salt))`, scoped by PoolId.
- **IL settlement sequencing** (still carried from sessions 3–4) — spec calls `_computeIL` in
  `beforeRemoveLiquidity`, but v4 withdrawn `outAmt0/outAmt1` are known only *after* removal;
  resolve when wiring `beforeRemoveLiquidity`/`afterRemoveLiquidity`.
- **`onlyReactive` + `emitOutOfRange`/`emitBackInRange`** — implement with the reactive phase;
  guard on `_reactiveSet[id]`.

---

## 7. Note for Maintainer

The `_afterSwap`/`_beforeSwap`/`_afterAddLiquidity`/`_afterRemoveLiquidity`/`_beforeRemoveLiquidity`
skeletons still emit "function state mutability can be restricted to pure" lint notes — expected
for the unimplemented stubs; they fill in during Phase 2 callback work. These are notes, not
warnings, and do not fail `forge build` or CI.
