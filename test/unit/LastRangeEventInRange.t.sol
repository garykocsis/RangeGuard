// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for the _lastRangeEventInRange alternation guard initialization in afterAddLiquidity.
// The guard seeds from the entry tick vs the half-open range [tickLower, tickUpper): in range -> true,
// out of range (below or above) -> false. This must mirror the Reactive contract's lastKnownInRange
// init so the first transition fires with the correct polarity. getSlot0 returns tick 0 (pool never
// PoolManager-initialized), so range placement relative to 0 selects the deposit case.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

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

contract LastRangeEventInRangeTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1

    uint128 internal constant ENTRY0 = 2.5e18;
    uint128 internal constant ENTRY1 = 5_000e6;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();
        harness.stagePoolConfig(poolKey, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = address(0xA11CE);
    }

    function _register(int24 lower, int24 upper) internal returns (bytes32 positionKey) {
        positionKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: SALT});
        harness.exposed_afterAddLiquidity(
            LP, poolKey, params, toBalanceDelta(-int128(ENTRY0), -int128(ENTRY1)), toBalanceDelta(0, 0), ""
        );
    }

    /// Case A: entry tick below range (100% token0 deposit) -> out of range -> guard false.
    function test_AfterAddLiquidity_WhenEntryBelowRange_GuardFalse() public {
        bytes32 positionKey = _register(100, 200); // tick 0 < 100
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "below range -> false");
    }

    /// Case B: entry tick in range (mixed deposit) -> in range -> guard true.
    function test_AfterAddLiquidity_WhenEntryInRange_GuardTrue() public {
        bytes32 positionKey = _register(-100, 100); // -100 <= 0 < 100
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "in range -> true");
    }

    /// Case C: entry tick above range (100% token1 deposit) -> out of range -> guard false.
    function test_AfterAddLiquidity_WhenEntryAboveRange_GuardFalse() public {
        bytes32 positionKey = _register(-200, -100); // tick 0 >= -100 (upper)
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "above range -> false");
    }

    /// Why: range is half-open [lower, upper). tick == lower is IN range (>= lower).
    function test_AfterAddLiquidity_WhenEntryEqualsLower_GuardTrue() public {
        bytes32 positionKey = _register(0, 100); // 0 >= 0 (lower) && 0 < 100
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "tick == lower is in range");
    }

    /// Why: range is half-open [lower, upper). tick == upper is OUT of range (< upper is false).
    function test_AfterAddLiquidity_WhenEntryEqualsUpper_GuardFalse() public {
        bytes32 positionKey = _register(-100, 0); // 0 == upper -> out
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "tick == upper is out of range");
    }
}
