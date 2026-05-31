# **RangeGuard ---- Technical Specification (MVP)**

# Version 2.1

## 1. Overview

**Purpose**

RangeGuard is a Uniswap v4 hook that provides native, on-chain insurance against impermanent loss (IL) for liquidity providers (LPs). Coverage accrues over time using a day-count convention, is funded by a portions of trading fees via v4 dynamic fees, and is paid out automatically on full withdrawal, subject to three caps.

**Tagline:** "Protect your liquidity. Guard your range."

**MVP Target:** Testnet deployment with a single ETH/USDC pool demo

## 2. Pool & Token Model

- token1 = stable (USDC) --- numeraire for all accounting
- token0 = volatile (ETH)
- MVP demo pool: ETH/USDC
- One hook instance supports multiple pools
- Pool price is set at poolManager.initialize() --- completely separate from the first LP deposit
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
- Only these two values accepted at stagePoolConfig() --- all others revert
- Accrual model is LAZY --- coverage only computed on explicit touches
  - afterAddLiquidity: dt = 0, initializes lastAccrualTime baseline
  - checkpoint() primary accrual driver between deposit and withdrawal
  - beforeRemoveLiquidity: final accrual update before settlement
- afterSwap does NOT trigger accrual --- it is impossible to iterate all LP positions on-chain (unbounded set, O(N) gas per swap)
- getEarnedCoverage() view function always simulates accrual to block.timestamp --- returns correct live value without requiring a checkpoint first
- Report granularity is driven by checkpoint frequency

### Pillar 2: Buffer Funding

- Dynamic fee mechanism: Total fee = BASE_LP_FEES_BPS + BUFFER_BPS (always derived, never stored separately)
- beforeSwap returns the dynamic fee
- afterSwap handles buffer funding ONLY --- updates bufferBalanceStable, emits BufferFunded
- afterSwap also emits TickUpdated (lightweight event for Reactive Network subscription)
- Buffer is an internal accounting variable in the hook contract (no separate vault in MVP)
- seedBuffer(poolId, amount) callable by admin for demo/testnet seeding
- Buffer grows from ALL swaps regardless of whether any position is in range

### Pillar 3: Claim Settlement

- minHoldSeconds is a HARD ELIGIBILITY GATE
  - If block.timestamp - depositTime < minHoldSeconds -> payout = 0
  - Emits IneligibleClaim with reason "MIN_HOLD_NOT_MET"
  - Skips all accrual, IL, computation, and payout logic entirely
- Settlement is triggered on full withdrawal only (no partial withdrawals in MVP)
- Settlement flow:
  - beforeRemoveLiquidity: eligibility check -> final \_accrue() -> computeIL() -> computePayout() -> storePendingPayout
  - afterRemoveLiquidity: execute payout -> update buffer -> cleanup position state -> emit events
- IL formula (stable numeraire):
  - P_exit = spot price from current tick (decimal adjusted, USDC per ETH)
  - V_HODL = entryAmt1 + entryAmt0 \* P_exit
  - V_actual = outAmt1 + outAmt0 \* P_exit (fees included)
  - IL_raw = max(0, V_HODL - V_actual)
- Three payout caps applied in order:
  - IL_covered = IL_raw \* maxPayoutPctOfIl / 10000
  - bufferCap = bufferBalanceStable \* maxPayoutPctOfBuffer / 10000
  - payout = min(IL_covered, earnedCoverageStable, bufferCap)
- LimitingFactor enum recorded with every settlement (see Section 9)

### Pillar 4: LP Transparency (Coverage Report --- Key Differentiator)

The coverage report is RangeGuard's primary differentiating feature. It provides LPs with a complete, verifiable, day-by-day history of their positions -- generated entirely from on-chain events. No off-chain assumptions are required.

Every line in the coverage report maps to a real on-chain event:

- PositionRegistered -> entry snapshot (entry date, notional, range, APR)
- AccrualUpdated -> accrual periods with isInRange flag and delta earned
- PositionOutOfRange -> accrual paused, coverage snapshot at pause
- PositionBackInRange -> accrual resumed, coverage snapshot at resume
- ClaimSettled -> IL_raw, payout, limitingFactor

### Pillar 5: Pool Parameterization

- PoolConfig fields are immutable after pool initialization --- hard bounds enforced at stagePoolConfig() time
- reactiveContract[poolId] is set exactly once via setReactiveContract() after pool initialization --- \_reactiveSet guard permanently prevents any subsequent change
- Pool bring-up uses a three-phase setup sequence (see Section 4):
  - Phase 1 --- stagePoolConfig(): owner stages config before pool exists in PoolManager
  - Phase 2 --- \_beforeInitialize(): commits staged config atomically when pool is initialized
  - Phase 3 --- setReactiveContract(): owner registers reactive contract address after its deployment
- Hard bounds enforced at stagePoolConfig() time --- bad configs revert before pool is ever created
- dynamicFeeBps is always derived (baseLpFeeBps + bufferBps) --- never stored separately, preventing drift
- Post-init privileged actions (two, ordered):
  1. setReactiveContract() --- onlyOwner, one-time only, called after reactive contract is deployed
  2. seedBuffer() --- config.admin only, funds the IL coverage buffer
- Production deployments use CREATE2 for atomic hook + reactive deployment (no three-phase gap). MVP uses sequential deployment for simplicity; \_reactiveSet guard preserves trustlessness after setup.

## 4. PoolConfig Struct (Immutable)

```solidity
/// @notice Immutable configuration for a single pool, set once at initialization.
/// @dev All BPS values are 10,000 denominator; APR uses 1e18 fixed-point
struct PoolConfig {

    // Fees
    uint24 baseLpFeeBps;         // LP fee portion      e.g. 3000 = 0.30%
    uint24 bufferBps;            // Buffer fee portion  e.g. 1000 = 0.10%
    // dynamicFeeBps = baseLpFeeBps + bufferBps (always derived, never stored)

    // Coverage accrual
    uint256 coverageApr;         // 1e18 fixed-point    e.g. 0.10e18 = 10%
    uint256 secondsPerYear;      // A/365F = 31_536_000 | A/360 = 31_104_000

    // Eligibility
    uint32 minHoldSeconds;       // Hard gate: payout = 0 if not met

    // Payout caps
    uint16 maxPayoutPctOfIl;     // Cap 1: % of IL covered   e.g. 5000 = 50%
    uint16 maxPayoutPctOfBuffer; // Cap 3: % of buffer       e.g. 1000 = 10%

    // Accrual ceiling
    uint256 maxAccruedCoverageMultiple; // e.g. 3e18 = 3x entryNotional; 0 = disabled

    // Buffer health (informational)
    uint256 targetBufferSize;    // Actuarial target, used in getBufferHealth()

    // Checkpoint rate limiting (per pool)
    uint32 minCheckpointInterval; // e.g. 2 minute demo / 1 hour mainnet

    // Admin
    address admin;               // seedBuffer() only; no param changes
}
```

### Compile-Time Constants (Hard Bounds)

```solidity
uint256 constant BPS_DENOM               = 10_000;
uint256 constant APR_PRECISION           = 1e18;
uint24  constant MAX_BASE_FEE_BPS        = 10_000;
uint24  constant MAX_BUFFER_BPS          = 5_000;
uint256 constant MAX_COVERAGE_APR        = 0.50e18;
uint16  constant MAX_PAYOUT_PCT          = 10_000;
uint32  constant MAX_HOLD_SECONDS        = 365 days;
uint256 constant SECONDS_PER_YEAR_365F   = 31_536_000;
uint256 constant SECONDS_PER_YEAR_360    = 31_104_000;
// Fee pip denominator — distinct from BPS_DENOM
// v4 expresses fees in pips (1e6), NOT basis points (1e4).
// baseLpFeeBps and bufferBps field names are a misnomer —
// they hold pip values. e.g. 3000 = 0.30%, 1000 = 0.10%.
// Buffer contribution: stableVolume * bufferBps / FEE_DENOM
// Payout caps (maxPayoutPctOfIl, maxPayoutPctOfBuffer) use
// BPS_DENOM (1e4). Never use BPS_DENOM for fee math.
uint256 constant FEE_DENOM               = 1_000_000;
```

### Initialization Functions (Three-Phase Setup)

**Why three phases:** v4's `beforeInitialize` callback receives no `hookData` --- per-pool config cannot be passed through it. Additionally, the reactive contract requires the hook address at deployment, creating a circular dependency resolved by deferring reactive registration to Phase 3.

#### Phase 1 --- stagePoolConfig (external, onlyOwner)

```solidity
/// @notice Stage pool configuration before PoolManager.initialize() is called.
/// @dev onlyOwner. Re-stageable until pool is initialized. No reactive address at this stage.
function stagePoolConfig(
    PoolKey    calldata key,
    PoolConfig calldata config,
    address             authorizedInitializer,
    uint160             expectedSqrtPriceX96
) external onlyOwner;
```

Validations (all revert with custom errors before any storage write):

- `PoolAlreadyInitialized` if `_poolInitialized[poolId]` is true
- `ZeroAdmin` if `config.admin == address(0)`
- `ZeroInitializer` if `authorizedInitializer == address(0)`
- `ZeroSqrtPrice` if `expectedSqrtPriceX96 == 0`
- `NotDynamicFee` if `key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG` (0x800000)
- `InvalidFeeConfig` if `config.baseLpFeeBps > MAX_BASE_FEE_BPS`
- `InvalidFeeConfig` if `config.bufferBps > MAX_BUFFER_BPS`
- `InvalidApr` if `config.coverageApr == 0 || config.coverageApr > MAX_COVERAGE_APR`
- `InvalidPayoutCaps` if `config.maxPayoutPctOfIl > MAX_PAYOUT_PCT`
- `InvalidPayoutCaps` if `config.maxPayoutPctOfBuffer > BPS_DENOM` ← protects buffer-payout invariant
- `UnsupportedDayCount` if `config.secondsPerYear` is neither `SECONDS_PER_YEAR_365F` nor `SECONDS_PER_YEAR_360`

On success: stores `_pendingSetup[poolId]`, emits `PoolConfigStaged`.
Re-stageable: owner may overwrite `_pendingSetup[poolId]` at any time until pool is initialized.

#### Phase 2 --- \_beforeInitialize callback (PoolManager-only)

```solidity
/// @dev Called by PoolManager during initialize(). Validates sender and price, commits staged config.
function _beforeInitialize(
    address sender,
    PoolKey calldata key,
    uint160 sqrtPriceX96
) internal override returns (bytes4);
```

Checks (all revert --- pool never created if any fail):

- `NotDynamicFee` if `key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG` (authoritative check)
- `PoolNotStaged` if `!_pendingSetup[poolId].exists`
- `UnauthorizedInitializer` if `sender != _pendingSetup[poolId].authorizedInitializer`
- `UnexpectedSqrtPrice` if `sqrtPriceX96 != _pendingSetup[poolId].expectedSqrtPriceX96`

On success: `poolConfig[poolId] = _pendingSetup[poolId].config`,
`delete _pendingSetup[poolId]`, `_poolInitialized[poolId] = true`,
emits `PoolConfigInitialized(poolId, config)`.

Note: `reactiveContract[poolId]` is NOT set here --- it remains `address(0)` until Phase 3.

#### Phase 3 --- setReactiveContract (external, onlyOwner, one-time)

```solidity
/// @notice Register the reactive contract address after it has been deployed.
/// @dev onlyOwner. Callable exactly once per pool. _reactiveSet guard permanently locks after call.
function setReactiveContract(PoolKey calldata key, address reactive) external onlyOwner;
```

Checks:

- `PoolNotInitialized` if `!_poolInitialized[poolId]`
- `ReactiveAlreadySet` if `_reactiveSet[poolId]` is true
- `ZeroReactive` if `reactive == address(0)`

On success: `reactiveContract[poolId] = reactive`, `_reactiveSet[poolId] = true`,
emits `ReactiveContractSet(poolId, reactive)`.

#### PendingPoolSetup Struct

```solidity
/// @notice Transient staging struct, deleted on commit in _beforeInitialize.
struct PendingPoolSetup {
    PoolConfig config;
    address    authorizedInitializer;
    uint160    expectedSqrtPriceX96;
    bool       exists;
}
```

#### Custom Errors (pool setup)

```solidity
error PoolAlreadyInitialized();
error PoolNotInitialized();
error PoolNotStaged();
error NotOwner();
error ZeroAdmin();
error ZeroReactive();
error ZeroInitializer();
error ZeroSqrtPrice();
error NotDynamicFee();
error UnauthorizedInitializer();
error UnexpectedSqrtPrice();
error ReactiveAlreadySet();
error InvalidFeeConfig();
error InvalidApr();
error InvalidPayoutCaps();
error UnsupportedDayCount();
```

## 5. State Variables

### Hook-Level Mappings

```solidity
// Protocol owner --- gates stagePoolConfig() and setReactiveContract()
address public immutable owner;

// Pool setup
mapping(PoolId => PendingPoolSetup) private _pendingSetup;      // transient; deleted on commit
mapping(PoolId => PoolConfig)       public  poolConfig;          // live after _beforeInitialize
mapping(PoolId => bool)             private _poolInitialized;
mapping(PoolId => address)          public  reactiveContract;    // live after setReactiveContract
mapping(PoolId => bool)             private _reactiveSet;        // one-time guard

// Pool and position state
mapping(PoolId => PoolState)        public poolState;
mapping(PoolId => mapping(bytes32 => PositionState)) public positions;
```

### PositionState Struct

```solidity
struct PositionState {
    // Snapshot - set once at deposit, never mutated
    uint128 entryAmt0;              // token0 (ETH) amount at deposit
    uint128 entryAmt1;              // token1 (USDC) amount at deposit
    int24   entryTick;              // Pool tick at deposit
    int24   tickLower;              // Position lower tick bound
    int24   tickUpper;              // Position upper tick bound
    uint256 entryNotionalStable;    // entryAmt1 + entryAmt0 * P_entry (USDC)
    uint32  depositTime;            // block.timestamp at deposit

    // Accrual -- mutated on every _accrue() call
    uint32  lastAccrualTime;        // Timestamp of last accrual update
    uint256 earnedCoverageStable;   // Cumulative coverage earned (USDC)

    // Settlement -- set in beforeRemoveLiquidity, cleared in afterRemoveLiquidity
    uint256 pendingPayout;          // Computed payout awaiting execution

    // Existence flag
    bool active;                    // true = registered, false = cleared
}
```

### PositionKey Derivation

```solidity
/// @notice Derives a unique position key scoped to a pool.
function _positionKey(
    address owner,
    int24   tickLower,
    int24   tickUpper,
    bytes32 salt
) internal pure returns (bytes32) {
    return keccak256(abi.encode(owner, tickLower, tickUpper, salt));
}
```

The outer PoolId key in `positions[poolId][positionKey]` ensures no cross-pool collisions even if two pools share an identical owner, tick range, and salt.

### Entry Notional Formula

```
entryNotionalStable = entryAmt1 + (entryAmt0 * P_entry)
where P_entry = spot price at deposit (USDC per ETH), decimal adjusted from current tick
```

This handles all three deposit cases naturally:

- Case A (price below range): entryAmt1 = 0, notional = entryAmt0 \* P_entry
- Case B (price in range): mixed amounts, standard formula
- Case C (price above range): entryAmt0 = 0, notional = entryAmt1

## 6. Hook Callbacks & Responsibilities

| Callback                                 | Responsibility                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| stagePoolConfig (Phase 1, onlyOwner)     | Validate all PoolConfig bounds, authorizedInitializer, expectedSqrtPriceX96. Store PendingPoolSetup. Emit PoolConfigStaged. Re-stageable until pool initialized.                                                                                                                                                                                                                            |
| setReactiveContract (Phase 3, onlyOwner) | Require pool initialized. \_reactiveSet guard: reverts ReactiveAlreadySet on second call. Rejects address(0). Sets reactiveContract[poolId], \_reactiveSet[poolId] = true. Emits ReactiveContractSet.                                                                                                                                                                                       |
| beforeInitialize                         | Validate key.fee == DYNAMIC_FEE_FLAG. Require pending setup exists (PoolNotStaged). Validate sender == authorizedInitializer (UnauthorizedInitializer). Validate sqrtPriceX96 == expectedSqrtPriceX96 (UnexpectedSqrtPrice). Commit poolConfig from pending setup. Delete \_pendingSetup. Set \_poolInitialized = true. Emit PoolConfigInitialized. Note: reactiveContract is NOT set here. |
| afterAddLiquidity                        | Derive entryAmt0, entryAmt1 from liquidity delta. Compute entryNotionalStable. Register PositionState (active=true). Call \_accrue() --- dt=0, initializes lastAccrualTime. Emit PositionRegistered.                                                                                                                                                                                        |
| beforeSwap                               | Return dynamic fee = baseLpFeeBps + bufferBps. No position state touched.                                                                                                                                                                                                                                                                                                                   |
| afterSwap                                | Compute buffer contribution from swap fee. Update bufferBalanceStable. Emit BufferFunded. Emit TickUpdated (for Reactive Network). NO position accrual --- cannot iterate positions.                                                                                                                                                                                                        |
| beforeRemoveLiquidity                    | Check minHoldSeconds -> if not met: emit IneligibleClaim, return. Call \_accrue() final update. Call \_computeIL(). Call \_computePayout(). Store pendingPayout. Emit AccrualUpdated.                                                                                                                                                                                                       |
| afterRemoveLiquidity                     | Execute pendingPayout transfer to LP. Update bufferBalanceStable and totalPaidOutStable. Clear PositionState (active=false, pendingPayout=0). Emit ClaimSettled / PartialPayout / NoClaim.                                                                                                                                                                                                  |

## 7. Core Internal Functions

\_accrue()

```solidity
function _accrue(
    PoolId  poolId,
    bytes32 positionKey,
    int24   currentTick
) internal {
    PositionState storage pos = positions[poolId][positionKey];
    PoolConfig    storage cfg = poolConfig[poolId];

    if (!pos.active) return;

    uint256 dt       = block.timestamp - pos.lastAccrualTime;
    bool isInRange   = pos.tickLower <= currentTick && currentTick < pos.tickUpper;
    uint256 delta    = 0;

    if (isInRange && dt > 0) {
        uint256 yearFraction = (dt * APR_PRECISION) / cfg.secondsPerYear;
        delta = (pos.entryNotionalStable * cfg.coverageApr * yearFraction)
                / (APR_PRECISION * APR_PRECISION);

        if (cfg.maxAccruedCoverageMultiple > 0) {
            uint256 cap      = pos.entryNotionalStable * cfg.maxAccruedCoverageMultiple / APR_PRECISION;
            uint256 newTotal = pos.earnedCoverageStable + delta;
            pos.earnedCoverageStable = newTotal > cap ? cap : newTotal;
        } else {
            pos.earnedCoverageStable += delta;
        }
    }

    pos.lastAccrualTime = uint32(block.timestamp);

    emit AccrualUpdated(
        poolId, positionKey, dt, delta,
        pos.earnedCoverageStable, isInRange, block.timestamp
    );
}
```

\_computeIL()

```solidity
function _computeIL(
    PositionState memory pos,
    uint128 outAmt0,
    uint128 outAmt1,
    int24   exitTick
) internal view returns (uint256 IL_raw) {
    uint256 P_exit   = _priceFromTick(exitTick); // USDC per ETH, decimal adjusted
    uint256 V_HODL   = pos.entryAmt1 + (uint256(pos.entryAmt0) * P_exit / PRICE_PRECISION);
    uint256 V_actual = uint256(outAmt1)          + (uint256(outAmt0)        * P_exit / PRICE_PRECISION);
    IL_raw = V_HODL > V_actual ? V_HODL - V_actual : 0;
}
```

\_computePayout()

```solidity
function _computePayout(
    PoolId        poolId,
    PositionState memory pos,
    uint256       IL_raw
) internal view returns (uint256 payout, LimitingFactor factor) {
    if (IL_raw == 0) return (0, LimitingFactor.NONE);

    PoolConfig storage cfg   = poolConfig[poolId];
    PoolState  storage state = poolState[poolId];

    uint256 IL_covered = IL_raw       * cfg.maxPayoutPctOfIl     / BPS_DENOM;
    uint256 bufferCap  = state.bufferBalanceStable * cfg.maxPayoutPctOfBuffer / BPS_DENOM;
    uint256 earned     = pos.earnedCoverageStable;

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

```solidity
/// @notice Permissionless accrual update for a single position.
/// @dev Primary entry point for Reactive Network automation.
function checkpoint(
    PoolId  poolId,
    bytes32 positionKey
) external {
    PositionState storage pos = positions[poolId][positionKey];
    PoolConfig    storage cfg = poolConfig[poolId];

    require(pos.active, "position not active");
    require(
        block.timestamp - pos.lastAccrualTime >= cfg.minCheckpointInterval,
        "TOO_SOON"
    );

    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);

    emit Checkpointed(poolId, positionKey, block.timestamp);
}
```

### Reactive Contract --- Two Jobs

**Job 1: Range Transition Detection (event-driven)**

- Subscribes to TickUpdated events emitted by the hook in afterSwap
- Tracks lastKnownRangeStatus per position in Reactive Contract state
- On tick crossing:
  - If wasInRange && !isInRange: call checkpoint() -> hook calls emitOutOfRange()
  - If !wasInRange && isInRange: call checkpoint() -> hook calls emitBackInRange()

**Job 2: Periodic Heartbeat (time-driven)**

- Calls checkpoint() every checkpointInterval for each active in-range position
- Generates intermediate AccrualUpdated events for the coverage report
- Mainnet: every 24 hours | Demo/testnet: every 2 minutes

### Hook Functions Callable by Reactive Contract Only

```solidity
/// @dev Access controlled: only reactiveContract[poolId] may call
function emitOutOfRange(
    PoolId  poolId,
    bytes32 positionKey,
    int24   currentTick
) external onlyReactive(poolId) {
    PositionState storage pos = positions[poolId][positionKey];
    emit PositionOutOfRange(
        poolId, positionKey, pos.tickLower, pos.tickUpper,
        currentTick, pos.earnedCoverageStable, block.timestamp
    );
}

function emitBackInRange(
    PoolId  poolId,
    bytes32 positionKey,
    int24   currentTick
) external onlyReactive(poolId) {
    PositionState storage pos = positions[poolId][positionKey];
    emit PositionBackInRange(
        poolId, positionKey, pos.tickLower, pos.tickUpper,
        currentTick, pos.earnedCoverageStable, block.timestamp
    );
}
```

`reactiveContract[poolId]` is set per pool via `setReactiveContract()` (Phase 3 of pool setup),
after the reactive contract has been deployed with the hook address. The `_reactiveSet[poolId]`
guard ensures this can never be changed after initial registration. All `onlyReactive(poolId)`
access control depends on this mapping being set before any reactive callbacks fire.

## 9. LimitingFactor Enum

```solidity
enum LimitingFactor {
    NONE,         // IL = 0, no claim needed
    IL_CAP,       // maxPayoutPctOfIl was the binding constraint
    COVERAGE_CAP, // earnedCoverageStable was the binding constraint
    BUFFER_CAP    // maxPayoutPctOfBuffer was the binding constraint
}
```

LimitingFactor is included in:

- ClaimSettled event
- getEstimatedPayout() view function
- Coverage report (frontend dashboard)

## 10. Event Inventory

| Event                 | When Emitted                               | Key Data                                                                          |
| --------------------- | ------------------------------------------ | --------------------------------------------------------------------------------- |
| PoolConfigStaged      | stagePoolConfig() --- Phase 1              | poolId, config, authorizedInitializer, expectedSqrtPriceX96                       |
| PoolConfigInitialized | \_beforeInitialize() on commit --- Phase 2 | poolId, config (reactive not included)                                            |
| ReactiveContractSet   | setReactiveContract() --- Phase 3          | poolId, reactive address                                                          |
| PositionRegistered    | afterAddLiquidity                          | owner, range, entryNotional, depositTime, coverageApr, dayCountBasis              |
| AccrualUpdated        | \_accrue() --- every call                  | positionKey, dt, delta, newEarnedTotal, isInRange, timestamp                      |
| TickUpdated           | afterSwap --- every swap                   | poolId, newTick, timestamp (lightweight, for Reactive)                            |
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
| getCoverageProgress(PoolId, positionKey) | earned, maxPossible, pctEarned                                                          |

## 12. Safety & Governance

- All PoolConfig fields are immutable after \_beforeInitialize() commits the staged config
- reactiveContract[poolId] is set exactly once by setReactiveContract(); \_reactiveSet guard permanently prevents any change after initial registration
- \_poolInitialized guard prevents pool re-initialization
- \_reactiveSet guard prevents reactive contract from being changed after initial registration
- \_pendingSetup staging pattern prevents pool initialization with wrong price or unauthorized caller
- Hard bounds enforced at stagePoolConfig() time for all parameters
- Single admin per pool for MVP (multisig or DAO recommended for mainnet)
- Admin can only call seedBuffer() --- no parameter changes possible
- dynamicFeeBps always derived --- never stored, preventing fee drift
- secondsPerYear validated to only accept A/365F or A/360
- Reentrancy: position state cleared before payout transfer in afterRemoveLiquidity
- Post-init privileged actions: setReactiveContract() (owner, one-time), then seedBuffer() (admin)

## 13. MVP Scope

**Deployment note:** MVP uses a three-phase sequential pool setup (stagePoolConfig -> PoolManager.initialize -> setReactiveContract) to resolve the circular deployment dependency between the hook and reactive contract. Production deployments use CREATE2 for atomic, same-transaction deployment of both contracts, eliminating the intermediate window where the pool is initialized but the reactive contract is not yet registered.

In scope:

- Single-range LPs only
- Full withdrawal only (no partials)
- Spot price for IL calculation (tick-based)
- Fixed dynamic fee per pool
- Seeded buffer for demo
- Internal buffer accounting (no vault contract)
- Multi-pool support (one hook, multiple pools)
- Reactive Network integration for range notifications and checkpoints

Out of scope (Phase 2):

- TWAP / Oracle price for IL calculation
- Partial withdrawals
- Volatility-responsive dynamic fee
- LP premium mechanism
- Separate vault contract
- Mainnet hardening

## 14. Demo Configuration

### Testnet Deployment Parameters

| Parameter                   | Demo Value    | Mainnet Value |
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
- LP deposits mix of ETH + USDC (Case B --- price in range at deposit)
- Entry notional: ~10,000 USDC
- Range: [$1,800, $2,200]

### Demo Script Narrative Arc (vm.warp in Foundry)

[Setup] Deploy hook, stage ETH/USDC pool config (stagePoolConfig), initialize pool, deploy reactive contract, register reactive (setReactiveContract)
[Setup] Admin seeds buffer: 10,000 USDC -> BufferSeeded
Buffer health: 10,000 / 10,000 USDC (100.0%)

[Day 0] LP Deposits mix of ETH + USDC
Entry notional: 10,000 USDC | Range: [1800, 2200] | PositionRegistered

[Day 3] Swap: 10 ETH -> USDC (in range) -> BufferFunded +4.20 USDC
[Day 7] Swap: 50,000 USDC -> ETH (in range) -> BufferFunded +21.00 USDC
[Day 12] Swap: 25 ETH -> USDC (in range) -> BufferFunded +10.50 USDC
[Day 15] Checkpoint -> AccrualUpdated: +41.10 USDC earned

[Day 15] Large swap: 200 ETH -> USDC -> tick crosses tickLower
PositionOutOfRange emitted | Accrual paused at 41.10 USDC
BufferFunded +84.00 USDC (buffer grows regardless of range)

[Day 18] Swap out of range -> BufferFunded +12.60 USDC
[Day 20] Checkpoint -> AccrualUpdated: +0.00 USDC (isInRange: false)

[Day 22] Large swap: 150,000 USDC -> ETH -> tick crosses tickLower back up
PositionBackInRange emitted | Accrual resumed from 41.10 USDC
BufferFunded +63.00 USDC

[Day 30] Swap in range -> BufferFunded +8.40 USDC
[Day 38] Swap in range -> BufferFunded +16.80 USDC
[Day 45] Checkpoint -> AccrualUpdated: +63.01 USDC | Total: 104.11 USDC

[Day 45] LP withdraws full position
IL raw: 87.50 USDC
IL cap (50%): 43.75 USDC <- binding constraint
Earned coverage: 104.11 USDC
Buffer cap: 1,022.05 USDC
Payout: 43.75 USDC
Limiting Factor: IL_CAP | ClaimSettled

[Final] Initial Seed: 10,000.00 USDC
Fees skimmed: 220.50 USDC
Paid out: 43.75 USDC
Buffer balance: 10,176.75 USDC (101.8% health --- self-sustaining)

## 15. Recorded Demo Structure (5 minutes)

| Segment          | Duration  | Content                                      | Tool     |
| ---------------- | --------- | -------------------------------------------- | -------- |
| The Problem      | 0:00-0:40 | IL explained, HODL vs LP value loss          | Slides   |
| The Solution     | 0:40-1:20 | Five Pillar visual, self-funding buffer      | Slides   |
| Code Walkthrough | 1:20-2:00 | PoolConfig, \_accrue(), \_computePayout()    | IDE      |
| Demo Script      | 2:00-4:15 | Full lifecycle with swaps, range transitions | Terminal |
| Coverage Report  | 4:15-4:45 | Frontend dashboard, day-by-day statement     | Browser  |
| Closing          | 4:45-5:00 | Tagline, GitHub link, testnet link           | Slide    |

## 16. Build Order

1. \_accrue() --- accrual engine (lazy, in-range gated, A/365F)
2. \_computeIL() --- spot price IL calculation with decimal adjustment
3. \_computePayout() --- three-cap logic + LimitingFactor determination
4. Hook callbacks --- stagePoolConfig, \_beforeInitialize, setReactiveContract, afterAddLiquidity, beforeSwap, afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity
5. checkpoint() --- permissionless + Reactive Network entry point
6. Reactive Contract --- range transition detection + periodic heartbeat
7. Frontend dashboard --- coverage report rendered from on-chain events
8. Demo script --- RangeGuardDemo.s.sol with vm.warp

## 17. References

- [Uniswap v4 Core Docs]
- [Uniswap v4 Periphery Docs]
- [Uniswap v4 Hooks Docs]
- [Foundry Docs]
- [Reactive Network Docs]
