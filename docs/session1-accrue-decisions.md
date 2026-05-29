# RangeGuard — Session Decisions: `_accrue()` Implementation

This document records every decision locked during the `_accrue()` design and
implementation session. It is a canonical reference; treat it as authoritative
alongside spec.md / context.md / state-machine.md / invariant-mapping.md.

---

## 1. Risk Register & Resolutions

| # | Risk | Resolution |
|---|------|-----------|
| 1 | Spec code is pseudocode with typos; not compilable | **Treat spec code as intent, not literal source.** Claude writes the compilable implementation. |
| 2 | `_accrue()` signature mismatch — spec §7 (3-arg) vs §8 `checkpoint()` (4-arg) | **`_accrue(PoolId, bytes32 positionKey, int24 currentTick)` — 3 args.** `timestamp` is NOT a parameter; `block.timestamp` is read internally. `checkpoint()` corrected to call it with 3 args (fixed in spec.md §8 and context.md §11). |
| 3 | `getEarnedCoverage()` could duplicate accrual logic (forbidden) | **Shared internal `pure` helper** (`_accrueEarned`) holds the accrual math + ceiling clamp. `_accrue()` calls it and writes state; `getEarnedCoverage()` calls it read-only. One formula, cannot drift. (Recorded in spec.md §11.) |
| 4 | Multiplication ordering / overflow in delta math | **Approved simplified one-truncation formula** (see §2). Overflow analysis approved: worst case ≈ 7.3e65 < uint256 max (~1.15e77). |
| 5 | `uint32` timestamp truncation + dt underflow | **uint32 overflow acceptable for MVP testnet.** Added **dt underflow guard** that fail-safes to `dt = 0` (no revert). |
| 6 | Decimal handling / `tickToPrice()` for IL | **Out of scope here** — belongs to `_computeIL()` in a later session. |
| 7 | Reentrancy in settlement | **Future-phase concern.** `pendingPayout` design (state cleared before transfer) is correct as specified. |

---

## 2. Approved Scaling Formula

Algebraically identical to the spec's two-division form, but with one truncation:

```
delta = (entryNotionalStable * coverageApr * dt) / (secondsPerYear * APR_PRECISION)
```

- **One truncation** instead of two (no intermediate `yearFraction` rounding).
- **Rounds down** (integer division) → conservative; buffer never over-pays. Correct
  direction for insurance accounting.
- **Units:** `notional[1e6] × apr[1e18] × dt[s] / (spy[s] × 1e18)` → the `1e18` cancels,
  `dt/spy` is the year fraction → result in the same stable scale as notional.

**Overflow analysis (approved):** with `coverageApr ≤ 0.5e18`, `dt ≤ ~4.29e9` (uint32),
`entryNotional ≤ uint128 max ≈ 3.4e38`, worst-case numerator ≈ **7.3e65** < uint256 max
(~1.15e77). Solidity 0.8.26 checked arithmetic is the backstop.

**Accrual ceiling (unchanged):**
```
cap          = entryNotionalStable * maxAccruedCoverageMultiple / APR_PRECISION   (0 = disabled)
newEarned    = min(currentEarned + delta, cap)
appliedDelta = newEarned - currentEarned        // post-clamp; Σ deltas == earned
```

**dt underflow guard (approved):**
```
dt = block.timestamp > lastAccrualTime ? block.timestamp - lastAccrualTime : 0
```

---

## 3. Approved Edge Case Table

| Case | Behavior |
|------|----------|
| `!active` | Early return — no writes, **no event**. |
| `dt == 0` (same block / add-liquidity baseline) | `delta = 0`; `lastAccrualTime` not rewritten; emits `AccrualUpdated(dt=0, delta=0)`. |
| Out of range, `dt > 0` | `delta = 0`, coverage unchanged, `lastAccrualTime` advances, event `isInRange=false`. |
| `currentTick == tickLower` | **In range** (inclusive lower bound). |
| `currentTick == tickUpper` | **Out of range** (exclusive upper bound). |
| Ceiling reached | `delta` clamped; `appliedDelta < rawDelta`; `earned == cap`. |
| Already at cap | `appliedDelta = 0` even while in range. |
| `maxAccruedCoverageMultiple == 0` | Ceiling disabled — no clamp. |
| `lastAccrualTime > block.timestamp` | Guarded → `dt = 0` (no revert, no underflow). |
| `entryNotionalStable == 0` / `coverageApr == 0` | Helper returns `delta = 0`. |

**Modeling note (by design):** `_accrue()` evaluates `isInRange` from the single
`currentTick` sample for the whole `dt`. Range transitions between touches are resolved
by Reactive Network checkpoints on boundary crossings — "report granularity is driven by
checkpoint frequency." Not a bug.

---

## 4. Approved `AccrualUpdated` Event Fields

```solidity
event AccrualUpdated(
    PoolId  indexed poolId,
    bytes32 indexed positionKey,
    uint256 dt,
    uint256 delta,          // applied delta (post-ceiling clamp)
    uint256 newEarnedTotal,
    bool    isInRange,
    uint256 timestamp
);
```

- `poolId` included (multi-pool coverage-report indexing).
- `yearFraction` dropped (derivable off-chain from `dt` + `secondsPerYear`; keeps event lean).
- `poolId` + `positionKey` indexed for efficient per-position filtering.

---

## 5. PoolId Import Decision

**Approved:** import `{PoolId}` from `v4-core/types/PoolId.sol` and key the mappings by it
now. Matches spec exactly.

```solidity
import {PoolId} from "v4-core/types/PoolId.sol";

mapping(PoolId => PoolConfig) public poolConfig;
mapping(PoolId => mapping(bytes32 => PositionState)) public positions;
```

---

## 6. Test Seeding Decision

**Approved:** use a **dedicated test harness contract** that `extends RangeGuardHook` and
exposes an internal setter to seed `PositionState` directly.
- **No test-only code in the production contract.**
- Follows the established `BaseRangeGuardTest` pattern.
- Harness also exposes the internal `_accrue()` for direct unit testing.

---

## 7. Approved Implementation Design

**Function signatures:**
```solidity
function _accrue(PoolId poolId, bytes32 positionKey, int24 currentTick) internal;

function _accrueEarned(
    uint256 currentEarned,
    uint256 entryNotionalStable,
    uint256 coverageApr,
    uint256 secondsPerYear,
    uint256 maxAccruedCoverageMultiple,
    uint256 dt,
    bool    isInRange
) internal pure returns (uint256 newEarned, uint256 appliedDelta);
```

**Responsibilities:** advance one position's earned coverage to `block.timestamp`; gate on
`active` + in-range + `dt > 0`; delegate math/clamp to the pure helper; never iterate; never
touch the entry snapshot.

**Storage reads:** `positions[poolId][positionKey]` → `active`, `lastAccrualTime`,
`tickLower`, `tickUpper`, `entryNotionalStable`, `earnedCoverageStable`;
`poolConfig[poolId]` → `coverageApr`, `secondsPerYear`, `maxAccruedCoverageMultiple`.
`currentTick` is passed in (not read); `block.timestamp` read internally.

**Storage writes:** `earnedCoverageStable` only when `appliedDelta > 0`;
`lastAccrualTime` only when `dt > 0`; zero writes when `!active`.

**Supporting state introduced (minimum to compile + test):**
- Constant `APR_PRECISION = 1e18`.
- Structs `PoolConfig`, `PoolState`, `PositionState` (packed: snapshot amounts in slot 0;
  ticks + timestamps + `active` packed in slot 1).
- Mappings `poolConfig`, `positions`.
- Event `AccrualUpdated`.
- No custom errors (guards/early-returns, not reverts).

**Deferred:** `getEarnedCoverage()` (needs live tick / StateLibrary), `checkpoint()`,
`poolState`/`_poolInitialized`, callback wiring — all later steps per build order.

**Section order:** per CLAUDE.md (Type declarations → State variables → Events → Errors →
Modifiers → Functions; functions ordered constructor → external → public → internal → private).

---

## 8. Implementation Status (end of session)

- ✅ `src/RangeGuardHook.sol` — `_accrue()` + `_accrueEarned()` + supporting state implemented.
- ✅ `forge build` succeeds (pre-existing warnings only; `i_manager` lint note overridden by CLAUDE.md `i_` rule).
- ✅ Existing `test_getHookPermissions()` still passes.
- ⏭️ Next: `_accrue()` unit → fuzz → invariant tests (via dedicated harness), then `_computeIL()`.
