# RangeGuard Context Packet

## 1. Project Summary

RangeGuard is a Uniswap v4 hook that provides native, on-chain insurance against impermanent loss (IL) for liquidity providers (LPs). Coverage accrues over time using a day-count convention, is funded by a portion of swap fees via v4 dynamic fees, and pays out automatically on full withdrawal, subject to three caps. MVP targets testnet with a single ETH/USDC pool demo.

Tagline: "Protect your liquidity. Guard your range."

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

- stagePoolConfig() + \_beforeInitialize() + setReactiveContract()

Planned next steps:

- afterAddLiquidity()
- beforeSwap() / afterSwap()
- beforeRemoveLiquidity() / afterRemoveLiquidity()
- checkpoint()
- Reactive contract
- Frontend dashboard

Recent architecture update:

- v4 beforeInitialize has no hookData --- pool config cannot be passed through the callback
- Three-phase pool setup introduced: stagePoolConfig (Phase 1) -> \_beforeInitialize commit (Phase 2) -> setReactiveContract (Phase 3)
- Reactive contract has circular deployment dependency with hook --- registration deferred to Phase 3
- \_reactiveSet guard ensures reactive address is set exactly once and permanently locked
- authorizedInitializer and expectedSqrtPriceX96 stored in PendingPoolSetup to prevent unauthorized or wrong-price initialization

## 3. Related Documents

- spec.md
- state-machine.md
- invariant-mapping.md
- testing-strategy.md

## 4. MVP Design Decisions (locked)

Pool & Token Model:

- token1 = stable (USDC, numeraire for all accounting)
- token0 = volatile (ETH)
- MVP demo pool: ETH/USDC
- One hook instance supports multiple pools
- Pool price set at poolManager.initialize() - separate from first deposit
- First deposit can be 100% token0, 100% token1, or mixed depending on where current tick sits relative to LP range (standard v4 mechanics)

LP Scope:

- Single-range LPs only
- Full withdrawal triggers settlement (no partials in MVP)
- Demo uses Case B deposit: price in range at deposit, accrual starts immediately

Config Model:

- PoolConfig fields are immutable after pool initialization (\_beforeInitialize commit)
- One PoolConfig per pool, keyed by PoolId
- Three-phase pool setup: stagePoolConfig (owner) -> \_beforeInitialize (commit) -> setReactiveContract (owner, one-time)
- Post-init privileged actions (ordered): setReactiveContract() (owner, one-time), then seedBuffer() (admin)

## 5. Five Pillars (Final)

Pillar 1 - Accrual Gating:

- Accrues only if tickLower <= currentTick < tickUpper
- Day-count: Actual/365 Fixed (SECONDS_PER_YEAR = 31,536,000)
  or A/360 (31,104,000) --- validated at stagePoolConfig(), no other values accepted
- Accrual is LAZY - only computed on explicit touches
  - afterAddLiquidity (dt = 0, initializes lastAccrualTime)
  - checkpoint() (primary accrual driver)
  - beforeRemoveLiquidity (final accrual before settlement)
- afterSwap does NOT accrue (cannot iterate positions)
- getEarnedCoverage() view simulates accrual to block.timestamp so it always returns correct live value without a checkpoint

Pillar 2 - Buffer Funding:

- Dynamic fee = baseLpFeeBps + bufferBps (always derived, never stored)
- beforeSwap returns dynamic fee
- afterSwap handles buffer funding ONLY - updates bufferBalanceStable
- Buffer is internal accounting variable in hook contract (no vault)
- seedBuffer(poolId, amount) callable by admin for demo/testnet
- Buffer grows from ALL swaps regardless of whether positions are in range

Pillar 3 - Claim Settlement:

- minHoldSeconds = HARD ELIGIBILITY GATE:
  - if block.timestamp - depositTime < minHoldSeconds -> payout = 0
  - emits IneligibleClaim, skips all accrual/IL/payout logic
- Settlement flow:
  ```
  beforeRemoveLiquidity: eligibility check -> final _accrue() ->
         _computeIL() -> _computePayout() -> store pendingPayout
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
  IL_covered = IL_raw * maxPayoutPctOfIl / 10000
  bufferCap  = bufferBalanceStable * maxPayoutPctOfBuffer / 10000
  payout     = min(IL_covered, earnedCoverageStable, bufferCap)
  ```
- LimitingFactor enum recorded with every settlement:
  ```
  enum LimitingFactor { NONE, IL_CAP, COVERAGE_CAP, BUFFER_CAP }
  ```

Pillar 4 - LP Transparency (Coverage Report - KEY DIFFERENTIATOR):

- All accrual, buffer, and payout data available via view functions and events
- Coverage report generated from on-chain events - fully verifiable, no off-chain assumptions
- Every line in the report maps to a real on-chain event:
  ```
  PositionRegistered      -> entry snapshot
  AccrualUpdated          -> accrual periods (in-range and out-of-range)
  PositionOutOfRange      -> accrual paused
  PositionBackInRange     -> accrual resumed
  ClaimSettled            -> IL, payout, limitingFactor
  ```
- Report granularity driven by checkpoint frequency
- getEarnedCoverage() always returns correct live value (simulates to now)
- LimitingFactor tells LP exactly which cap constrained their payout

Pillar 5 - Pool Parameterization:

- All PoolConfig fields immutable after pool initialization (\_beforeInitialize commit)
- reactiveContract[poolId] set exactly once via setReactiveContract() --- \_reactiveSet guard permanently prevents any change after registration
- No admin can change parameters post-init
- Post-init privileged actions (ordered): setReactiveContract() (owner, one-time), seedBuffer() (admin)
- Hard bounds enforced at stagePoolConfig() time --- bad configs revert before pool is ever created
- dynamicFeeBps always derived (baseLpFeeBps + bufferBps), never stored

## 6. Non-Negotiable Architecture Rules

- afterSwap must never iterate all LP positions
- dynamicFeeBps must always be derived
- PoolConfig parameters are immutable after initialization
- Reactive contracts must never mutate accounting state
- accrual is always lazy
- coverage only accrues while in range
- pools must be initialized with DYNAMIC_FEE_FLAG enabled
- PoolConfig commit is atomic in \_beforeInitialize (Phase 2); reactive registration deferred to setReactiveContract (Phase 3) due to circular deployment dependency --- \_reactiveSet guard preserves trustlessness after setup

## 7. PoolConfig Struct (Final, Immutable)

```solidity
struct PoolConfig {
    // Fees
    uint24 baseLpFeeBps;             // e.g. 3000 = 0.30%
    uint24 bufferBps;                // e.g. 1000 = 0.10%
    // dynamicFeeBps = baseLpFeeBps + bufferBps (derived)

    // Coverage accrual
    uint256 coverageApr;             // 1e18 fixed-point  e.g. 0.10e18 = 10%
    uint256 secondsPerYear;          // 31_536_000 (A/365F) or 31_104_000 (A/360)

    // Eligibility
    uint32 minHoldSeconds;           // hard gate: payout = 0 if not met

    // Payout caps
    uint16 maxPayoutPctOfIl;         // e.g. 5000 = 50%
    uint16 maxPayoutPctOfBuffer;     // e.g. 1000 = 10%

    // Accrual ceiling
    uint256 maxAccruedCoverageMultiple; // e.g. 3e18 = 3x notional; 0 = disabled

    // Buffer health (informational)
    uint256 targetBufferSize;        // used in getBufferHealth() view only

    // Checkpoint rate limiting (per pool)
    uint32 minCheckpointInterval;    // e.g. 2 min demo, 1 hour mainnet

    // Admin
    address admin;                   // seedBuffer() only
}
```

## 8. State Variables (Final)

```
// Compile-time constants
uint256 BPS_DENOM               = 10_000
uint256 APR_PRECISION           = 1e18
uint24  MAX_BASE_FEE_BPS        = 10_000
uint24  MAX_BUFFER_BPS          = 5_000
uint256 MAX_COVERAGE_APR        = 0.50e18
uint16  MAX_PAYOUT_PCT          = 10_000
uint32  MAX_HOLD_SECONDS        = 365 days
uint256 SECONDS_PER_YEAR_365F   = 31_536_000
uint256 SECONDS_PER_YEAR_360    = 31_104_000

// Protocol owner --- gates stagePoolConfig() and setReactiveContract()
address immutable owner

// Pool setup
mapping(PoolId => PendingPoolSetup)                   _pendingSetup   // transient; deleted on commit
mapping(PoolId => PoolConfig)                          poolConfig      // live after Phase 2
mapping(PoolId => bool)                                _poolInitialized
mapping(PoolId => address)                             reactiveContract // live after Phase 3
mapping(PoolId => bool)                                _reactiveSet    // one-time guard

// Pool and position state
mapping(PoolId => PoolState)                           poolState
mapping(PoolId => mapping(bytes32 => PositionState))   positions

struct PoolState {
    uint256 bufferBalanceStable     // current buffer (USDC units)
    uint256 totalSkimmedStable      // cumulative buffer funded from fees
    uint256 totalPaidOutStable      // cumulative payout
}

struct PendingPoolSetup {
    PoolConfig config
    address    authorizedInitializer
    uint160    expectedSqrtPriceX96
    bool       exists
}

struct PositionState {
    // Snapshot (set once at deposit)
    uint128 entryAmt0               // token0 (ETH) at deposit
    uint128 entryAmt1               // token1 (USDC) at deposit
    int24   entryTick               // pool tick at deposit
    int24   tickLower               // position lower bound
    int24   tickUpper               // position upper bound
    uint256 entryNotionalStable     // entryAmt1 + entryAmt0 * P_entry
    uint32  depositTime             // block.timestamp at deposit

    // Accrual (mutated on every _accrue() call)
    uint32  lastAccrualTime         // timestamp of last accrual update
    uint256 earnedCoverageStable    // cumulative coverage earned (USDC)

    // Settlement
    uint256 pendingPayout           // computed payout awaiting execution

    // Existence
    bool active                     // true = registered
}
positionKey = keccak256(abi.encode(owner, tickLower, tickUpper, salt))
Outer key = PoolId -> no cross-pool collisions
```

## 9. Hook Callbacks (Final)

stagePoolConfig (Phase 1 --- external, onlyOwner, before PoolManager.initialize):

- validates all PoolConfig bounds + authorizedInitializer + expectedSqrtPriceX96
- stores PendingPoolSetup; re-stageable until pool initialized
- emits PoolConfigStaged

beforeInitialize (Phase 2 --- callback, PoolManager-only):

- validates DYNAMIC_FEE_FLAG
- requires pending setup exists (revert PoolNotStaged)
- validates sender == authorizedInitializer (revert UnauthorizedInitializer)
- validates sqrtPriceX96 == expectedSqrtPriceX96 (revert UnexpectedSqrtPrice)
- commits PoolConfig atomically; deletes pending setup; marks pool initialized
- reactiveContract NOT set here --- see Phase 3
- emits PoolConfigInitialized

setReactiveContract (Phase 3 --- external, onlyOwner, after reactive deployed):

- one-time only: \_reactiveSet guard reverts ReactiveAlreadySet on second call
- sets reactiveContract[poolId]; sets \_reactiveSet[poolId] = true
- emits ReactiveContractSet

afterAddLiquidity:

- Derive entryAmt0, entryAmt1 from liquidity delta
- Compute entryNotionalStable = entryAmt1 + entryAmt0 \* P_entry
- Register PositionState (active = true)
- Call \_accrue() - dt = 0, initializes lastAccrualTime
- Emit PositionRegistered

beforeSwap:

- Return dynamic fee = baseLpFeeBps + bufferBps
- No position state touched

afterSwap:

- Compute buffer contribution from swap fee amount
- Update bufferBalanceStable
- Emit BufferFunded
- Emit TickUpdated (for Reactive Network subscription)
- No position accrual (cannot iterate positions)

beforeRemoveLiquidity:

- Check minHoldSeconds -> if not met: emit IneligibleClaim, return
- Call \_accrue() - final accrual update
- Call \_computeIL() - spot price IL calculation
- Call \_computePayout() - apply three caps, determine LimitingFactor
- Store pendingPayout
- Emit AccrualUpdated

afterRemoveLiquidity:

- Execute pendingPayout -> transfer USDC to LP
- Update bufferBalanceStable, totalPaidOutStable
- Clear PositionState (active = false, pendingPayout = 0)
- Emit ClaimSettled / PartialPayout / NoClaim

## 10. Events (Final)

| Event                 | Description                                |
| --------------------- | ------------------------------------------ |
| PoolConfigStaged      | stagePoolConfig() --- Phase 1              |
| PoolConfigInitialized | \_beforeInitialize() on commit --- Phase 2 |
| ReactiveContractSet   | setReactiveContract() --- Phase 3          |
| PositionRegistered    | afterAddLiquidity                          |
| AccrualUpdated        | \_accrue() - every call                    |
| TickUpdated           | afterSwap - every swap (lightweight)       |
| PositionOutOfRange    | emitOutOfRange() via Reactive              |
| PositionBackInRange   | emitBackInRange() via Reactive             |
| BufferFunded          | afterSwap                                  |
| BufferSeeded          | seedBuffer()                               |
| ClaimSettled          | afterRemoveLiquidity (successful payout)   |
| NoClaim               | IL = 0 on withdrawal                       |
| IneligibleClaim       | minHoldSeconds not met                     |
| PartialPayout         | buffer insufficient for full payout        |

## 11. Checkpoint & Reactive Network

checkpoint(PoolId, bytes32 positionKey):

- Permissionless, one position per call
- Required dt >= minCheckpointInterval (from PoolConfig, per pool)
- Call \_accrue(poolId, positionKey, currentTick)
- Emit AccrualUpdated (and optionally Checkpointed)

Reactive Contract responsibilities:

Job 1 - Range transition detection (event-driven):

- Subscribe to TickUpdated events from hook
- Track lastKnownRangeStatus per position (in Reactive state)
- On tick crossing:
  ```
  if wasInRange && !isInRange:
      call checkpoint() -> hook calls emitOutOfRange()
  if !wasInRange && isInRange:
      call checkpoint() -> hook calls emitBackInRange()
  ```

Job 2 - Periodic heartbeat (time-driven):

- Call checkpoint() every checkpointInterval for each active in-range position
- Generates intermediate AccrualUpdated events for coverage report

Hook functions callable by Reactive Contract only:

emitOutOfRange(PoolId, bytes32 positionKey, int24 currentTick)
emitBackInRange(PoolId, bytes32 positionKey, int24 currentTick)
(access controlled: only reactiveContract[poolId] address may call)

`reactiveContract[poolId]` set via setReactiveContract() (Phase 3), after reactive contract is deployed with hook address. \_reactiveSet guard ensures one-time registration.

## 12. View Functions (Final)

Pool level:

```
getPoolConfig(PoolId)           -> full PoolConfig struct
getBufferHealth(PoolId)         -> balance, skimmed, paidOut, targetSize
getCurrentFee(PoolId)           -> baseLpFeeBps + bufferBps
getDayCountBasis(PoolId)        -> "A/365F" or "A/360"
getCoverageAPR(PoolId)          -> coverageApr
```

Position level:

```
getPositionSnapshot(PoolId, positionKey)   -> entry state
getAccrualState(PoolId, positionKey)       -> lastAccrualTime, earnedCoverageStable, isInRange
getEarnedCoverage(PoolId, positionKey)     -> simulated accrual to now (always live, no checkpoint needed)
getEstimatedPayout(PoolId, positionKey)    -> IL_raw, cappedPayout, limitingFactor
getCoverageProgress(PoolId, positionKey)   -> earned, maxPossible, pctEarned
```

## 13. LimitingFactor Enum

```solidity
enum LimitingFactor {
    NONE,          // IL = 0, no claim needed
    IL_CAP,        // maxPayoutPctOfIl was binding constraint
    COVERAGE_CAP,  // earnedCoverageStable was binding constraint
    BUFFER_CAP     // maxPayoutPctOfBuffer was binding constraint
}
```

## 14. Entry Notional - Clarification

entryNotionalStable = entryAmt1 + (entryAmt0 \* P_entry)

- P_entry derived from current tick at deposit (decimal adjusted)
- Handles all three deposit cases:
  - Case A: currentTick < tickLower -> 100% token0, entryAmt1 = 0
  - Case B: tickLower <= tick < tickUpper -> mixed amounts (demo case)
  - Case C: currentTick >= tickUpper -> 100% token1, entryAmt0 = 0
- Cases A and C start out of range -> \_accrue() gates correctly
- Demo uses Case B: price in range at deposit, accrual starts immediately

## 15. Demo Configuration

Testnet deployment parameters:

| Params                     | Values                              |
| -------------------------- | ----------------------------------- |
| baseLpFeeBps               | 3,000 (0.30%)                       |
| bufferBps                  | 1,000 (0.10%)                       |
| coverageApr                | 0.50e18 (50% APR - visible accrual) |
| secondsPerYear             | 31,536,000                          |
| minHoldSeconds             | 5 minutes                           |
| minCheckpointInterval      | 2 minutes                           |
| maxPayoutPctOfIl           | 5,000 (50%)                         |
| maxPayoutPctOfBuffer       | 1,000 (10%)                         |
| maxAccruedCoverageMultiple | 3e18 (3x notional cap)              |
| targetBufferSize           | 100,000 USDC                        |
| Initial buffer seed        | 10,000 USDC                         |

Demo script approach:

- Use vm.warp in Foundry script to simulate 45-day lifecycle
- Pre-seed rich AccrualUpdated + range transition event history on testnet before demo
- Live demo shows: one real withdrawal + ClaimSettled firing live
- Reactive Network: checkpointInterval = 2 minutes on testnet

Demo Pool setup:

- Pool initialized at ~$2,000/ETH (sqrtPriceX96 set at PoolManager.initialize())
- LP deposits mix of ETH + USDC (Case B - price in range)
- Entry notional: ~10,000 USDC
- Range: [1,800, 2,200]

## 16. Recorded Demo Structure (5 Minutes)

| Time      | Description                                              | Tool                            |
| --------- | -------------------------------------------------------- | ------------------------------- |
| 0:00-0:40 | The Problem                                              | Slides                          |
| 0:40-1:20 | The Solution - 5 pillars visual                          | Slides                          |
| 1:20-2:00 | Code Walkthrough - PoolConfig, \_accrue, \_computePayout | IDE                             |
| 2:00-4:15 | Demo script runs                                         | Terminal - Foundry with vm.warp |
| 4:15-4:45 | Coverage Report                                          | Frontend dashboard              |
| 4:45-5:00 | Closing - tagline + links                                | Slide                           |

## 17. Build Order

| Step | Action               | Description                                                                           |
| ---- | -------------------- | ------------------------------------------------------------------------------------- |
| 1    | \_accrue()           | accrual engine                                                                        |
| 2    | \_computeIL()        | IL math                                                                               |
| 3    | \_computePayout()    | three-cap logic + limitingFactor                                                      |
| 4    | Hook setup functions | stagePoolConfig, \_beforeInitialize commit, setReactiveContract                       |
| 5    | Hook callbacks       | afterAddLiquidity, beforeSwap, afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity |
| 6    | checkpoint()         | permissionless + reactive entry point                                                 |
| 7    | Reactive Contract    | range detection + heartbeat                                                           |
| 8    | Frontend dashboard   | coverage report from events                                                           |
| 9    | Demo script          | RangeGuardDemo.s.sol with vm.warp                                                     |

## 18. References

- Uniswap v4 Core Docs
- Uniswap v4 Periphery Docs
- Uniswap v4 Hook Docs
- Foundry Docs
- Reactive Network Docs
