// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._afterAddLiquidity() (position registration + dt=0 baseline).
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().
// Inherits BaseRangeGuardTest for canonical deployment; the internal callback is reached
// via RangeGuardHookHarness (no test-only code in production).
//
// Tick note: these unit tests drive the harness directly. The pool is committed in the
// harness (so `_poolInitialized` is true and `poolConfig` is live), but the underlying
// PoolManager pool is never initialized, so `getSlot0` returns tick 0. Entry-price/tick
// variation against the real PoolManager + router is covered by the integration suite.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AfterAddLiquidityTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // Mirrors of the production events for vm.expectEmit.
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
    event AccrualUpdated(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        uint256 dt,
        uint256 delta,
        uint256 newEarnedTotal,
        bool isInRange,
        uint256 timestamp
    );

    RangeGuardHookHarness internal harness;

    // Actors / fixtures.
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;

    uint256 internal constant COVERAGE_APR = 0.5e18; // 50%
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000; // A/365F

    // Entry principal. With getSlot0 tick == 0, P_entry == 1e18, so the volatile leg maps
    // 1:1 into stable and entryNotionalStable == entryAmt1 + entryAmt0.
    uint128 internal constant ENTRY0 = 2.5e18; // token0 (volatile)
    uint128 internal constant ENTRY1 = 5_000e6; // token1 (stable)

    // In range when tickLower <= tick(0) < tickUpper.
    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;

    function setUp() public override {
        super.setUp();
        // owner == this test contract, so it can call onlyOwner setup directly.
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = COVERAGE_APR;
        cfg.secondsPerYear = SECONDS_PER_YEAR;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = ADMIN;
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
    }

    /// @dev Stage + commit a pool in the harness so `_poolInitialized` is true and the
    ///      config is live. The underlying PoolManager pool stays uninitialized (tick 0).
    function _initPool() internal returns (PoolKey memory key, PoolId poolId) {
        key = _key();
        poolId = key.toId();
        harness.stagePoolConfig(key, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    function _params(int24 tickLower, int24 tickUpper) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e18, salt: SALT});
    }

    /// @dev A liquidity add makes the caller delta negative (tokens owed to the pool).
    function _addDelta(uint128 amt0, uint128 amt1) internal pure returns (BalanceDelta) {
        return toBalanceDelta(-int128(amt0), -int128(amt1));
    }

    function _expectedKey(int24 tickLower, int24 tickUpper) internal view returns (bytes32) {
        return harness.exposed_positionKey(LP, tickLower, tickUpper, SALT);
    }

    /*//////////////////////////////////////////////////////////////
                              LIFECYCLE GUARD
    //////////////////////////////////////////////////////////////*/

    function test_AfterAddLiquidity_WhenPoolNotInitialized_Reverts() public {
        PoolKey memory key = _key(); // staged-but-not-committed path is irrelevant: never staged
        vm.expectRevert(RangeGuardHook.PoolNotInitialized.selector);
        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRATION — SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_AfterAddLiquidity_WhenValid_RegistersPosition() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, _expectedKey(TICK_LOWER, TICK_UPPER));
        assertTrue(pos.active, "position active");
        assertEq(pos.entryAmt0, ENTRY0, "entryAmt0");
        assertEq(pos.entryAmt1, ENTRY1, "entryAmt1");
        assertEq(pos.tickLower, TICK_LOWER, "tickLower");
        assertEq(pos.tickUpper, TICK_UPPER, "tickUpper");
        assertEq(pos.entryTick, 0, "entryTick (getSlot0 -> 0)");
        assertEq(pos.depositTime, uint32(START_TIME), "depositTime");
        // P_entry == 1e18 at tick 0, so notional == stable + volatile (1:1).
        assertEq(pos.entryNotionalStable, uint256(ENTRY1) + uint256(ENTRY0), "entryNotionalStable");
    }

    /// Why: afterAddLiquidity must seed `lastAccrualTime` and accrue nothing (dt == 0).
    function test_AfterAddLiquidity_WhenValid_SeedsZeroCoverageBaseline() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, _expectedKey(TICK_LOWER, TICK_UPPER));
        assertEq(pos.earnedCoverageStable, 0, "no coverage at dt=0");
        assertEq(pos.lastAccrualTime, uint32(START_TIME), "lastAccrualTime seeded to now");
        assertEq(pos.liquidity, 1e18, "liquidity snapshots params.liquidityDelta");
    }

    function test_AfterAddLiquidity_WhenValid_ReturnsSelectorAndDelta() public {
        (PoolKey memory key,) = _initPool();
        BalanceDelta delta = _addDelta(ENTRY0, ENTRY1);

        (bytes4 selector, BalanceDelta returned) =
            harness.exposed_afterAddLiquidity(LP, key, _params(TICK_LOWER, TICK_UPPER), delta, toBalanceDelta(0, 0), "");

        assertEq(selector, harness.afterAddLiquidity.selector, "returns afterAddLiquidity selector");
        assertTrue(returned == delta, "returns the unmodified caller delta");
    }

    function test_AfterAddLiquidity_WhenValid_EmitsPositionRegistered() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        vm.expectEmit(true, true, true, true, address(harness));
        emit PositionRegistered(
            poolId,
            _expectedKey(TICK_LOWER, TICK_UPPER),
            LP,
            TICK_LOWER,
            TICK_UPPER,
            ENTRY0,
            ENTRY1,
            uint256(ENTRY1) + uint256(ENTRY0),
            0, // entryTick
            uint32(START_TIME),
            COVERAGE_APR,
            SECONDS_PER_YEAR
        );
        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );
    }

    /// Why: the dt=0 baseline must emit an opening AccrualUpdated line (Pillar 4 report)
    /// with zero dt and zero delta — in range here, so isInRange == true.
    function test_AfterAddLiquidity_WhenValid_EmitsBaselineAccrualUpdated() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, _expectedKey(TICK_LOWER, TICK_UPPER), 0, 0, 0, true, START_TIME);
        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                       PRINCIPAL = DELTA - FEES
    //////////////////////////////////////////////////////////////*/

    /// Why: entry amounts record principal only; fees credited in the same delta must be
    /// netted out (principal = callerDelta - feesAccrued).
    function test_AfterAddLiquidity_WhenFeesAccrued_NetsPrincipal() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        // Caller owes ENTRY of principal but is credited some fees in the same callback.
        uint128 fee0 = 1e17;
        uint128 fee1 = 100e6;
        BalanceDelta delta = _addDelta(ENTRY0, ENTRY1); // -(principal)
        BalanceDelta fees = toBalanceDelta(int128(fee0), int128(fee1)); // +fees to caller

        harness.exposed_afterAddLiquidity(LP, key, _params(TICK_LOWER, TICK_UPPER), delta, fees, "");

        // principal = delta - fees = -(ENTRY) - (+fee) = -(ENTRY + fee) -> magnitude ENTRY + fee.
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, _expectedKey(TICK_LOWER, TICK_UPPER));
        assertEq(pos.entryAmt0, ENTRY0 + fee0, "entryAmt0 nets fees out of principal");
        assertEq(pos.entryAmt1, ENTRY1 + fee1, "entryAmt1 nets fees out of principal");
    }

    /*//////////////////////////////////////////////////////////////
                       RE-ADD GUARD (REVERTS — ONE ADD PER POSITION)
    //////////////////////////////////////////////////////////////*/

    /// Why: MVP supports a single add per position. A top-up to an already-active position must
    /// revert (not silently skip) — silently skipping would leave `pos.liquidity` desynced from
    /// the live v4 position liquidity and permanently block the full-withdrawal gate. The
    /// original snapshot must be untouched after the revert.
    function test_AfterAddLiquidity_WhenReAddedToActivePosition_Reverts() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        bytes32 posKey = _expectedKey(TICK_LOWER, TICK_UPPER);

        // Seed a distinctive active snapshot.
        RangeGuardHook.PositionState memory seeded;
        seeded.entryAmt0 = 111;
        seeded.entryAmt1 = 222;
        seeded.entryTick = 42;
        seeded.tickLower = TICK_LOWER;
        seeded.tickUpper = TICK_UPPER;
        seeded.depositTime = uint32(START_TIME - 1000);
        seeded.lastAccrualTime = uint32(START_TIME - 1000);
        seeded.active = true;
        seeded.entryNotionalStable = 999;
        seeded.earnedCoverageStable = 555;
        harness.seedPosition(poolId, posKey, seeded);

        // Re-add with completely different amounts must revert.
        vm.expectRevert(RangeGuardHook.PositionAlreadyRegistered.selector);
        harness.exposed_afterAddLiquidity(
            LP, key, _params(TICK_LOWER, TICK_UPPER), _addDelta(9e18, 9_000e6), toBalanceDelta(0, 0), ""
        );

        // Snapshot untouched after the revert.
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, posKey);
        assertEq(pos.entryAmt0, 111, "entryAmt0 unchanged");
        assertEq(pos.entryAmt1, 222, "entryAmt1 unchanged");
        assertEq(pos.entryTick, 42, "entryTick unchanged");
        assertEq(pos.depositTime, uint32(START_TIME - 1000), "depositTime unchanged");
        assertEq(pos.entryNotionalStable, 999, "notional unchanged");
        assertEq(pos.earnedCoverageStable, 555, "earned coverage unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    OUT-OF-RANGE DEPOSIT (UNCONDITIONAL)
    //////////////////////////////////////////////////////////////*/

    /// Why: registration is unconditional. A deposit out of range at entry still registers
    /// (active), and the dt=0 baseline accrues nothing with isInRange == false.
    function test_AfterAddLiquidity_WhenOutOfRangeAtDeposit_RegistersWithZeroAccrual() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        // tick 0 sits below [100, 200): out of range at deposit.
        int24 lower = 100;
        int24 upper = 200;

        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, _expectedKey(lower, upper), 0, 0, 0, false, START_TIME);
        harness.exposed_afterAddLiquidity(
            LP, key, _params(lower, upper), _addDelta(ENTRY0, ENTRY1), toBalanceDelta(0, 0), ""
        );

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, _expectedKey(lower, upper));
        assertTrue(pos.active, "out-of-range deposit still registers");
        assertEq(pos.earnedCoverageStable, 0, "no coverage out of range");
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION KEY DERIVATION
    //////////////////////////////////////////////////////////////*/

    function test_PositionKey_IsDeterministicAndInputSensitive() public view {
        bytes32 a = harness.exposed_positionKey(LP, TICK_LOWER, TICK_UPPER, SALT);
        bytes32 b = harness.exposed_positionKey(LP, TICK_LOWER, TICK_UPPER, SALT);
        assertEq(a, b, "deterministic for identical inputs");

        assertTrue(a != harness.exposed_positionKey(address(0xBEEF), TICK_LOWER, TICK_UPPER, SALT), "owner-sensitive");
        assertTrue(a != harness.exposed_positionKey(LP, TICK_LOWER + 1, TICK_UPPER, SALT), "tickLower-sensitive");
        assertTrue(a != harness.exposed_positionKey(LP, TICK_LOWER, TICK_UPPER + 1, SALT), "tickUpper-sensitive");
        assertTrue(a != harness.exposed_positionKey(LP, TICK_LOWER, TICK_UPPER, bytes32(uint256(8))), "salt-sensitive");
    }
}
