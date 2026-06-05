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
  - afterRemoveLiquidity: final accrual update before settlement
    computation (v4-native: withdrawn amounts and final accrual both
    resolved inside afterRemoveLiquidity)
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
- Settlement flow (v4-native — withdrawn amounts exist only AFTER removal):
  - beforeRemoveLiquidity: validation only — enforce active position, enforce MVP
    full-withdrawal only (revert on partial). No IL or payout computation — withdrawn
    amounts not known yet.
  - afterRemoveLiquidity: extract actual withdrawn amounts from BalanceDelta,
    minHoldSeconds eligibility check, if ineligible emit IneligibleClaim and cleanup
    state, final \_accrue(), \_computeIL() using outAmt0/outAmt1, \_computePayout() using
    three-cap logic, execute payout transfer, update buffer accounting, cleanup
    PositionState, emit settlement events.
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
- Pool bring-up uses a three-phase setup sequence (see Section 4):
  - Phase 1 --- stagePoolConfig(): owner stages config before pool exists in PoolManager
  - Phase 2 --- \_beforeInitialize(): commits staged config atomically when pool is initialized

- Hard bounds enforced at stagePoolConfig() time --- bad configs revert before pool is ever created
- dynamicFeeBps is always derived (baseLpFeeBps + bufferBps) --- never stored separately, preventing drift
- Post-init privileged actions :
  1. seedBuffer() --- config.admin only, funds the IL coverage buffer

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

### Initialization Functions (2 Phase Setup)

**Why two phases:** v4's `beforeInitialize` callback receives no `hookData` --- per-pool config cannot be passed through it.

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
error ZeroInitializer();
error ZeroSqrtPrice();
error NotDynamicFee();
error UnauthorizedInitializer();
error UnexpectedSqrtPrice();
error InvalidFeeConfig();
error InvalidApr();
error InvalidPayoutCaps();
error UnsupportedDayCount();
```

## 5. State Variables

### Hook-Level Mappings

```solidity
// Protocol owner --- gates stagePoolConfig()
address public immutable owner;

// Pool setup
mapping(PoolId => PendingPoolSetup) private _pendingSetup;      // transient; deleted on commit
mapping(PoolId => PoolConfig)       public  poolConfig;          // live after _beforeInitialize
mapping(PoolId => bool)             private _poolInitialized;


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

    // Withdrawal gate -- full position liquidity captured at registration; the
    // beforeRemoveLiquidity gate compares removed liquidity against it (MVP full-withdrawal only)
    uint128 liquidity;              // full position liquidity

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

| Callback                             | Responsibility                                                                                                                                                   |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| stagePoolConfig (Phase 1, onlyOwner) | Validate all PoolConfig bounds, authorizedInitializer, expectedSqrtPriceX96. Store PendingPoolSetup. Emit PoolConfigStaged. Re-stageable until pool initialized. |

|
| beforeInitialize | Validate key.fee == DYNAMIC_FEE_FLAG. Require pending setup exists (PoolNotStaged). Validate sender == authorizedInitializer (UnauthorizedInitializer). Validate sqrtPriceX96 == expectedSqrtPriceX96 (UnexpectedSqrtPrice). Commit poolConfig from pending setup. Delete \_pendingSetup. Set \_poolInitialized = true. Emit PoolConfigInitialized. |
| afterAddLiquidity | Derive entryAmt0, entryAmt1 from liquidity delta. Compute entryNotionalStable. Register PositionState (active=true). Call \_accrue() --- dt=0, initializes lastAccrualTime. Emit PositionRegistered. |
| beforeSwap | Return dynamic fee = baseLpFeeBps + bufferBps. No position state touched. |
| afterSwap | Compute buffer contribution from swap fee. Update bufferBalanceStable. Emit BufferFunded. Emit TickUpdated (for Reactive Network). NO position accrual --- cannot iterate positions. |
| beforeRemoveLiquidity | Validation only. Derive positionKey. Require position is active (revert PositionNotActive). Enforce MVP full-withdrawal only: require uint128(-params.liquidityDelta) == pos.liquidity (revert PartialWithdrawalNotSupported). No minHoldSeconds check. No accrual, IL, or payout computation. Return selector.AccrualUpdated. |
| afterRemoveLiquidity | All settlement logic. Extract outAmt0/outAmt1 from BalanceDelta (fees included per IL spec). Check minHoldSeconds HARD GATE: if not met, emit IneligibleClaim, cleanup PositionState, return. Get exitTick from getSlot0. Call \_accrue() — final accrual. Call \_computeIL(pos, outAmt0, outAmt1, exitTick). Call \_computePayout(). Strict CEI: clear PositionState (active=false) and update buffer BEFORE transfer. Transfer USDC payout to LP. Emit ClaimSettled (IL_CAP, payout>0), PartialPayout (COVERAGE_CAP/BUFFER_CAP or payout==0 with IL>0), or NoClaim (IL_raw==0). emit PositionClosed|

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

### AbstractCallback Inheritance

`RangeGuardHook` inherits from both `BaseHook` (Uniswap v4) and `AbstractCallback`
(Reactive Network's `reactive-lib`). `AbstractCallback` provides the `authorizedSenderOnly`
modifier, which verifies that `msg.sender` equals the Reactive Network's official
Callback Proxy — the on-chain gateway through which all Reactive contract callbacks
are routed on the host chain.

```solidity
import {AbstractCallback} from "reactive-lib/src/abstract-base/AbstractCallback.sol";

contract RangeGuardHook is BaseHook, AbstractCallback {
    constructor(
        IPoolManager _manager,
        address      _owner,
        address      _callbackSender    // Reactive Network Callback Proxy
    )
        BaseHook(_manager)
        AbstractCallback(_callbackSender)
    {
        owner = _owner;
    }
}
```

**Callback Proxy address (all testnets):** `0x0000000000000000000000000000000000fffFfF`

Passed as `_callbackSender` in the deploy script. The hook cannot verify WHICH specific
Reactive contract triggered a callback — it can only verify the callback arrived through
the official Reactive Network infrastructure. This is acceptable: the reactive-callable
functions can only accrue and emit events; they cannot move funds or corrupt accounting.

**Minimum callback gas limit:** 100,000 gas per request (enforced by Reactive Network).
RangeGuard uses 300,000 per callback to accommodate `_accrue` + event emission.

---

### RVM ID Placeholder Rule (Critical)

The Reactive Network overwrites the **first 160 bits** of every callback payload with
the calling Reactive contract's ReactVM ID. Therefore every hook function callable from
a Reactive contract **must accept a leading `address` parameter** (typically named
`sender` and ignored). Callback payloads must place `address(0)` in this first position.

```solidity
// Correct payload encoding in Reactive contract:
bytes memory payload = abi.encodeWithSignature(
    "checkpointCallback(address,bytes32,bytes32)",
    address(0),   // ← RVM ID placeholder — network overwrites this
    poolId,
    positionKey
);
```

All three hook functions callable by the Reactive contract follow this pattern.

---

### checkpoint() Function — Permissionless

```solidity
/// @notice Permissionless accrual update for a single position.
/// @dev For direct callers (keepers, LPs, manual). Rate-limited by minCheckpointInterval.
///      Does NOT include the RVM ID sender parameter — use checkpointCallback() for
///      Reactive Network heartbeat calls.
function checkpoint(PoolId poolId, bytes32 positionKey) external {
    if (!_poolInitialized[poolId])                                    revert PoolNotInitialized();
    PositionState storage pos = positions[poolId][positionKey];
    PoolConfig    storage cfg = poolConfig[poolId];
    if (!pos.active)                                                  revert PositionNotActive();
    if (block.timestamp - pos.lastAccrualTime < cfg.minCheckpointInterval)
                                                                      revert CheckpointTooSoon();
    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);
    emit Checkpointed(poolId, positionKey, block.timestamp);
}
```

### checkpointCallback() — Reactive Network Heartbeat Entry Point

```solidity
/// @notice Reactive Network heartbeat entry point. Mirrors checkpoint()'s gates and
///         effects, with the required RVM ID sender placeholder as the first parameter.
/// @dev  The sender arg is the ReactVM
///      contract ID injected by the network — it is not validated and is ignored.
///      only called by reactive network
function checkpointCallback(
    address /* sender */,       // RVM ID placeholder — ignored
    PoolId   poolId,
    bytes32  positionKey
) external authorizedSenderOnly {
    if (!_poolInitialized[poolId])                                    revert PoolNotInitialized();
    PositionState storage pos = positions[poolId][positionKey];
    PoolConfig    storage cfg = poolConfig[poolId];
    if (!pos.active)                                                  revert PositionNotActive();
    if (block.timestamp - pos.lastAccrualTime < cfg.minCheckpointInterval)
                                                                      revert CheckpointTooSoon();
    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);
    emit Checkpointed(poolId, positionKey, block.timestamp);
}
```

---

### Range Transition Functions (authorizedSenderOnly, atomic)

Each combines accrual + range event emission atomically. The leading `address sender`
parameter is the RVM ID placeholder required by the Reactive Network. The hook maintains
`_lastRangeEventInRange` to enforce correct event alternation.

**Range event guard state:**

```solidity
/// @dev Prevents duplicate consecutive range events per position.
///      Initialized in afterAddLiquidity based on entry tick vs tick range.
mapping(PoolId => mapping(bytes32 => bool)) private _lastRangeEventInRange;
```

Initialized in `afterAddLiquidity`:

```solidity
_lastRangeEventInRange[poolId][positionKey] =
    (entryTick >= pos.tickLower && entryTick < pos.tickUpper);
```

**checkpointAndEmitOutOfRange:**

```solidity
/// @notice Called by Reactive contract on out-of-range transition detection.
/// @dev authorizedSenderOnly. Not rate-limited. Atomic: accrue + PositionOutOfRange.
///      First param is RVM ID placeholder (required by Reactive Network, ignored).
function checkpointAndEmitOutOfRange(
    address /* sender */,       // RVM ID placeholder — ignored
    PoolId  poolId,
    bytes32 positionKey
) external authorizedSenderOnly {
    PositionState storage pos = positions[poolId][positionKey];
    if (!pos.active)                                        revert PositionNotActive();
    if (!_lastRangeEventInRange[poolId][positionKey])       revert PositionAlreadyOutOfRange();

    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);
    _lastRangeEventInRange[poolId][positionKey] = false;

    emit PositionOutOfRange(
        poolId, positionKey,
        pos.tickLower, pos.tickUpper,
        currentTick, pos.earnedCoverageStable, block.timestamp
    );
}
```

**checkpointAndEmitBackInRange:**

```solidity
/// @notice Called by Reactive contract on back-in-range transition detection.
/// @dev authorizedSenderOnly. Not rate-limited. Atomic: accrue + PositionBackInRange.
///      First param is RVM ID placeholder (required by Reactive Network, ignored).
function checkpointAndEmitBackInRange(
    address /* sender */,       // RVM ID placeholder — ignored
    PoolId  poolId,
    bytes32 positionKey
) external authorizedSenderOnly {
    PositionState storage pos = positions[poolId][positionKey];
    if (!pos.active)                                         revert PositionNotActive();
    if (_lastRangeEventInRange[poolId][positionKey])         revert PositionAlreadyInRange();

    int24 currentTick = _getCurrentTick(poolId);
    _accrue(poolId, positionKey, currentTick);
    _lastRangeEventInRange[poolId][positionKey] = true;

    emit PositionBackInRange(
        poolId, positionKey,
        pos.tickLower, pos.tickUpper,
        currentTick, pos.earnedCoverageStable, block.timestamp
    );
}
```

**New errors:**

```solidity
error PositionAlreadyOutOfRange();
error PositionAlreadyInRange();
```

---

### PositionClosed Event

```solidity
/// @notice Emitted on every settlement path in afterRemoveLiquidity.
/// @dev Minimal lifecycle signal for Reactive Network automation — stop tracking.
///      Correlate with ClaimSettled/NoClaim/IneligibleClaim/PartialPayout (same tx).
event PositionClosed(
    PoolId  indexed poolId,
    bytes32 indexed positionKey,
    address         owner
);
```

---

### Reactive Contract — Event Subscriptions

The Reactive contract subscribes to four sources:

```
// Hook events (host chain — Sepolia/Unichain):
PositionRegistered  → add position to tracking, init lastKnownRangeStatus
TickUpdated         → range transition detection
PositionClosed      → remove position from tracking, stop heartbeat

// Cron system (ReactVM chain):
Cron10              → heartbeat trigger (~1 min); check lastCheckpointTime before firing
```

### Reactive Contract — Two Jobs

**Job 1: Range Transition Detection (event-driven)**

On `PositionRegistered`: add position to internal tracking map, initialize
`lastKnownRangeStatus[positionKey]` from entry tick vs tick range.

On `TickUpdated`: evaluate tracked positions against new tick, detect transitions:

(`hookChainId` is a constructor parameter — the host chain the hook is deployed on —
used as both the subscription source chain and the callback destination chain, so the
contract is not hardcoded to Sepolia.)

```solidity
bytes memory payload = abi.encodeWithSignature(
    "checkpointAndEmitOutOfRange(address,bytes32,bytes32)",
    address(0),    // RVM ID placeholder
    pos.poolId,
    positionKey
);
emit Callback(hookChainId, hookAddress, 300_000, payload);
```

On `PositionClosed`: remove position from tracking and heartbeat schedule.

The hook's `_lastRangeEventInRange` guard provides a second layer of protection
against duplicate events if Reactive contract state is stale or restarted.

**Job 2: Periodic Heartbeat (time-driven)**

On `Cron10` (~1 min): iterate active positions, emit one `Callback` per position
that has exceeded `minCheckpointInterval`:

```solidity
for (uint256 i = 0; i < activeKeys.length && i < MAX_POSITIONS_PER_CYCLE; i++) {
    PositionInfo memory pos = positions[activeKeys[i]];
    if (!pos.active) continue;
    if (block.timestamp - pos.lastCheckpointTime < minInterval) continue;

    bytes memory payload = abi.encodeWithSignature(
        "checkpointCallback(address,bytes32,bytes32)",
        address(0),         // RVM ID placeholder
        pos.poolId,
        activeKeys[i]
    );
    emit Callback(hookChainId, hookAddress, 300_000, payload);
}

uint256 private constant MAX_POSITIONS_PER_CYCLE = 20;
```

**Gas note:** Each `Callback` emit costs 100,000 rGas minimum on the Reactive Network.
20 positions × 300,000 = 6,000,000 rGas per heartbeat cycle. Ensure the Reactive
contract's rGas balance is funded accordingly for the demo.

**Production upgrade path:** If position count exceeds 20, migrate to Pattern A
(single Callback to a permissionless batch contract on Sepolia that iterates positions
locally). `checkpoint()` is permissionless so no hook changes are required.

---

### Function Summary

| Function                         | Caller                 | Rate-limited | Sender param | Emits                                    |
| -------------------------------- | ---------------------- | ------------ | ------------ | ---------------------------------------- |
| `checkpoint()`                   | Anyone                 | Yes          | No           | `AccrualUpdated` + `Checkpointed`        |
| `checkpointCallback()`           | authorizedSenderOnly   | Yes          | Yes (RVM ID) | `AccrualUpdated` + `Checkpointed`        |
| `checkpointAndEmitOutOfRange()`  | `authorizedSenderOnly` | No           | Yes (RVM ID) | `AccrualUpdated` + `PositionOutOfRange`  |
| `checkpointAndEmitBackInRange()` | `authorizedSenderOnly` | No           | Yes (RVM ID) | `AccrualUpdated` + `PositionBackInRange` |

---

### Known Limitations (Lazy Accrual at Transitions)

Due to lazy accrual, transition functions evaluate the **current** tick at call time.
Maximum accrual error per transition = one `minCheckpointInterval` (2 min demo).

**Edge cases (MVP demo: won't occur; production: accepted):**

- Tick bounces before call lands: `_lastRangeEventInRange` guard prevents misleading events
- If guard reverts, Reactive contract updates its state and does not retry

**Production mitigation:** reduce `minCheckpointInterval` or pass tick-at-crossing as
a parameter from the Reactive contract.

---

### Deployment Note

The pool setup sequence is two phases only — `setReactiveContract()` is not needed.
Security is provided by `AbstractCallback` (`authorizedSenderOnly` modifier):

```
Phase 1: stagePoolConfig()       — owner, before PoolManager.initialize()
Phase 2: _beforeInitialize()     — PoolManager callback, commits staged config
(then):  seedBuffer()            — admin, funds real token1 custody
(then):  deploy Reactive contract — pass hookAddress + hookChainId + cronTopic +
         minCheckpointInterval; begins subscriptions
```

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
| PositionRegistered    | afterAddLiquidity                          | owner, range, entryNotional, depositTime, coverageApr, dayCountBasis              |
| AccrualUpdated        | \_accrue() --- every call                  | positionKey, dt, delta, newEarnedTotal, isInRange, timestamp                      |
| TickUpdated           | afterSwap --- every swap                   | poolId, newTick, timestamp (lightweight, for Reactive)                            |
| PositionOutOfRange    | checkpointAndEmitOutOfRange                | positionKey, tickLower, tickUpper, currentTick, earnedCoverageAtPause, timestamp  |
| PositionBackInRange   | checkpointAndEmitBackInRange()             | positionKey, tickLower, tickUpper, currentTick, earnedCoverageAtResume, timestamp |
| BufferFunded          | afterSwap                                  | swapAmount, bufferContribution, newBufferBalance                                  |
| BufferSeeded          | seedBuffer()                               | poolId, amount, newBalance                                                        |
| ClaimSettled          | afterRemoveLiquidity (payout > 0)          | owner, range, IL_raw, earnedCoverage, payout, limitingFactor                      |
| NoClaim               | afterRemoveLiquidity (IL = 0)              | owner, range, V_HODL, V_actual                                                    |
| IneligibleClaim       | afterRemoveLiquidity (minHold not met)     | owner, range, reason                                                              |
| PartialPayout         | afterRemoveLiquidity (buffer insufficient) | owner, range, requested, actual                                                   |
| Checkpointed          | checkpoint() / checkpointCallback()        | poolId, positionKey, timestamp                                                    |
| PositionClosed        | afterRemoveLiquidity                       | poolId, positionKey, owner                                                        |

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
- \_poolInitialized guard prevents pool re-initialization
- \_pendingSetup staging pattern prevents pool initialization with wrong price or unauthorized caller
- Hard bounds enforced at stagePoolConfig() time for all parameters
- Single admin per pool for MVP (multisig or DAO recommended for mainnet)
- Admin can only call seedBuffer() --- no parameter changes possible
- dynamicFeeBps always derived --- never stored, preventing fee drift
- secondsPerYear validated to only accept A/365F or A/360
- Reentrancy: position state cleared before payout transfer in afterRemoveLiquidity

## 13. MVP Scope

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

- Pool key: currency0 = native ETH (address(0)), currency1 = USDC; tickSpacing = 60
- Pool initialized at ~$2,000/ETH (sqrtPriceX96 set at poolManager.initialize())
- LP deposits mix of ETH + USDC (Case B --- price in range at deposit)
- Entry notional: ~10,000 USDC
- Range: [$1,800, $2,200]

### Demo Script Narrative Arc (vm.warp in Foundry)

[Setup] Deploy hook, stage ETH/USDC pool config (stagePoolConfig), initialize pool
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
4. Hook callbacks --- stagePoolConfig, \_beforeInitialize, afterAddLiquidity, beforeSwap, afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity
5. checkpoint() + checkpointCallback() + checkpointAndEmitOutOfRange() +
   checkpointAndEmitBackInRange() --- accrual drivers + Reactive Network
   entry points (implemented in Reactive contract session)
6. Reactive Contract --- range transition detection + periodic heartbeat
7. Sepolia/ReactVM deployment --- hook → Sepolia, Reactive → ReactVM (deploy scripts ready)
8. Demo script --- RangeGuardDemo.s.sol with vm.warp
9. Frontend dashboard --- coverage report rendered from Sepolia events

## 17. References

- [Uniswap v4 Core Docs]
- [Uniswap v4 Periphery Docs]
- [Uniswap v4 Hooks Docs]
- [Foundry Docs]
- [Reactive Network Docs]
