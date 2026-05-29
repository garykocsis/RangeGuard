# RangeGuard Context Packet

## 1. Project summary

RangeGuard is a Uniswap v4 hook that provides native, on-chain insurance against impermanent loss (IL) for liquidity providers (LPs). Coverage accrues over time using a day-count convention, is funded by a portion of swap fees via v4 dynamic fees, and pays out automatically on full withdrawal, subject to three caps. MVP targets testnet with a single ETH/USDC pool demo.

Tagline:"Protect your liquidity. Guard your range."

## 2. Current Implementation Status

Completed:

- Foundry scaffold
- Hook contract skeleton
- getHookPermissions() in test/unit
- deployment script
- BaseRangeGuardTest.t.sol in test/shared
- spec.md
- state-machine.md
- invariant-mapping.md
- testing-strategy.md

Next implementation target:

- \_accrue()

Planned next steps:

- \_computeIL()
- \_computePayout()
- hook callback wiring
- checkpoint()
- Reactive contract
- frontend dashboard

Recent architecture update:

- PoolConfig initialization moved into beforeInitialize()
- initializePoolConfig() now internal-only
- Pool initialization is now atomic
- DYNAMIC_FEE_FLAG enforcement added at initialization

## 3. Related Documents:

- spec.md
- state-machine.md
- invariant-mapping.md
- testing-strategy.md

## 4. MVP design decisions (locked)

Pool & Token Model:

- token1 = stable (USDC, numeraire for all accounting)
- token0 = volatile (ETH)
- MVP demo pool: ETH/USDC
- One hook instance supports multiple pools
- Pool price set at poolManager.initialize() - separate from first deposit
- First deposit can be 100% token0, 100% token1, or mixed depending on where current tick sits relative to LP range (standard v4 mechanics)

LP Scope

- Single-range LPs only
- Full withdrawal triggers settlement (no partials in MVP)
- Demo uses Case B deposit: price in range at deposit, accrual starts immediately

Config Model:

- PoolConfig is immutable after initializePoolConfig()
- One PoolConfig per pool, keyed by PoolId
- intitiazlizePoolConfig() callable once per pool (guarded by \_poolInitialized mapping)
- Only priviledged post-init action: seedBuffer() by admin

## 5. FIVE PILLARS (FINAL)

Pillar 1 - Accrual Gating:

- Accrues only if tickLower <= currentTick < tickUpper
- Day-count: Actual/365 Fixed (SECONDS_PER_YEAR = 31,536,000)
  or A/360 (31,104,000) validated at init, not other values accepted
- Accrual is LAZY - only computed on explicit touches
  - afterAddLiquidity (dt = 0, initializes lastAccrualTime)
  - checkpoint() (primary accrual driver)
  - beforeRemoveLiquidity (final accrual before settlement)
- afterSwap does NOT accrue (cannot iterate positions)
- getEarnedCoverage() view simulates accrual to block.timestamp so it always return correct live value without a checkpoint

Pillar 2 - Buffer Funding:

- Dyanmic fee = BASE_LP_FEE-BPS + BUFFER_BPS (always derived, never stored)
- beforeSwap returns dynamic fee
- afterSwap handles buffer funding ONLY - updates bufferBalanceStable
- Buffer is internal accounting variable in hook contract (no vault)
- seedBuffer(poolId, amount) callable by admin for demo/testnet
- Buffer grows from ALL swaps regardless of whether positions are in range

Piller 3 - Claim Settlement:

- minHoldSeconds = HARD ELIGIBILITY GATE (Option A);
  - if block.timestmap - depositTime < minHoldSecods -> payout = 0
  - emits IneligibleClaim, skips all accrual/IL/payout logic
- Settlement flow:

```
        beforeRemoveLiquidity: eligibility check -> final _accrue() ->
               _computeIL() -> _computePayout()  ->
               store pendingPayout
        afterRemoveLiquidity: execute payout -> update buffer ->
                              cleanup state -> emit events
```

- IL formula (stable numeraire):

```
        P_exit   = spot price from current tick (decimal adjusted)
        V_HODL   = entryAmt1 + entryAmt0 * P_exit
        V_actual = outAmt1 + outAmt0 * P_exit
        IL_raw   = max(0, V_HODL - V_actual)
```

- Three payout caps:

```
        IL_covered = IL_raw * maxPayoutPctOf IL / 10000
        bufferCap  = bufferBalanceStable * maxPayoutPctOfBuffer / 10000
        payout     = min(IL_covered, earnedCoverageStable, bufferCap)
```

- LimitingFactor enum recorded with every settlement:

```
        enum LimitingFactor { NONE, IL_CAP, COVERAGE_CAP, BUFFER_CAP }
```

Pillar 4 - LP Transparency (Coverge Report - KEY DIFFERENTIATOR)

- All accrual, buffer, and payout data available via view functions and events
- Coverage report generated from on-chaing events - fully verifiable, no off-chain assumptions
- Every line in the report maps to a real on-chain event:

```
        Positionregistered         ->  entry snapshot
        AccrualUpdated             ->  accrual periods (in-range and out-of-range)
        PositionOutOfRange         ->  accrual paused
        PositionBackInRange        ->  accrual resumed
        ClaimSettled               ->  IL, payout, limitingFactor
```

- Report granularity driven by checkpoint frequency
- getEarnedCoverage() always returns correct live value (simulates to now)
- LimitingFactor tells LP exaclty which cap constrained their payout

Piller 5 - Pool Parameterization:

- All parameters immutable after initializePoolConfig()
- No admin can change parameters post-init
- Only poat-init priviledged action: seedBuffer() by admin
- Hard bounds enforced at init time (bad configs revert)
- dynamicFeeBps always derived (baseLpFeeBps + bufferBps), never stored

## 6. Non-Negotiable Architecture Rules

- afterSwap must never iterate all LP positions
- dynamicFeeBps must always be derived
- PoolConfig parameters are immutable after initialization
- Reactive contracts must never mutate accounting state
- accrual is always lazy
- coverage only accrues while in range
- pools must be initialized with DYNAMIC_FEE_FLAG enabled
- pool initialization and PoolConfig setup are atomic

## 7. POOLCONFIG STRUCT (FINAL, IMMUTABLE)

```
struct PoolConfig {
    // Fees
    uint24 baseLpFeeBps;            // e.g. 3000 = 0.30%
    uint24 bufferBps;               // e.g. 1000 = 0.10%
    // dynamicFeeBps = baseLPFeeBps + bufferBps (derived)

    // Coverage accrual
    uint256 coverageApr;            // 1e18 fixed-point  e.g. 0.10e18 = 10%
    uint256 secondsPerYear;         // 31,536,000 (A/365F) or 31,104,000 (A/360)

    // Eligibility
    unint32 minHoldSeconds;         // hard gate: payout = 0 if not met

    // Payout caps
    uint16 maxPayoutPctOfIl;        // e.g. 5000 = 50%
    uint16 maxPayoutPctOfBuffer;    // e.g. 1000 = 10%

    // Accrual ceiling
    uint16 maxAccruedCoverageMultiple; // e.g. 3e18 = 3x notional; 0 = diabled

    // Buffer health (information)
    uint256 targetBufferSize;       // used in getBufferHealth() view only

    // Checkpoint rate liniting (per pool)
    uint32 minCheckpointInterval;   // e.g. 2 min demo, 1 hour mainnet

    // Admin
    address admin;                  // seedBuffer() only
}
```

## 8. STATE VARIABLES (FINAL)

```
// Compile-time constants
uint256 BPS_DENOM               = 10,000
uint256 APR_PRECISION           = 1e18
uint24 MAX_BASE_FEE_BPS         = 10,000
uint24 MAX_BUFFER_BPS           = 5,000
uint256 MAX_COVERAGE_APR        = 0.50e18
uint16 MAX_PAYOUT_PCT           = 10,000
uint32 MAX_HOLD_SECONDS         = 365 days
uint256 SECONDS_PER_YEAR_365F   = 31,536,000
uint256 SECONDS_PER_YEAR_360    = 31,104,000

// Hook-level mappings
mapping(PoolId => PoolConfig)   poolConfig
mapping(PoolId => PoolState)    poolState
mapping(PoolID => bool)         _poolInitialized
mapping(PoolId => mapping(bytes32 => PoitionState)) positions

struct PoolState {
    uint256 bufferBalanceStable     // current buffer (USDC units)
    uint256 totaSkimmedStable       // cummulative buffer funded from fees
    uint256 totalPaidOutStable      // cummulative payout
}

struct PositionState {
    // Snapshot (set once at deposit)
    uint128 entryAmt0               // token0 (ETH) at deposit
    uint128 entryAmt1               // token1 (USDC) at deposit
    int24 entryTick                 // pool tick at deposit
    int24 tickLower                 // position lower bound
    int24 tickUpper                 // position upper bound
    uint256 entryNotionalStable     //entryAmt1 + entryAmt0 * P_entry
    uint32 depositTime              // block.timestamp at deposit

    // Accrual (mutated on every _accrue() call)
    uint32 lastAccrualTime          // timestamp of last accrual update
    uint256 earnedCoverageStable    // cummulative coverage earned (USDC)

    // Settlement
    uint256 pendingPayout           // computed payout awaiting execution

    // Existence
    bool active                     // true = registered
}
positionKey = keccak256(abi.encode(owner, tickLower, tickUpper, salt))
Outer key = PoolId -> no cross-pool collisions
```

## 9. HOOK CALLBACKS (FINAL)

beforeInitialize

- validates DYNAMIC_FEE_FLAG
- decodes PoolConfig from hookData
- validates immutable config bounds
- initializes PoolConfig atomically
- registers reactiveContract
- prevents partially initialized pools

afterAddLiquidity

- Derive entryAmt0, entryAmt1 from liquidity delta
- Compute entryNotionalStable = entryAmt1 + entryAmt0 \* P_entry
- Register PositionState (active = true)
- Call \_accrue() - dt = 0, initializes lastAccrualTime
- Emit PositionRegistered

beforeSwap:

- Return dynamic fee = baseLPFeeBPS + bufferBPS
- No position state touched

afterSwap:

- Compute buffer contribution from swap fee amout
- Update bufferBalanceStable
- Emit BufferFunded
- Emit TickUpdated (for Reactive Network subscription)
- No position accrual (cannot iterate positions)

beforeRemoveLiquidity:

- Check minHoldSeconds -> if not met: emit IneligibleClain, return
- Check \_accrue() - final accrual update
- Call \_computeIL() - spot price IL calculations
- Call \_computePayout() - apply three caps, determine LimitingFactor
- Store pendingPayout
- Emit NoClaim (if IL = 0) or AccrualUpdated

afterRemoveLiquidity:

- Execute pendingPayout -> transfer USDC to LP
- Update bufferBalanceStable, totalPaidOutStable
- Clear PositionState (active = false, pendingPayout = 0)
- Emit ClaimSettled / PartialPayout / NoClaim
- Emit BufferFunded (final state)

## 10. CORE INTERNAL FUNCTIONS

\_accrue(PoolId, bytes32 positionKey, int24 currentTick, unit256 timestamp):

- Gate: if not active -> return
- dt = timeStamp - lastAccrualTime
- isInRange = tickLower <= currentTick < tickUpper

```
    if isInRange && dt > 0
        yearFraction = dt * APR_PRECISION / secondsPerYear
        delta = entryNotionalStable * coverageApr * yearFraction
               / (APR_PRECISION * APR_PRECISION)
        if maxAccruedCoverageMultiple > 0;
           cap = entryNotionalStable * maxAccruedCoverageMultiple / APR_PRECISION
           earnedCoverageStable = min(eanredCoverageStable + delta, cap)
        else:
            earnedCoverageStable + - delta
```

- always: lastAccrualTime = timestamp
- Emit AccrualUpdated(positionKey, dt, yearFraction, delta,
  newEarnedTotal, isInRange)

\_computeIL(PositionState, uint128 outAmt0, uint128 outAmt1, int24 exitTick)

- P_exit = \_tickToPrice(exitTick) (decimal adjusted, USDC per ETH)
- V_HODL = entryAmt1 + entryAmt0 \* P_exit
- V_actual = outAmt1 + outAmt0 \* P_exit
- IL_raw = max(0, V_HODL - V_actual)
- return IL_raw

\_computePayout(PoolId, PositionState, uint256 IL_raw)

- IL_covered = IL_raw \* maxPayoutPctOfIl / BPS_DENOM
- bufferCap = bufferBalanceStable \* maxPayoutOfBuffer / BPS_DENOM
- payout = min(IL_covered, earnedCoverageStable, bufferCap)
- limitingFactor:

```
    if IL_raw = 0           -> NOME
    if binding = IL_covered -> IL_CAP
    if binding = earned     -> COVERAGE_CAP
    if binding = bufferCap  -> BUFFER_CAP
```

- return (payout, limitingFactor)

## 11. CHECKPOINT & REACTIVE NETWORK

checkpoint(POOLId pooliId, bytes32 positionKey):

- Permissionless, one position per call
- Required dt > = minCheckpointInterval (from PoolConfig, per pool)
- Call \_accrue() with current tick and block.timestamp
- Emit AccrualUpdated (and optionally Checkpointed)

Reactive Contract responsibilities:  
 Job 1 - Range transition detection (event-driven):

- Subscribe to TickUpdated events from hook
- Track lastKnownRangeStatus per position (in Reactive state)
- on tick crossing:

```
        if wasInRange && !isInRange:
            call checkpoint()  -> hook calls emitOutOfRange()
        if !wasInRange && isInRange:
            call checkpoint() - hook calls emitBackInRange()
```

Job 2 - Periodic hearbeat (time-driven):

- Call checkpoint() every checkpointInterval for each active in-range position
- Generates intermediate AccrualUpdated events for coverage report

Hook functions callable by Reactive Contract only:

<div style="margin-left: 30px;">
emitOutOfRange(PoolId, bytes32 positionKey, int24 currentTick) <br>
emitBackInRange(PoolId, bytes32 positionKey, int24 currentTick) <br>
(access controlled: only reactiveContract address per pool)  <br> <br>
</div>
reactiveContract address stores per pool (set at initializedPoolConfig

## 10. EVENTS (FINAL)

| Event                 | Desc                                     |
| --------------------- | ---------------------------------------- |
| PoolConfigInitialized | intializePoolConfig()                    |
| PositionRegistered    | afterAddLiquidity                        |
| AccrualUpdated        | \_accrue() - every call                  |
| TickUpdated           | afterSwap - every swap (lightweight)     |
| PositionOutOfRange    | emitOutOfRange() via Reactive            |
| PositionBackIngRange  | emitBackInRange() via Reactive           |
| BufferFunded          | afterSwap                                |
| BufferSeeded          | seedBuffer()                             |
| ClaimSettled          | afterRemoveLiquidity (successful payout) |
| NoClaim               | IL = 0 on withdrawal                     |
| IneligibleClaim       | minHoldSeconds not met                   |
| PartialPayout         | buffer insufficient for full payout      |
| FeeParamtersUpdated   | (reserved - params immutable in MVP)     |

### 12. VIEW FUNCTIONS (FINAL)

Pool level:

```
  getPoolConfig(PoolId)                 -> full PoolConfig struct
  getBufferHealth(PoolId)               -> balance, skimmed, paidOut, targetSize
  getCurrentFee(PoolId)                 -> baseLpFeeBps + bufferBps
  getCayCountBasis(Poolid)              -> "A/365F" or "A/360"
  getCoverageAPR(PoolId)                -> coverageApr
```

Position level:

```
  getPositionSnapShot(PoolId, positionKey)       -> entry State
  getAccrualState(PoolId, positionKey)           -> lastAccrualTime, earnedCoverageStable, isInRange
  getEarnedCoverage(PoolId, positionKey)         -> simulated accrual to now
                                                 (always live, no checkpoint needed)
  getEligibilityPayout(PoolId, positionKey)      -> IL_raw, cappedPayout, limitingFactor
  getCoverageProgress(PoolId, positionKey)       -> earned, maxPossible, pctEarned
```

## 13. LIMITING FACTOR ENUM

```
enum LimitingFactor {
    NONE,           // IL = 0, no claim needed
    IL_CAP,         // maxPayoutPctOfIl was binding constraint
    COVERAGE_CAP,  // earnedCovergeStable was binding constraint
    BUFFER_CAP      // maxPayoutPctOfBuffer was binding constraint
}
```

## 14. ENTRY NOTIONAL - CLARIFICATION

entryNotionalStable - entryAmt1 + (entryAmt0 \* P_entry)

- P_entry derived from current tick at deposit (decimal adjusted)
- Handles all three deposit cases:
  - Case A: currentTick < tickLower -> 100% token0, entryAmt1 = 0
  - Case B: tickLower <= tick < tickUpper -> mixed amounts (demo case)
  - Case C:currentTick >- tickUpper - > -> 100% token1, entryAmt0 = 0
- Cases A and C start out of range ->acrue() gates correctly
- Demo uses Case B: price in range at deposit, accrual starts immediately

### 15. DEMO CONFIGURATION

Testnet deployment parameters:
| Params |Values |
| ----- | --- |
| baseLpFeeBps | 3,000 (0.30%) |
| bufferBps | 1,000 (0.10%) |
| coverageApr | 0.50e18 (50% APR - visicable accrual)
| secondsPerYear | 31,356,000 |
| minHoldSeconds | 5 minutes |
| minCheckPointInterval | 2 minutes |
| maxPayOutPctOfIl | 5,000 (50%) |
| maxPayoutPctOfBuffer |1,000 (10%) |
| maxAccruedCoverageMultiple | 3e18 (3x notional cap) |
| targetBufferSize | 100,000 USDC |
| Initial buffer sees | 10,000 USDC |

Demo script approach:

- use vm.warp in Foundry script to simulate 45 day lifecycle
- Pre-seed rich AccrualUpdated + range transition event history on testnet before demo
- Live demo show: one real withdrawal + ClaimSettled firing live
- Reactive Network: checkpointInterval = 2 minutes on testnet

Demo Pool setup:

- Pool initialized at ~2,000/ETH (sqrtPriceX96 set at initialize()
- LP deposits mix of ETH + USDC (case B - price in range)
- Entry Notioinal: ~10,000 USDC
- Range: [1,800, 2,200]

Demo script narrative arc:  
| Day | Action |
| ----- | --- |
| Setup | Deploy hook, init pool, set config, seed buffer 10,000 USDC |
| Day 0 | LP deposits -> PositionRegisterd |
| Day 3 | Swap in range -> BufferFunded |
| Day 7 | Swap in range -> BufferFunded |
| Day 12 | Swap in range -> BufferFunded |
| Day 15 | Checkpoint -> AccrualUpdated (+41.10 USDC) |
| Day 15 | Large swap -> price exists range -> PositionOutOfRange |
| Day 18 | Swap out of range -> BufferFunded (buffer grows regardless) |
| Day 20 | Checkpoint -> AccrualUpdated (+0.0 USDC, isInRange: false) |
| Day 22 | Large Swap -> price returns -> PositionBackInRange |
| Day 30 | Swap in range -> BufferFunded |
| Day 38 | Swap in range -> BufferFunded |
| Day 45 | Checkpoint -> accrualUpdated (+63.01 USDC, total: 104.11 USDC) |
| Day 45 | LP withdraws -> ClaimSettled
| | IL raw: 87.50 USDC | Payout: 43.75 USDC | LimitingFactor: IL_CAP |
| Final | Buffer: 10,176.75 USDC (101.8% health -- self-sustaining [x]) |

### 16. RECORDED DEMO STRUCTURE (5 MINUTES)

| Time      | Desc1            | Desc2                                       |
| --------- | ---------------- | ------------------------------------------- |
| 0:00-0:40 | The Problem      | slides                                      |
| 0:40-1:20 | The Solution     | slides - 5 pillars visual                   |
| 1:20-2:00 | Code Walkthrough | IDE - PoolConfig, \_accrue, \_computePayout |
| 2:00-4:15 | Demo script runs | terminal - Foundry script with vm.warp      |
| 4:15-4:45 | Coverage Report  | frontend dashboard                          |
| 4:45-5:00 | Closing          | slide - tagline + links )                   |

### 17. BUILD ORDER

| Step | Action             | Desc1                                 |
| ---- | ------------------ | ------------------------------------- |
| 1.   | \_accrue()         | accrual engine                        |
| 2.   | \_computeIL()      | IL math                               |
| 3.   | \_computePayout()  | thre-cap logic + limitingFactor       |
| 4.   | Hook callbacks     | wire everything together              |
| 5.   | checkpoint()       | permissionless + reactive entry point |
| 6.   | Reactive Contract  | range detection + heartbeat           |
| 7.   | FrontEnd dashboard | coverage report from events           |
| 8.   | Demo script        | RangeGuardDemo.s.sol with vm.warp     |

### 18. REFERENCES

- Uniswap v4 Core Docs
- Uniswap v4 Periphery Docs
- Uniswap V4 Hook Docs
- Foundry Docs
- Reactive Network Docs
