// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
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
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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

    /// @notice Transient staging record for a pool, written by `stagePoolConfig()` and
    ///         deleted atomically in `_beforeInitialize()` on commit.
    /// @dev    `exists` distinguishes a staged pool from the zero-value default; the
    ///         reactive address is intentionally absent (registered later in Phase 3).
    struct PendingPoolSetup {
        PoolConfig config; // Fully validated config awaiting commit
        address authorizedInitializer; // Only address permitted to initialize the pool
        uint160 expectedSqrtPriceX96; // Exact price the pool must be initialized at
        bool exists; // true once staged, false after commit/never-staged
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

    /// @notice Fee denominator (1,000,000) for swap-fee math, matching v4's pip units.
    /// @dev    v4 fees are hundredths of a bip: `LPFeeLibrary.MAX_LP_FEE == 1_000_000` is
    ///         100%, so the config's `baseLpFeeBps`/`bufferBps` (e.g. 3000 = 0.30%) are
    ///         pips, NOT true basis points despite the field names. Buffer-contribution
    ///         math therefore divides by this, NOT `BPS_DENOM`; using 10,000 would credit
    ///         the buffer 100x too fast. Payout-cap percentages remain `BPS_DENOM`-based.
    uint256 internal constant FEE_DENOM = 1_000_000;

    /// @notice Maximum LP fee portion accepted at staging (10,000 bps = 100%).
    uint24 internal constant MAX_BASE_FEE_BPS = 10_000;

    /// @notice Maximum buffer fee portion accepted at staging (5,000 bps = 50%).
    uint24 internal constant MAX_BUFFER_BPS = 5_000;

    /// @notice Maximum coverage APR accepted at staging (0.50e18 = 50%).
    uint256 internal constant MAX_COVERAGE_APR = 0.5e18;

    /// @notice Maximum value for a percentage cap expressed in bps (10,000 = 100%).
    uint16 internal constant MAX_PAYOUT_PCT = 10_000;

    /// @notice Day-count seconds-per-year: Actual/365 Fixed.
    uint256 internal constant SECONDS_PER_YEAR_365F = 31_536_000;

    /// @notice Day-count seconds-per-year: Actual/360.
    uint256 internal constant SECONDS_PER_YEAR_360 = 31_104_000;

    /// @notice The Uniswap v4 PoolManager this hook is bound to.
    IPoolManager public immutable i_manager;

    /// @notice Protocol owner; gates `stagePoolConfig()` and `setReactiveContract()`.
    /// @dev    Distinct from per-pool `authorizedInitializer` and `config.admin`.
    address public immutable owner;

    /// @notice Transient staged setup per pool; deleted on commit in `_beforeInitialize()`.
    /// @dev    `internal` (not externally exposed) so the test harness subclass can assert
    ///         on it without a production getter, per the project's harness pattern.
    mapping(PoolId => PendingPoolSetup) internal _pendingSetup;

    /// @notice True once a pool's staged config has been committed via `_beforeInitialize()`.
    mapping(PoolId => bool) internal _poolInitialized;

    /// @notice One-time guard locking `reactiveContract[poolId]` after registration.
    mapping(PoolId => bool) internal _reactiveSet;

    /// @notice Immutable per-pool configuration, keyed by PoolId.
    mapping(PoolId => PoolConfig) public poolConfig;

    /// @notice Registered reactive contract per pool; address(0) until Phase 3.
    mapping(PoolId => address) public reactiveContract;

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

    /// @notice Emitted on `afterAddLiquidity` when a new position is registered.
    /// @dev    Every field is sourced from the immutable entry snapshot so the coverage
    ///         report can render the entry line entirely from this one event. Not emitted
    ///         on a top-up to an already-active position (the snapshot is preserved).
    /// @param poolId               Pool the position belongs to.
    /// @param positionKey          Position identifier within the pool.
    /// @param owner                Position owner (the v4 `sender`; see MVP limitation).
    /// @param tickLower            Position lower tick bound.
    /// @param tickUpper            Position upper tick bound.
    /// @param entryAmt0            token0 (volatile) principal deposited.
    /// @param entryAmt1            token1 (stable) principal deposited.
    /// @param entryNotionalStable  entryAmt1 + entryAmt0 * P_entry (stable units).
    /// @param entryTick            Pool tick at deposit.
    /// @param depositTime          block.timestamp at deposit.
    /// @param coverageApr          Pool coverage APR (1e18 fixed-point) at deposit.
    /// @param secondsPerYear       Day-count basis (A/365F or A/360) at deposit.
    event PositionRegistered(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 entryAmt0,
        uint128 entryAmt1,
        uint256 entryNotionalStable,
        int24 entryTick,
        uint32 depositTime,
        uint256 coverageApr,
        uint256 secondsPerYear
    );

    /// @notice Emitted on `stagePoolConfig()` (Phase 1) when a config is staged or re-staged.
    event PoolConfigStaged(
        PoolId indexed poolId, PoolConfig config, address authorizedInitializer, uint160 expectedSqrtPriceX96
    );

    /// @notice Emitted on `_beforeInitialize()` commit (Phase 2). Reactive address not yet set.
    event PoolConfigInitialized(PoolId indexed poolId, PoolConfig config);

    /// @notice Emitted on `setReactiveContract()` (Phase 3) when the reactive address is locked.
    event ReactiveContractSet(PoolId indexed poolId, address reactive);

    /// @notice Emitted on `afterSwap` when a swap funds the buffer (skipped on zero contribution).
    /// @dev    The contribution is a NOTIONAL credit (no token delta is taken in MVP — the buffer
    ///         is internal accounting; real backing comes from `seedBuffer()`). The buffer grows
    ///         from every swap regardless of whether any position is in range.
    /// @param poolId            Pool the swap belongs to.
    /// @param contribution      Buffer credit from this swap (stable units).
    /// @param newBufferBalance  Buffer balance after the credit (stable units).
    event BufferFunded(PoolId indexed poolId, uint256 contribution, uint256 newBufferBalance);

    /// @notice Emitted on every `afterSwap` with the post-swap tick, for Reactive Network subscription.
    /// @dev    Lightweight by design: the Reactive contract derives per-position range crossings
    ///         off this event. The hook never iterates positions here.
    /// @param poolId     Pool the swap belongs to.
    /// @param newTick    Pool tick after the swap (read via `getSlot0`).
    /// @param timestamp  block.timestamp at the swap.
    event TickUpdated(PoolId indexed poolId, int24 newTick, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a caller other than `owner` invokes an owner-gated function.
    error NotOwner();

    /// @notice Thrown by `stagePoolConfig()` when the pool is already initialized.
    error PoolAlreadyInitialized();

    /// @notice Thrown by `setReactiveContract()` when the pool is not yet initialized.
    error PoolNotInitialized();

    /// @notice Thrown by `_beforeInitialize()` when no staged setup exists for the pool.
    error PoolNotStaged();

    /// @notice Thrown when `config.admin == address(0)`.
    error ZeroAdmin();

    /// @notice Thrown when a reactive address of `address(0)` is supplied.
    error ZeroReactive();

    /// @notice Thrown when `authorizedInitializer == address(0)`.
    error ZeroInitializer();

    /// @notice Thrown when `expectedSqrtPriceX96 == 0`.
    error ZeroSqrtPrice();

    /// @notice Thrown when `key.fee` does not carry the dynamic-fee flag.
    error NotDynamicFee();

    /// @notice Thrown by `_beforeInitialize()` when `sender != authorizedInitializer`.
    error UnauthorizedInitializer();

    /// @notice Thrown by `_beforeInitialize()` when `sqrtPriceX96 != expectedSqrtPriceX96`.
    error UnexpectedSqrtPrice();

    /// @notice Thrown by `setReactiveContract()` when the reactive address is already set.
    error ReactiveAlreadySet();

    /// @notice Thrown when fee bounds are exceeded (`baseLpFeeBps` or `bufferBps`).
    error InvalidFeeConfig();

    /// @notice Thrown when `coverageApr` is zero or exceeds `MAX_COVERAGE_APR`.
    error InvalidApr();

    /// @notice Thrown when a payout cap exceeds its permitted maximum.
    error InvalidPayoutCaps();

    /// @notice Thrown when `secondsPerYear` is neither A/365F nor A/360.
    error UnsupportedDayCount();

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts a function to the protocol `owner`.
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _manager, address _owner) BaseHook(_manager) {
        i_manager = _manager;
        owner = _owner;
    }

    /*//////////////////////////////////////////////////////////////
                             EXTERNAL / PUBLIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Phase 1: stage a pool's immutable config before `PoolManager.initialize()`.
    /// @dev    onlyOwner. Validates all bounds and pins the authorized initializer and the
    ///         exact init price. Re-stageable (overwrites) until the pool is initialized;
    ///         reverts `PoolAlreadyInitialized` thereafter. The reactive address is NOT
    ///         staged here (registered in Phase 3 to resolve the circular deploy dependency).
    ///         All checks precede the single storage write (CEI); no external calls.
    /// @param  key                    Pool key; `key.fee` must carry the dynamic-fee flag.
    /// @param  config                 Fully specified pool configuration to stage.
    /// @param  authorizedInitializer  Only address permitted to initialize this pool.
    /// @param  expectedSqrtPriceX96   Exact sqrt price the pool must be initialized at.
    function stagePoolConfig(
        PoolKey calldata key,
        PoolConfig calldata config,
        address authorizedInitializer,
        uint160 expectedSqrtPriceX96
    ) external onlyOwner {
        PoolId poolId = key.toId();

        // Checks (fail-fast, in spec order) — no storage written until all pass.
        if (_poolInitialized[poolId]) revert PoolAlreadyInitialized();
        if (config.admin == address(0)) revert ZeroAdmin();
        if (authorizedInitializer == address(0)) revert ZeroInitializer();
        if (expectedSqrtPriceX96 == 0) revert ZeroSqrtPrice();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFee();
        if (config.baseLpFeeBps > MAX_BASE_FEE_BPS) revert InvalidFeeConfig();
        if (config.bufferBps > MAX_BUFFER_BPS) revert InvalidFeeConfig();
        if (config.coverageApr == 0 || config.coverageApr > MAX_COVERAGE_APR) revert InvalidApr();
        if (config.maxPayoutPctOfIl > MAX_PAYOUT_PCT) revert InvalidPayoutCaps();
        if (config.maxPayoutPctOfBuffer > BPS_DENOM) revert InvalidPayoutCaps();
        if (config.secondsPerYear != SECONDS_PER_YEAR_365F && config.secondsPerYear != SECONDS_PER_YEAR_360) {
            revert UnsupportedDayCount();
        }

        // Effects: stage (or overwrite) the pending setup.
        PendingPoolSetup storage pending = _pendingSetup[poolId];
        pending.config = config;
        pending.authorizedInitializer = authorizedInitializer;
        pending.expectedSqrtPriceX96 = expectedSqrtPriceX96;
        pending.exists = true;

        emit PoolConfigStaged(poolId, config, authorizedInitializer, expectedSqrtPriceX96);
    }

    /// @notice Phase 3: register the reactive contract address once, after its deployment.
    /// @dev    onlyOwner, one-time. The `_reactiveSet` guard permanently locks the address
    ///         after the first successful call. Note: `onlyOwner` runs before the one-time
    ///         guard, so a non-owner second caller reverts `NotOwner`, not `ReactiveAlreadySet`.
    /// @param  key       Pool key identifying the initialized pool.
    /// @param  reactive  Deployed reactive contract address (must be non-zero).
    function setReactiveContract(PoolKey calldata key, address reactive) external onlyOwner {
        PoolId poolId = key.toId();

        if (!_poolInitialized[poolId]) revert PoolNotInitialized();
        if (_reactiveSet[poolId]) revert ReactiveAlreadySet();
        if (reactive == address(0)) revert ZeroReactive();

        reactiveContract[poolId] = reactive;
        _reactiveSet[poolId] = true;

        emit ReactiveContractSet(poolId, reactive);
    }

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

    /// @notice Phase 2: PoolManager callback that commits the staged config atomically.
    /// @dev    Authoritative gate for pool creation: validates the dynamic-fee flag, that a
    ///         staged setup exists, that `sender` is the authorized initializer, and that the
    ///         price matches exactly. On success it copies the staged config into
    ///         `poolConfig`, deletes the pending setup, and marks the pool initialized. Any
    ///         revert here makes `PoolManager.initialize()` revert in full, so a pool can
    ///         never exist without a committed config. `reactiveContract[poolId]` remains
    ///         `address(0)` until Phase 3.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        // Checks (spec order). NotDynamicFee is authoritative; PoolNotStaged also implicitly
        // catches a mismatched key since PoolId is derived from the full key (incl. fee).
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFee();

        PendingPoolSetup storage pending = _pendingSetup[poolId];
        if (!pending.exists) revert PoolNotStaged();
        if (sender != pending.authorizedInitializer) revert UnauthorizedInitializer();
        if (sqrtPriceX96 != pending.expectedSqrtPriceX96) revert UnexpectedSqrtPrice();

        // Effects: commit config, clear staging, mark initialized.
        PoolConfig memory committed = pending.config;
        poolConfig[poolId] = committed;
        delete _pendingSetup[poolId];
        _poolInitialized[poolId] = true;

        emit PoolConfigInitialized(poolId, committed);

        return this.beforeInitialize.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice Derives a pool-scoped, collision-resistant key for a position.
    /// @dev    Pure. The outer `positions[poolId]` mapping prevents cross-pool collisions
    ///         even when two pools share an identical owner, range, and salt.
    /// @param  owner_     Position owner (the v4 `sender` for MVP).
    /// @param  tickLower  Position lower tick bound.
    /// @param  tickUpper  Position upper tick bound.
    /// @param  salt       Caller-supplied salt for distinct positions at the same range.
    /// @return The position key within a pool.
    function _positionKey(address owner_, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(owner_, tickLower, tickUpper, salt));
    }

    /// @notice Registers a new LP position and seeds its accrual baseline.
    /// @dev    Lifecycle: requires the pool to be initialized (`PoolNotInitialized`
    ///         otherwise). Writes the immutable entry snapshot exactly once — a top-up to an
    ///         already-active position is a no-op for accounting (the snapshot is preserved),
    ///         consistent with the single-range / full-withdrawal MVP scope. The snapshot
    ///         (including `lastAccrualTime = block.timestamp`) is written BEFORE the baseline
    ///         `_accrue()` so that call observes `dt == 0` and accrues nothing — it only
    ///         emits the opening `AccrualUpdated` line for the coverage report.
    ///
    ///         MVP limitation: `owner` is the v4 `sender` (the router/caller to the
    ///         PoolManager), not necessarily the end LP. Documented and accepted for MVP.
    /// @param  sender  v4 caller, used as the position owner in the position key.
    /// @param  key     Pool key (selects the initialized pool and its config).
    /// @param  params  Liquidity params; supplies the tick range and position salt.
    /// @param  delta   Caller balance delta (principal + fees) for this add.
    /// @param  feesAccrued  Fees portion of `delta`; subtracted so prior fees never inflate
    ///                      the entry snapshot (zero for a brand-new position).
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Lifecycle invariant: positions may only register on an initialized pool.
        if (!_poolInitialized[poolId]) revert PoolNotInitialized();

        bytes32 positionKey = _positionKey(sender, params.tickLower, params.tickUpper, params.salt);
        PositionState storage pos = positions[poolId][positionKey];

        // Skip re-registration: the entry snapshot is set once and never mutated. A top-up
        // to an active position preserves the original snapshot (early-return before any
        // state read of the pool, by design).
        if (pos.active) {
            return (this.afterAddLiquidity.selector, delta);
        }

        // Current pool tick at deposit: drives the entry price and the in-range status.
        (, int24 currentTick,,) = i_manager.getSlot0(poolId);

        // Effects: write the immutable snapshot and accrual baseline. `lastAccrualTime` is
        // set to now BEFORE `_accrue()` below so the baseline call sees `dt == 0`.
        // `earnedCoverageStable` and `pendingPayout` stay zero on the fresh slot. The entry
        // amounts and notional are computed in a tight scope so their intermediates free
        // before the event emission (avoids stack-too-deep without via-IR).
        {
            // Principal contributed by the LP, net of any fees credited in the same delta.
            // For a fresh position `feesAccrued == 0`; the subtraction is the correct
            // general form. Adds make the caller delta negative (tokens owed to the pool),
            // so take the magnitude for the entry amounts.
            BalanceDelta principal = delta - feesAccrued;
            uint128 entryAmt0 = _absToUint128(principal.amount0());
            uint128 entryAmt1 = _absToUint128(principal.amount1());

            pos.entryAmt0 = entryAmt0;
            pos.entryAmt1 = entryAmt1;
            // entryNotionalStable = entryAmt1 + entryAmt0 * P_entry, using the shared
            // `_priceFromTick` convention so entry and settlement (`_computeIL`) cannot
            // diverge.
            pos.entryNotionalStable =
                uint256(entryAmt1) + FullMath.mulDiv(uint256(entryAmt0), _priceFromTick(currentTick), PRICE_PRECISION);
        }

        pos.entryTick = currentTick;
        pos.tickLower = params.tickLower;
        pos.tickUpper = params.tickUpper;
        pos.depositTime = uint32(block.timestamp);
        pos.lastAccrualTime = uint32(block.timestamp);
        pos.active = true;

        _emitPositionRegistered(poolId, positionKey, sender, pos, poolConfig[poolId]);

        // Baseline accrual (dt == 0): registers the opening AccrualUpdated line; accrues
        // nothing. Registration is unconditional — an out-of-range deposit still registers
        // and `_accrue` gates the delta to zero.
        _accrue(poolId, positionKey, currentTick);

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

    /// @notice Returns the per-swap dynamic LP fee; touches no position or accounting state.
    /// @dev    The fee is always DERIVED (`baseLpFeeBps + bufferBps`) and never stored, so it
    ///         cannot drift from the config. The value is OR'd with `LPFeeLibrary.OVERRIDE_FEE_FLAG`
    ///         so the PoolManager applies it for this swap; without the flag v4 would fall back to
    ///         `slot0.lpFee()`, which is 0 on a dynamic-fee pool. Both config fields are bounded at
    ///         staging (sum <= MAX_BASE_FEE_BPS + MAX_BUFFER_BPS = 15_000), well under `MAX_LP_FEE`.
    ///         No `BeforeSwapDelta` is taken (`ZERO_DELTA`): the buffer credit is notional and is
    ///         booked in `_afterSwap`, not skimmed from token flows.
    /// @param  key  Pool key; selects the immutable config to derive the fee from.
    /// @return The `beforeSwap` selector, a zero swap delta, and the override-flagged dynamic fee.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolConfig storage cfg = poolConfig[key.toId()];
        uint24 derivedFee = uint24(cfg.baseLpFeeBps + cfg.bufferBps) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, derivedFee);
    }

    /// @notice Books the buffer contribution from a swap and emits the lightweight tick update.
    /// @dev    Buffer funding ONLY — never accrues a position and never iterates the LP set
    ///         (O(N) forbidden in the swap path). The contribution is the `bufferBps` share of the
    ///         swap's stable-leg (token1, the numeraire) volume, so no price conversion is needed:
    ///           contribution = |delta.amount1()| * bufferBps / FEE_DENOM   (truncates down)
    ///         The credit is notional (no token delta taken; real backing comes from `seedBuffer()`)
    ///         and grows the buffer on EVERY swap regardless of any position's range status.
    ///         `BufferFunded` is skipped when the contribution rounds to zero (no storage write);
    ///         `TickUpdated` is emitted on every swap. The post-swap tick is read via `getSlot0`.
    /// @param  key    Pool key; selects the pool's config and buffer state.
    /// @param  delta  Swap balance delta; only the stable leg (`amount1`) is read, as a magnitude.
    /// @return The `afterSwap` selector and a zero hook delta (no token taken from the swap).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // Stable-leg volume (numeraire); FullMath guards the max-uint128 * bufferBps product.
        uint256 stableVolume = _absToUint128(delta.amount1());
        uint256 contribution = FullMath.mulDiv(stableVolume, poolConfig[poolId].bufferBps, FEE_DENOM);

        // Effects: only write when the contribution is non-zero (minimize storage writes).
        if (contribution > 0) {
            PoolState storage state = poolState[poolId];
            uint256 newBufferBalance = state.bufferBalanceStable + contribution;
            state.bufferBalanceStable = newBufferBalance;
            state.totalSkimmedStable += contribution;
            emit BufferFunded(poolId, contribution, newBufferBalance);
        }

        // Lightweight tick update for the Reactive Network, emitted on every swap.
        (, int24 newTick,,) = i_manager.getSlot0(poolId);
        emit TickUpdated(poolId, newTick, block.timestamp);

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

    /*//////////////////////////////////////////////////////////////
                                  PRIVATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Emits `PositionRegistered` from storage pointers.
    /// @dev    Isolating the 12-field emit in its own stack frame keeps `_afterAddLiquidity`
    ///         under the stack limit without via-IR. Reads the just-written snapshot and the
    ///         pool config; performs no state changes.
    /// @param  poolId       Pool the position belongs to.
    /// @param  positionKey  Position identifier within the pool.
    /// @param  owner_       Position owner (the v4 `sender` for MVP).
    /// @param  pos          The freshly written position snapshot.
    /// @param  cfg          The pool config (for coverageApr / secondsPerYear).
    function _emitPositionRegistered(
        PoolId poolId,
        bytes32 positionKey,
        address owner_,
        PositionState storage pos,
        PoolConfig storage cfg
    ) private {
        emit PositionRegistered(
            poolId,
            positionKey,
            owner_,
            pos.tickLower,
            pos.tickUpper,
            pos.entryAmt0,
            pos.entryAmt1,
            pos.entryNotionalStable,
            pos.entryTick,
            pos.depositTime,
            cfg.coverageApr,
            cfg.secondsPerYear
        );
    }

    /// @notice Returns the magnitude of a signed amount as a `uint128`.
    /// @dev    Liquidity adds yield a negative caller delta (tokens owed to the pool); the
    ///         entry snapshot records magnitudes. Widening to `int256` before negating
    ///         avoids the `type(int128).min` overflow edge; the magnitude of any `int128`
    ///         fits in `uint128`.
    /// @param  x  Signed token amount from a `BalanceDelta` leg.
    /// @return The absolute value of `x` as a `uint128`.
    function _absToUint128(int128 x) private pure returns (uint128) {
        int256 v = int256(x);
        if (v < 0) v = -v;
        return uint128(uint256(v));
    }
}
