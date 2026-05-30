# **RangeGuard ---- Technical Specification (MVP)**

# Version 2.0

## 1. Overview

**Purpose**

RangeGuard is a Uniswap v4 hook that provides native, on-chain insurance against impermanent loss (IL) for liquidity providers (LPs). Coverage accrues over time using a day-count convention, is funded by a portions of trading fees via v4 dynamic fees, and is paid out automatically on full withdrawal, subject to three caps.

**Tagline:** "Protect your liquidity. Guard your range."

**MVP Target:** Testnet deployment with a dingle ETH/USDC pool demo

## 2. Pool & Token Model

- token1 = stable (USDC) --- numeraire for all accounting
- token0 = volatile (ETH)
- MVP demo pool: ETH/USDC
- One hook instance supports multiple pools
- Pool price is set a poolManager.initialize() --- completlely separate from the first LP deposit
- First deposit can be:
  - Case A: 100% token0(ETH) --- current price below range
  - Case B: Mixed token0 + token1 --- current price in range (demo case)
  - Case C: 100% token1 (USDC) --- current price above range
- Cases A and C start out of range --- \_accrue gates correctly, no coverage earned until price enters range
- Demo uses Case B: price in range at deposit, accrual starts immediately

## 3. Five Pillars (Final Decisions)

### Pillar 1: Accrual Gating

- Coverage accrues ONLY while LP position is in-range: tickLower <= currentTick < tickUpper
- Day-count convention: Actual/365 Fixed (SECONDS_PER_YEAR = 31,536,000) or A/360 (31,104,000)
- Only these two values accepted at initializePoolConfig() --- all other revert
- Accrual nodel is LAZY --- coverage only computed on explicit touches
  - afterAddLiquidity: dt = 0, initializes lastAccrualTime baseline
  - checkpoint() primary accrual driver between deposit and withdrawal
  - beforeRemoveLiquidity: final accrual update before settlement
- afterSwap does NOT trigger accrual --- it is impossible to iterate all LP positions on-chain(unbounded set, O(N) gas per swap)
- getEarnedCoverage() view function always simulates accrual to block.timestamp --- returns correct live value without requiring a checkpoint first
- Report granularity is driven by checkpoint frequency

### Pillar 2: Buffer Funding

- Dynamic fee mechanism: Total fee = BASE_LP_FEES_BPS + BUFFER_BPS (always derived, never stored separately)
- beforeSwap returns the dynamic fee
- afterSwap handles buffer funding ONLY --- updates bufferBalanceStable, emits BufferFunded
- afterSwap also emits TickUpdated (lightweight event for Reactive Network subscription)
- Buffer is an internal accounting variable in the hook contract (no separate vault in MVP)
- seedBuffer(poolId, amount) callable by admin for demo/testnet seeding
- Buffer grows from ALL swaps regardless of whether any positions is in range

### Pillar 3: Claim Settlement

- minHoldSeconds is a HARD ELIGIBILITY GATE
  - If block.timestamp - depositTime < minHoldSeconds -> payout = 0
  - Emits IneligibleClaim with reason "MIN_HOLD_NOT_MET"
  - Skips all accrual, IL, computation, and payout logic entirely
- Settlement is triggered on full withdrawal only (no partial withdrawals in MVP)
- Settlement flow:
  - beforeRemoveLiquidity: eligibility check -> final \_accrue() -> computeIL() -> computePayout() -> storePendingPayout
  - afterRemoveLiquidity: execute payout -> update buffer -> cleanup position state -> emit events
- IL formula (stable numaraire):
  - P_exit = spot price from current tick (decimal adjusted, USDC per ETH)
  - V_HODL = entryAmt1 + entryAmt0 \* P_exit
  - V_actual = outAmt1 + outAmt0() \* P_exit (fees included)
  - IL_raw = max(0, V_HODL - V_Actual)
- Three payout caps applied in order:
  - IL_covered = IL_raw \* maxPayoutPctOfIl / 10000
  - bufferCap = bufferBalanceStable \* maxPayoutPctOfBuffer / 10000
  - payout = min(IL_covered, earnedCoverageStable, bufferCap)
- LimitingFactor enum recorded with every settlement (see Section 11)

### Pillar 4: LP Transparency (Coverage Report --- Key Differentiator)

The coverage report is RangeGuard's primary differentiating feature. It provide LPs with a complete, verifiable, day-by-day history of their positions -- generated entirely from on-chain events. No off-chain assumptions are required.

Every line in the coverage report maps to a real on-chain event: - PositionRegistered -> entry snapshot (entry date, notional, range, APR) - AccrualUpdated -> accrual periods with isInRange flag and delta earned - PositionOutOfRange ->accrual paused, coverage snapshot at pause - PositionBackInRange -> accrual resumed, coverage snapshot at resume - ClaimSettled -> IL_raw, payout, limitingFactor

Example coverage statement:

Position: ETH/USDC [1800, 2200]
Entry date: Day 0
Entry notional: 10,000 USDC
Coverage APR: 10% (A/365F)

Day 0-15: ☑️ In range -> AccrualUpdated -> +41.10 USDC  
Day 15: ⚠️ PositionOutOfRange (tick:1795)  
Day 15-22 **X** Out of range -> no accural -> +0.00 USDC  
Day 22: ☑️ PositionBackInrange (tick: 1850)  
Day 22-45: ☑️ In range - AccrualUpdated -> +63.01 USDC

Total earned coverage: 104.11 USDC  
IL raw: 87.50 USDC  
IL cap (50%): 43.75 USDC <- binding constraint  
Earned coverage: 104.11 USDC  
Buffer cap: 500.00 USDC  
Payout: 43.75 USDC  
Limiting Factor: IL_CAP

Report granularity is driven by checkpoint frequency. With Reactive Network providing daily (or 2-minuted demo) checkpoints, the report builds automatically with no LP action required

### Piller 5 Pool Parameterization

- ALL parameters are immutable after initializePoolConfig() -- no admin can change them post-init
- PoolConfig initialized atomically during beforeInitialize()
  via hookData decoding
- initializePoolConfig() is internal-only and callable
  exclusively from beforeInitialize()
- Hard bounds enforced at init time -- bad configs revert before any LP touched the pool
- dynamicFeeBps is always derived (baseLPFeeBps + buffer Bps) -- never stored separately, preventing drift
- Only post-init priviledged action: seedBuffer() callable by admin address stored in PoolConfig

## 4. PoolConfig Struct (Immutable)

```
/// @notice Immutable configuration for a single pool, set once at initialization.
/// @dev  All NPS values are 10,000 denominator: APR uses 1e18 fixed-point
struct PoolConfig{

    // Fees
    uint24 baseLpFeeBps;         //LP fee portion     e.g. 3000 = 0.30%
    uint24 bufferBps;            //Buffer fee portion eg. 1000 = 0.10%
    // dynamicFeeBps = baseLpFeeBps + bufferBps (always derived, never stores)

    // Coverage accrual
    uint256 coverageAPR:        // 1e18 fixed-point     e.g. 0.10e18 = 10%
    uint256 secondsPerYear      // A/365F = 31_536_000 | A/360 = 31_104_000

    // Eligibility
    uint32 minHoldSeconds;      // Hard gate: payout = 0 if not met

    // Payout Caps
    uint16 maxPayoutPctOfIl;    // Cap 1: % of IL covered   e.g. 5000 = 50%
    uint16 maxPayoutPctOfBuffer // cap 3: % of buffer       e.g. 1000 = 10%

    // Accrual ceiling
    uint256 maxAccruedCoverageMultiple  // e.g. 3e18 = 3x entryNotional; 0 = disabled

    // Buffer health (informational)
    uint256 targetBufferSize;    // Actuarial target, used in getBufferHealth()

    // Checkpoint rate limiting (per pool)
    uint32 minCheckpointInterval;    // e.g. 2 minute demo / 1 hour mainnet

    // Admin
    address admin;    // seedBuffer() only; no param changes
}
```

### Compile-Time Constants (Hard Bounds)

uint256 constant BPS_DENOM = 10_000;  
uint256 constant APR_PRECISION = 1e18;  
uint24 constand MAX_BASE_FEE_BPS = 10_000;  
uint24 constant MAX_BUFFER_BPS = 5_000;  
uint256 constant MAX_COVERAGE_APR = 0.50e18;  
uint16 constant MAX_PAYOUT_PCT = 10_000;  
uint32 constant MAX_HOLD_SECONDS = 365 days;  
uint256 constant SECONDS_PER_YEAR_365F = 31_536_000;
uint256 constant SECONDS_PER_YEAR_360 = 31_104_000;

### Initialization Function

```
function initializePoolConfig(
    PoolId calldata poolId,
    PoolConfig calldata cfg
    ) internal {
        if (_poolInitialized[poolId]) revert PoolAlreadyInitialized();
        if (cfg.admin == address(0))   revert ZeroAdmin();
        if (cfg.baseLpFeeBps > MAX_BASE-FEE_BPS) revert InvalidFeeConfig();
        if (cfg.bufferBps > MAX_BUFFER_BPS) revert InvalidFeeConfig();
        if (cfg.coverageApr > MAX_COVERAGE_APR) revert InValidApr();
        if (cfg.coverageApr == 0) revert InvalidApr();
        if (cfg.maxPayoutPctOfIl > MAX_PAYOUT_PCT) revert InvalidPayoutCaps();
        if (cfg.maxPayoutPctOfBuffer > MAX_PAYOUT_PCT) revert InvalidPayoutCaps();
        require(
            cfg.secondsPerYear == SECONDS_PER_YEAR_365F ||
            cfg.secondsPerYear == SECONDS_PER_YEAR_360,
            "unsupported day_count"
        );
        poolConfig[poolId] =  cfg;
        _poolInitialized[poolId] = true;
        emit PoolConfigInitialized(poolId, cfg);
    }
```

## 5. State Variables

### Hook-Level Mappings

```
mapping(PoolId => PoolConfig)           public poolConfig;
mapping(PoolId => PoolState)            public poolState;
mapping(PoolId => bool)                 private _poolInitialized;
mapping(PoolId => mappings(bytes32 => PositionState)) public positions;
mapping(PoolId => address)              public reactiveContract;
```

### PositionStateStruct

```
struct PositionState {
    //Snapshot - set once at deposit, never mutated
    uint128 entry_amt0;         //token0 (ETH) amount at deposit
    uint128 entry_amt1;         //token1 (USDC) amount at deposit
    int24 entryTick;            // Pool tick at deposit
    int24 tickLower;            // Position lower tick bound
    int24 tickUpper;            // Position upper tick bound
    uint256 entryNotionalStable // entryAmt1 + entryAmt0 * P_entry (USDC)
    uint32 depositTime;         // block.timestamp at deposit

    // Accrual  -- mutated on every _accrue() call
    uint32 lastAccrualTime;     // Timestamp of last accrual update
    uint256 earnedCoverageStable; // Cumulative coverage earned (USDC)

    // Settlement  -- set in beforeRemoveLiquidity, cleared in afterRemoveLiquidity
    uint256 pendingPayout;      // Computed payout awaiting execution

    // Existence flag
    bool active;                // true = registered, false = clear
}
```

### PositionKey Deriviation

```
/// @notice Derives a unique position key scoped to a pool.
function _positionKey(
    address owner,
    int24 tickLower,
    int24 tickUpper,
    bytes32 salt
 ) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner,tickLower,tickUpper,salt));
    }
```

The outer PoolId key in positions[poolId][positionKey] ensures no cross-pool collisions even if two pools share and identical owner, tick range, and salt

### Entry Notioinal Formula

entryNotionalStable = entryAmt1 + (entryAmt0 \* P_entry)  
where P_entry = spot price at deposit (USDC per ETH), decimal adjusted from current tick

This handles all three deposit cases naturally:  
Case A (price below range): entryAmt1 = 0, notional = entryAmt0 \* P_entry  
Case B (price in range): mixed amounts, standard formula
Case C (price above range): entryAmt0, notional = entryAmt1

## 6. Hook Callbacks & Responsibilities

| Callback              | Responsibility                                                                                                                                                                                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| beforeInitialize      | require key.fee == DYNAMIC_FEE_FLAG, revert with clear error if not set, Decode PoolConfig and reactiveCOntract from hookData, Validate PoolConfig bounds initialize immutable pool configuration, Register reactiveContract for pool, Mark pool as initialized, Prevent silent buffer funding failure |
| afterAddLiquidity     | Derive entryAmt0, entryAmt1 from liquidity delta, compute entryNotitionalStable. Register PositionState (active=true). Call \_accrue() -- dt=0, initializes lastAccrualTime. Emit PositionRegisiterd                                                                                                   |
| beforeSwap            | Return dynamic fee = baseLpFeeBps + bufferBps. No position state touched                                                                                                                                                                                                                               |
| afterSwap             | Compute buffer contribution from swap fee. Update bufferBalanceStable. Emit BufferFunded. Emit TickUpdated (for Reactive Network) NO position accural --- cannot iterate positions                                                                                                                     |
| beforeRemoveLiquidity | Check minHoldSeconds -> if not met: emit IneligibleClaim, return. Call \_accrue() final update. Call \_computeIL(). Call \_computerPayout(). Store pendingPayout. Emit AccrualUpdated                                                                                                                  |
| afterRemoveLiquidity  | Execute pendingPayout transfer to LP. Update bufferBalanceStable and totalPaidOutStable. Clear PositionState (active=false, pendingPayout = 0). Emit ClaimSettled / PartialPayout / NoClaim.                                                                                                           |

## 7. Core Internal Functions

\_accrue()

```
function  _accrue(
    PoolId poolId,
    bytes32 positionKey,
    int24 currentTick
   ) internal {
    PositionState storage pos = position[poolId][positionKey];
    PoolConfig storage cfg = poolConfig[poolId];

    if(!pos.active) return;

    uint256 dt = block.timestamp - pos.lastAccrualTime;
    bool isInRange = pos.tickLower <= currentTick && currentTick < pos.tickUpper;
    uint256 delta = 0;

    if (isInRange && dt > 0) {
        uint256 yearFraction = (dt * APR_PRECISION / cfg.secondsPerYear);
        delta = (pos.entryNotionalStable * cfg.coverageApr * yearFraction)
        / (APR_PRECISION * APR_PRECISION);

        if (cfg.maxAccruedCoverageMultiple > 0) {
            uint256 cap = pos.entryNotionalStable * cfg.maxAccruedCoverageMultiple
            / APR_PRECISION:
            uint256 newTotal = pos.earnedCoverageStable + delta;
            pos.earnedCoverageStable = newTotal > cap ? cap: newTotal;
        } else {
            pos.earnedCoverageStable += delta;
        }
    }

    pos.lastAccrualTime = uint32(block.timestamp);

    emit accrualUpdated(
        poolId,
        positionKey,
        dt,
        delta,
        pos.earnedCoverageStable,
        isInRange,
        timestamp
    );
 }
```

\_computeIL()

```
function _computeIL(
   PositionState memory pos,
   uint128 outAmt0,
   uint128 outAmt1,
   int24 exitTick
 ) internal view returns (uint256 IL_raw) {
       uint256 P_exit = tickToPrice(exitTick); // USDC Per Eth, decimal adjusted
       uint256 V_HODL = pos.entryAmt1 + (uint256(pos.entryAmt0) * P_exit / PRICE_PRECISION);
       uint256 V_actual = uint256(outAmt1) + (uint256(outAmt0) * P_exit / PRICE_PRECISION);
       IL_raw = V_HODL > V_actual ? V_HODL - V_actual: 0;
   }
```

\_computePayout()

```
function _computePayout(
    PoolId     poolId,
    PosititionState memory pos,
    uint256  IL_raw
) internal view returns (uint256 payout, LimitingFactor factor) {
    if (IL_raw == 0) return (0, LimitingFactor.NONE);

    PoolConfig storage cfg = poolConfig[poolId];
    PoolState storage state = poolState[poolId];

    uint256 IL_covered = IL_raw * cfg.maxPayoutPctOfIl /BPS_DENOM;
    uint256 bufferCap = state.bufferBalanceStable * cfg.maxPayoutPctOfBuffer / BPS_DENOM;
    uint256 earned = pos.earnedCoverageStable;

    payout = IL_covered;
    factor = LimitingFactor.IL_CAP;

    if (earned < payout) {
        payout = earned;
        factor = LimitingFactor.COVERAGE_CAP;
    }
    if (bufferCap < payout) {
        payout = bufferCap;
        factor = LimitingFactor.BUFFER_CAP;
    }
}
```

## 8. Checkpoint & Reactive Network

### checkpoint() Function

```
/// @notice Permissionless accrual update for a single position.
/// @dev Primary entry point for Reactive Network automation.
function checkpoint(
    PoolId poolID,
    bytes32 positionKey
) external {
    PositionState storage pos = positions[poolID][positionKey];
    PoolConfig storage cfg = poolConfig[poolId];

    require(pos.active, "position not active");
    require(
        block.timestamp - pos.lastAccrualTime >= cfg.minCheckpointInternal, "TOO_SOON"
    );

    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);

    emit Checkpointed(poolId, positionKey, block.timestamp);
}
```

### Reactive Contract --- Two Jobs

**Job 1: Range Transsition Detection (event-driven)**

- Subscribes to TickUpdated events emitted by the hook in afterSwap
- Tracks lastKnownRangeStatus per posiition in Reactive Contract state
- On tick crossing:
  - If wasInRange && isInRange: call checkpoint() -> hook calls emitOutofRange()
  - If !wasInRange && isInRange: call cehckpoint() -> hook calls emitBackInRange()

**Job 2: Periodic Hearbeat (time-driven)**

- Calls checkpoint() every checkpointInterval for each active in-range position
- Generates intermediate AccrualUpdated events for the coverage report
- Mainnet: every 24 hours | Demo/testnet: every 2 minutes

### Hook Functions Callable by Reactive Contract only

```
/// @dev Access controlled: only reactiveContract[poolId] may call
function emitOutOfRange(
    PoolId poolId,
    bytes32 positionKey,
    int24 currentTick
) external onlyReactive(poolId) {
    PositionState storage pos = positions[poolId][positionKey];

    emit PositionOutOfRange(
        poolId, positionKey, pos.tickLower, pos.tickUpper, currentTick, pos.earnedCoverageStable, block.timestamp
    );
}

function emitBackInRange(
    PoolId poolId,
    bytes32 positionKey,
    int24 currentTick
) external onlyReactive(poolId) {
    PositionState storage pos = positions[poolId][positionKey];

    emit PositionBackInRange(
        poolId, positionKey, pos.tickLower, pos.tickUpper, currentTick, pos.earnedCoverageStable, block.timestamp
    );
}
```

reactiveContract address is stored per pool and (set during beforeInitialize() hookData decoding)

## 9. LimitingFactor Enum

```
enum LimitingFactor {
    NONE,    // IL = 0, no claim needed
    IL_CAP,  // maxPayOutPctOfIl was the binding constraint
    COVERAGE_CAP,  // earnedCoverageStable was the binding constraint
    BUFFER_CAP     // maxPayoutPctOfBuffer was the binding constraint
}
```

LimitingFactor is included in - ClaimSettled event - getEstimatedPayout() view function - Coverage report (frontend dashboard)

This tells the LP exactly which cap constrained their payout --- no ambiguity.

## 10. Event Inventory

| Event                 | When Emitted                               | Key Data                                                                          |
| --------------------- | ------------------------------------------ | --------------------------------------------------------------------------------- |
| PoolConfigInitialized | initializePoolConfig()                     | poolId, all config params                                                         |
| PositionRegistered    | afterAddLiquidity                          | owner, range, entryNotional, depositTime, coverageApr, dayCountBasis              |
| AccrualUpdated        | \_accrue() ---- every call                 | positionKey, dt, delta, newEarnedTotal, isInRange, timestamp                      |
| TickUpdated           | afterSwap ---- every swap                  | poolId, newTick, timestamp (lighweight, for Reactive)                             |
| PositionOutOfRange    | emitOutOfRange() via Reactive              | positionKey, tickLower, tickUpper, currentTick, earnedCoverageAtPause, timestamp  |
| PositionBackInRange   | emitBackInRange() via Reactive             | positionKey, tickLower, tickUpper, currentTick, earnedCoverageAtResume, timestamp |
| BufferFunded          | afterSwap                                  | swapAmount, bufferContribution, newBufferBalance                                  |
| BufferSeeded          | seedBuffer()                               | poolId, amount, newBalance                                                        |
| ClaimSettled          | afterRemoveLiquidity (payout > 0)          | owner, range, IL_raw, earnedCoverage, payout, limitingFactor                      |
| NoClaim               | afterRemoveLiquidity (IL = 0)              | owner, range, V_HODL, V_actual                                                    |
| IneligibleClaim       | beforeRemoveLiquidity (minHold not met)    | owner, range, reason                                                              |
| PartialPayout         | afterRemoveLiquidity (buffer insufficient) | owner, range, requested, actual                                                   |
| Checkpointed          | checkpoint()                               | poolId, positionKey, timestamp                                                    |

## 11. View Function Inventory

### Pool Level

| Function                 | Returns                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| getPoolConfig(PoolId)    | Full PoolConfig struct                                                                   |
| getBufferHealth(PoolId)  | bufferBalanceStable, totalSkimmedStable, totalPaidOutStable, targetBufferSize, healthPct |
| getCurrentFee(PoolId)    | baseLpFeeBps + bufferBps (derived)                                                       |
| getDayCountBasis(PoolId) | "A/365F" or "A/360" (human-readable)                                                     |
| getCoverageAPR(PoolId)   | coverageApr (1e18 fixed-point)                                                           |

### Position Level

| Function                                 | Returns                                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------------------------- |
| getPositionSnapshot(PoolId, positionKey) | entryAmt0, entryAmt1, entryTick, entryNotionalStable, depositTime, tickLower, tickUpper |
| getAccrualState(PoolId, positionKey)     | lastAccrualTime, earnedCoverageStable, isInRange                                        |
| getEarnedCoverage(PoolId, positionKey)   | Simulates accrual to block.timestamp --- always returns live value without checkpoint   |
| getEligibility(PoolId, positionKey)      | eligible (bool), reason (string)                                                        |
| getEstimatedPayout(PoolId, positionKey)  | IL_raw, cappedPayout, limitingFactor (simulated withdrawal)                             |
| getCoverProgress(PoolId, positionKey)    | earned, maxPossible, pctEarned                                                          |

Note: getEarnedCoverage() is they key view function for the frontend dashboard. It always returns the correct current value by simulating the accrual formula
from lastAccrualTime to block.timestamp, applying the in-range gate against the current tick.

The accrual math is implemented once in a shared internal `pure` helper. \_accrue() calls
the helper and writes state (mutating earnedCoverageStable / lastAccrualTime and emitting
AccrualUpdated); getEarnedCoverage() calls the same helper read-only and mutates nothing.
This guarantees the live view and the on-chain accrual can never drift (no duplicated
accrual logic).

## 12. Safety & Governance

- All PoolConfig paramters are immutable after initializePoolConfig()
- Hard bounds enforced at init time for all paramaters
- Single admin per pool for MVP (multisig or DAO recommended for mainnet)
- Admin can only call seedBuffer() ----- no parameter changes possible
- dynamicFeeBps always derived ------ never stored, preventing fee drift
- \_poolInitialized guard prevents re-initialization by any actor
- secondsPerYear validated to only accept A/365F or A/360
- Reentrancy: position state cleared before payout transfer in afterRemoveLiquidity

## 13. MVP Scope

In scope: - Single-range LPs only - Full withdrawal only (no partials) - Spot price for IL calculation(tick-based) -
Fixed dynamic fee per pool - Seeded buffer for demo - Internal buffer accounting (no vault contract) - Multi-pool support (one hook, multiple pools) -
Reactive Network integration for range notifications and checkpoints

Out of scope (Phase 2): - TWAP / Oracle price for IL calculation - Partial withdrawals - Volatility-responsive dynamic fee - LP premium mechanism -
Separate vault contract - Mainnet hardening

## 14. Demo Configuration

### Testnet Deployment Paramaters

| Paramter                    | Demo Value    | Mainnet Value |
| --------------------------- | ------------- | ------------- |
| baseLPFeeBps                | 3,000 (0.30%) | 3,000 (0.30%) |
| bufferBps                   | 1,000 (0.10%) | 1,000 (0.10%) |
| coverageApr                 | 0.50e18 (50%) | 0.10e18 (10%) |
| secondsPerYear              | 31,536,000    | 31,536,000    |
| minHoldSeconds              | 5 minutes     | 7 days        |
| minCheckpointInterval       | 2 minutes     | 1 hour        |
| maxPayoutPctOfIl            | 5,000 (50%)   | 5,000 (50%)   |
| maxPayoutPctOfBuffer        | 1,000 (10%)   | 1,000 (10%)   |
| maxAccruedCoverageMultiple  | 3e18 (3x)     | 3e18 (3x)     |
| targetBufferSize            | 100,000 USDC  | 100,000 USDC  |
| Initial buffer seed         | 10,000 USDC   | TBD           |
| Reactive checkpointInterval | 2 minutes     | 24 hours      |

### Demo Pool Setup

- Pool initialized at ~$2,000/ETH (sqrtPriceX96 set at poolManager.initialize())
- LP deposits mix of ETH + USDC (Case B ---- price in range at deposit)
- Entry notional: ~10,000 USDC
- Range: [$1,800, $2,200]

### Demo Script Narrative Arc (vm.warp in Foundry)

[Setup] Deploy hook, initialize ETH/USDC pool, set PoolConfig  
[Setup] Admin seeds buffer: 10,000 USDC -> BufferSeeded ✓  
 Buffer health: 10,000 /10,000 USDC (100.0%)

[Day 0] LP Deposits mix of ETH + USDC  
 Entry notional: 10,000 USDC | Range: [1800, 2200]  
 PositionRegistered ✓

[Day 3] Swap: 10 ETH -> USDC (in range) -> BufferFunded +4.20 USDC  
[Day 7] Swap: 50,000 USDC -> ETH (in range) - BufferFunded +21.00 USDC  
[Day 12] Swap: 25 ETH -> USDC (in range) -> BufferFunded +10.50 USDC  
[Day 15] Checkpoint -> AccrualUpdated: +41.10 USDC earned ✓

[Day 15] Large swap: 200 ETH -> USDC -> tick crosses tickLower  
 PositionOutOfRange emitted ✓ | Accrual paused at 41.10 USDC  
 BufferFunded +84.00 USDC (buffer grows regardless of range)

[Day 18] Swap out of range -> BufferFunded +12.60 USDC  
 [Day 20] Checkpoint -> AccrualUpdated: +0.00 USDC (isInRange:false) ✓

[Day 22] Large swap: 150,000 USDC -> ETH -> tick crosses tickLower back up  
 PositionBackInRange emitted ✓ | Accrual resumed from 41.10 USDC  
 BufferFunded +63.00 USDC

[Day 30] Swap in range -> BufferFunded +8.40 USDC  
[Day 38] Swap in range -> BufferFUnded + 16.80 USDC  
[Day 45] Checkpoint -> AccrualUpdated: +63.01 USDC | Total: 104.11 USDC ✓

[Day 45] LP withdraws full position  
 IL raw: 87.50 USDC  
 IL cap (50%) 43.75 USDC <- binding constraint  
 Earned coverage: 104.11 USDC  
 Buffer cap: 1,022.05 USDC  
 Payout: 43.75 USDC  
 Limiting factor: IL_CAP  
 ClaimSettled ✓

[Final] Initial Seed: 10,000.00 USDC  
 Fees skimmed: 220.50 USDC  
 Paid out: 43.75 USDC  
 Buffer balance: 10,176.75 USDC (101.8% health --- self-sustaining ✓ )

## 15. Recorded Demo Structure (5 minutes)

| Segment          | Duration  | Content                                      | Tool     |
| ---------------- | --------- | -------------------------------------------- | -------- |
| The Problem      | 0:00-0:40 | IL explained, HODL vs LP value loss          | Slides   |
| The Solution     | 0:40-1:20 | Five Pillar visuual, self funding buffer     | Slided   |
| Code Walkthrough | 1:20-200  | PoolConfig, \_accrue(), \_computePayout()    | IDE      |
| Demo Script      | 2:00-4:15 | Full lifecycle with swaps, range transitions | Terminal |
| Coverage Report  | 4:15-4:45 | Frontend dashboard, day-by-day statement     | Browser  |
| Closing          | 4:45-5:00 | Tagline, Github link, testnet link           | Slide    |

## 16. Build Order

1. \_accrue() --- accrual engine (lazy, in-range gated, A/365F)
2. \_computeIL() --- spot price IL calculation with decimal adjustment
3. \_computePayout() --- three-cap logic + LimitingFactor determination
4. Hook callbacks --- wire all five callbacks together
5. checkpoint() ---- permissionless + Reactive Network entry point
6. Reactive Contract --- range transition detection + periodic heartbeat
7. Frontend dashboard --- coverage report rendered from on-chain events
8. Demo script --- RangeGuardDemo.s.sol with vm.warp

## 17. Referencces

- [Uniswap v4 Core Docs]
- [Uniswap v4 Periphery Docs]
- [Uniswap v4 Hooks public Docs]
- [Foundry Docs]
- [Reactive Network Docs]
