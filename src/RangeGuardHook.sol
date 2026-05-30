// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

/// @title RangeGuardHook
/// @notice Uniswap v4 hook providing native impermanent-loss coverage for LPs,
///         funded by dynamic-fee skimming and paid out on full withdrawal.
/// @dev    Coverage accrual is lazy and range-gated. This revision implements the
///         core accrual primitive (`_accrue`) and the shared accrual math helper
///         (`_accrueEarned`) together with the minimum state required to support them.
contract RangeGuardHook is BaseHook {
    /*//////////////////////////////////////////////////////////////
                              TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Identifies which cap bound a settlement payout; reported with every settlement.
    /// @dev    NONE is returned only when there is no impermanent loss (IL_raw == 0).
    enum LimitingFactor {
        NONE, // IL_raw == 0: no claim needed
        IL_CAP, // maxPayoutPctOfIl (% of IL covered) was the binding constraint
        COVERAGE_CAP, // earnedCoverageStable was the binding constraint
        BUFFER_CAP // maxPayoutPctOfBuffer (% of buffer) was the binding constraint

    }

    /// @notice Immutable configuration for a single pool, set once at initialization.
    /// @dev    All Bps values use a 10,000 denominator; APR uses 1e18 fixed-point.
    struct PoolConfig {
        // Fees
        uint24 baseLpFeeBps; // LP fee portion, e.g. 3000 = 0.30%
        uint24 bufferBps; // Buffer fee portion, e.g. 1000 = 0.10%
        // dynamicFeeBps = baseLpFeeBps + bufferBps (always derived, never stored)
        // Coverage accrual
        uint256 coverageApr; // 1e18 fixed-point, e.g. 0.10e18 = 10%
        uint256 secondsPerYear; // A/365F = 31_536_000 | A/360 = 31_104_000
        // Eligibility
        uint32 minHoldSeconds; // Hard gate: payout = 0 if not met
        // Payout caps
        uint16 maxPayoutPctOfIl; // Cap 1: % of IL covered, e.g. 5000 = 50%
        uint16 maxPayoutPctOfBuffer; // Cap 3: % of buffer, e.g. 1000 = 10%
        // Accrual ceiling
        uint256 maxAccruedCoverageMultiple; // e.g. 3e18 = 3x entryNotional; 0 = disabled
        // Buffer health (informational)
        uint256 targetBufferSize; // Actuarial target, used in getBufferHealth()
        // Checkpoint rate limiting (per pool)
        uint32 minCheckpointInterval; // e.g. 2 min demo / 1 hour mainnet
        // Admin
        address admin; // seedBuffer() only; no parameter changes
    }

    /// @notice Mutable pool-level buffer accounting.
    struct PoolState {
        uint256 bufferBalanceStable; // Current buffer (stable units)
        uint256 totalSkimmedStable; // Cumulative buffer funded from fees
        uint256 totalPaidOutStable; // Cumulative payouts
    }

    /// @notice Per-position lifecycle and accrual state.
    /// @dev    Field order is chosen for storage packing: the snapshot amounts fill
    ///         one slot, and the small lifecycle fields share a single slot.
    struct PositionState {
        // Snapshot - set once at deposit, never mutated (slot 0)
        uint128 entryAmt0; // token0 (volatile) amount at deposit
        uint128 entryAmt1; // token1 (stable) amount at deposit
        // Snapshot + accrual lifecycle fields (slot 1, packed)
        int24 entryTick; // Pool tick at deposit
        int24 tickLower; // Position lower tick bound
        int24 tickUpper; // Position upper tick bound
        uint32 depositTime; // block.timestamp at deposit
        uint32 lastAccrualTime; // Timestamp of last accrual update
        bool active; // true = registered, false = cleared
        // Accrual / settlement (own slots)
        uint256 entryNotionalStable; // entryAmt1 + entryAmt0 * P_entry (stable)
        uint256 earnedCoverageStable; // Cumulative coverage earned (stable)
        uint256 pendingPayout; // Computed payout awaiting execution
    }

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Fixed-point precision for APR and accrual-multiple math (1e18).
    uint256 internal constant APR_PRECISION = 1e18;

    /// @notice Fixed-point precision for tick-derived prices (1e18).
    /// @dev    Price is the raw token1/token0 ratio scaled by this factor, so that
    ///         `rawToken0Amount * price / PRICE_PRECISION` yields raw token1 units.
    ///         Token decimals are handled implicitly by the raw ratio (decimal-agnostic).
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @notice Basis-points denominator (10,000) for all percentage caps.
    uint256 internal constant BPS_DENOM = 10_000;

    /// @notice The Uniswap v4 PoolManager this hook is bound to.
    IPoolManager public immutable i_manager;

    /// @notice Immutable per-pool configuration, keyed by PoolId.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Mutable per-pool buffer accounting, keyed by PoolId.
    mapping(PoolId => PoolState) public poolState;

    /// @notice Per-position state, scoped by pool then position key.
    mapping(PoolId => mapping(bytes32 => PositionState)) public positions;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every `_accrue()` call for an active position.
    /// @param poolId          Pool the position belongs to.
    /// @param positionKey     Position identifier within the pool.
    /// @param dt              Seconds elapsed since the previous accrual.
    /// @param delta           Coverage actually added this accrual (post-ceiling clamp).
    /// @param newEarnedTotal  Cumulative earned coverage after this accrual.
    /// @param isInRange       Whether the position was in range for this accrual.
    /// @param timestamp       block.timestamp at which accrual was evaluated.
    event AccrualUpdated(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        uint256 dt,
        uint256 delta,
        uint256 newEarnedTotal,
        bool isInRange,
        uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _manager) BaseHook(_manager) {
        i_manager = _manager;
    }

    /*//////////////////////////////////////////////////////////////
                             EXTERNAL / PUBLIC
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _beforeInitialize(address, PoolKey calldata, uint160) internal override returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address owner,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, delta);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, delta);
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    /// @notice Lazily advances a single position's earned coverage to block.timestamp.
    /// @dev    Range-gated and conservative: accrues only while active, in range, and
    ///         when time has elapsed. Never iterates positions and never mutates the
    ///         entry snapshot. Range status is derived from the supplied `currentTick`.
    /// @param poolId       Pool the position belongs to.
    /// @param positionKey  Position identifier within the pool.
    /// @param currentTick  Current pool tick used to derive in-range status.
    function _accrue(PoolId poolId, bytes32 positionKey, int24 currentTick) internal {
        PositionState storage pos = positions[poolId][positionKey];

        // Inactive positions never accrue.
        if (!pos.active) return;

        // Guard against underflow: fail safe to dt = 0 (no accrual) rather than revert.
        uint256 last = pos.lastAccrualTime;
        uint256 nowTs = block.timestamp;
        uint256 dt = nowTs > last ? nowTs - last : 0;

        // Range status derived from the current tick: [tickLower, tickUpper).
        bool isInRange = pos.tickLower <= currentTick && currentTick < pos.tickUpper;

        PoolConfig storage cfg = poolConfig[poolId];

        (uint256 newEarned, uint256 appliedDelta) = _accrueEarned(
            pos.earnedCoverageStable,
            pos.entryNotionalStable,
            cfg.coverageApr,
            cfg.secondsPerYear,
            cfg.maxAccruedCoverageMultiple,
            dt,
            isInRange
        );

        // Effects: only write coverage when it actually changed.
        if (appliedDelta > 0) {
            pos.earnedCoverageStable = newEarned;
        }
        // Advance the accrual clock whenever time elapsed, even while out of range,
        // so paused seconds are consumed and never retroactively accrue.
        if (dt > 0) {
            pos.lastAccrualTime = uint32(nowTs);
        }

        emit AccrualUpdated(poolId, positionKey, dt, appliedDelta, newEarned, isInRange, nowTs);
    }

    /// @notice Pure accrual math + ceiling clamp shared by `_accrue()` and the live
    ///         coverage view, guaranteeing the two can never drift.
    /// @dev    Single-truncation form; integer division rounds down (conservative for
    ///         insurance accounting). Returns the new earned total and the applied
    ///         increment after the ceiling clamp.
    /// @param currentEarned               Coverage earned so far (stable units).
    /// @param entryNotionalStable         Position entry notional (stable units).
    /// @param coverageApr                 Coverage APR, 1e18 fixed-point.
    /// @param secondsPerYear              Day-count seconds per year.
    /// @param maxAccruedCoverageMultiple  Ceiling multiple of notional (1e18); 0 disables.
    /// @param dt                          Seconds elapsed since last accrual.
    /// @param isInRange                   Whether the position is in range.
    /// @return newEarned     Earned coverage after this accrual (clamped to ceiling).
    /// @return appliedDelta  Coverage actually added (newEarned - currentEarned).
    function _accrueEarned(
        uint256 currentEarned,
        uint256 entryNotionalStable,
        uint256 coverageApr,
        uint256 secondsPerYear,
        uint256 maxAccruedCoverageMultiple,
        uint256 dt,
        bool isInRange
    ) internal pure returns (uint256 newEarned, uint256 appliedDelta) {
        // No accrual when out of range, no time elapsed, or nothing to accrue on.
        if (!isInRange || dt == 0 || entryNotionalStable == 0 || coverageApr == 0) {
            return (currentEarned, 0);
        }

        // delta = notional * APR * (dt / secondsPerYear), one truncation, rounds down.
        uint256 rawDelta = (entryNotionalStable * coverageApr * dt) / (secondsPerYear * APR_PRECISION);
        newEarned = currentEarned + rawDelta;

        // Enforce the accrual ceiling when enabled.
        if (maxAccruedCoverageMultiple > 0) {
            uint256 cap = entryNotionalStable * maxAccruedCoverageMultiple / APR_PRECISION;
            if (newEarned > cap) {
                newEarned = cap;
            }
        }

        // Coverage can never decrease; defensively clamp the applied delta to zero.
        if (newEarned <= currentEarned) {
            return (currentEarned, 0);
        }
        appliedDelta = newEarned - currentEarned;
    }

    /// @notice Converts a pool tick into a fixed-point price (raw token1 per raw token0).
    /// @dev    Returns the raw token1/token0 ratio scaled by PRICE_PRECISION, so that
    ///         `rawToken0Amount * price / PRICE_PRECISION` yields raw token1 (stable)
    ///         units. Decimal-agnostic: token decimals are baked into the raw ratio, so
    ///         no per-token decimal configuration is required. Shared by IL settlement
    ///         and (later) entry-notional computation so the two cannot use divergent
    ///         price conventions.
    ///
    ///         Rounding: both mulDiv steps truncate toward zero, so the price is rounded
    ///         DOWN. This is applied consistently to V_HODL and V_actual in _computeIL().
    ///
    ///         Price source: this is the pool spot price derived from a single tick.
    ///         Spot prices are manipulable within a transaction (e.g. flash-swap tick
    ///         movement); MVP scope accepts this. A TWAP/oracle source is deferred to a
    ///         later phase and should replace this for production hardening.
    /// @param  tick      The pool tick to convert (must be within TickMath bounds).
    /// @return priceX18  Raw token1/token0 ratio scaled by PRICE_PRECISION (1e18).
    function _priceFromTick(int24 tick) internal pure returns (uint256 priceX18) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        // raw ratio * 2^96; mulDiv carries the 512-bit intermediate so sqrtP^2 cannot overflow.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        // rescale from Q96 to PRICE_PRECISION fixed-point.
        priceX18 = FullMath.mulDiv(priceX96, PRICE_PRECISION, FixedPoint96.Q96);
    }

    /// @notice Computes raw impermanent loss (in stable units) for a settling position.
    /// @dev    Pure: reads only the in-memory snapshot and the supplied amounts; never
    ///         touches storage and never mutates the entry snapshot. All values are raw
    ///         token amounts; the result is raw token1 (stable) units.
    ///
    ///         IL is measured against holding the entry token amounts, both legs valued
    ///         at the exit price:
    ///           V_HODL   = entryAmt1 + entryAmt0 * P_exit
    ///           V_actual = outAmt1   + outAmt0   * P_exit   (withdrawn amounts incl. fees)
    ///           IL_raw   = max(0, V_HODL - V_actual)
    ///
    ///         Rounding: P_exit is rounded down (see _priceFromTick); the same price is
    ///         applied to both V_HODL and V_actual, so the rounding largely offsets.
    ///         IL_raw is floored at zero and can never be negative.
    ///
    ///         Price source: spot price from `exitTick`, which is manipulable in-tx;
    ///         accepted for MVP (TWAP/oracle deferred).
    /// @param  pos       Position snapshot (only entryAmt0/entryAmt1 are read).
    /// @param  outAmt0   Raw token0 amount withdrawn by the LP (fees included).
    /// @param  outAmt1   Raw token1 amount withdrawn by the LP (fees included).
    /// @param  exitTick  Pool tick at settlement, used to derive the exit price.
    /// @return IL_raw    Raw impermanent loss in stable (token1) units; 0 if none.
    function _computeIL(PositionState memory pos, uint128 outAmt0, uint128 outAmt1, int24 exitTick)
        internal
        pure
        returns (uint256 IL_raw)
    {
        uint256 pExit = _priceFromTick(exitTick);

        uint256 vHodl = uint256(pos.entryAmt1) + FullMath.mulDiv(uint256(pos.entryAmt0), pExit, PRICE_PRECISION);
        uint256 vActual = uint256(outAmt1) + FullMath.mulDiv(uint256(outAmt0), pExit, PRICE_PRECISION);

        IL_raw = vHodl > vActual ? vHodl - vActual : 0;
    }

    /// @notice Computes the capped settlement payout and the cap that bound it.
    /// @dev    Thin storage-reading wrapper over the pure `_computePayoutAmount` core,
    ///         mirroring the `_accrue`/`_accrueEarned` split so the cap logic lives in one
    ///         pure, fuzzable place and the live view (future getEstimatedPayout) cannot
    ///         drift from settlement.
    ///
    ///         Read-only: never mutates state, never decrements the buffer (the transfer
    ///         and buffer update are owned by afterRemoveLiquidity), and never emits. The
    ///         final `_accrue()` and the `minHoldSeconds` eligibility gate are the caller's
    ///         responsibility and MUST run first; `pos.earnedCoverageStable` is therefore
    ///         expected to already reflect the final accrual.
    /// @param  poolId  Pool the position belongs to (selects config + buffer state).
    /// @param  pos     Position snapshot; only `earnedCoverageStable` is read.
    /// @param  ILRaw   Raw impermanent loss from `_computeIL()` (stable units).
    /// @return payout  Capped payout in stable units.
    /// @return factor  Which cap was binding (NONE only when ILRaw == 0).
    function _computePayout(PoolId poolId, PositionState memory pos, uint256 ILRaw)
        internal
        view
        returns (uint256 payout, LimitingFactor factor)
    {
        PoolConfig storage cfg = poolConfig[poolId];
        return _computePayoutAmount(
            ILRaw,
            pos.earnedCoverageStable,
            poolState[poolId].bufferBalanceStable,
            cfg.maxPayoutPctOfIl,
            cfg.maxPayoutPctOfBuffer
        );
    }

    /// @notice Pure three-cap payout selection shared by `_computePayout` (and reusable by
    ///         a future estimated-payout view), guaranteeing the two cannot drift.
    /// @dev    Applies the caps in spec order and selects the minimum:
    ///           IL_covered = ILRaw  * maxPayoutPctOfIl     / BPS_DENOM
    ///           bufferCap  = buffer * maxPayoutPctOfBuffer / BPS_DENOM
    ///           payout     = min(IL_covered, earned, bufferCap)
    ///         The binding cap is reported via `factor`, with ties resolving to the earlier
    ///         cap in the order IL_CAP -> COVERAGE_CAP -> BUFFER_CAP (strict `<`). When
    ///         ILRaw == 0 the function short-circuits to (0, NONE) — the only NONE path.
    ///
    ///         Note: when ILRaw > 0 but IL_covered rounds down to 0 (tiny IL or tiny cap),
    ///         the result is (0, IL_CAP) — a zero payout is still attributed to the IL cap,
    ///         never NONE.
    ///
    ///         Multiplications use `FullMath.mulDiv`, so a 100% cap applied to a very large
    ///         IL or buffer cannot overflow. Division rounds DOWN (conservative), matching
    ///         the rest of the accounting. `payout <= bufferBalance` holds because
    ///         `maxPayoutPctOfBuffer <= BPS_DENOM` is enforced at pool initialization.
    /// @param  ILRaw                 Raw impermanent loss (stable units).
    /// @param  earned                Earned coverage so far (stable units).
    /// @param  bufferBalance         Current buffer balance (stable units).
    /// @param  maxPayoutPctOfIl      Cap 1: BPS of IL covered.
    /// @param  maxPayoutPctOfBuffer  Cap 3: BPS of buffer payable.
    /// @return payout                Capped payout (stable units).
    /// @return factor                Binding cap (NONE only when ILRaw == 0).
    function _computePayoutAmount(
        uint256 ILRaw,
        uint256 earned,
        uint256 bufferBalance,
        uint16 maxPayoutPctOfIl,
        uint16 maxPayoutPctOfBuffer
    ) internal pure returns (uint256 payout, LimitingFactor factor) {
        // No impermanent loss: nothing to cover, and the only path that yields NONE.
        if (ILRaw == 0) return (0, LimitingFactor.NONE);

        uint256 ilCovered = FullMath.mulDiv(ILRaw, maxPayoutPctOfIl, BPS_DENOM);
        uint256 bufferCap = FullMath.mulDiv(bufferBalance, maxPayoutPctOfBuffer, BPS_DENOM);

        // Start at cap 1, then take the running minimum, recording which cap bound.
        // Strict `<` means ties resolve to the earlier (higher-precedence) cap.
        payout = ilCovered;
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
}
