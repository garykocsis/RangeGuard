// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for the _lastRangeEventInRange alternation guard under arbitrary sequences of
// out-of-range / back-in-range calls. The guard must alternate strictly: an out call is only valid
// when currently in-range, an in call only when currently out-of-range; a duplicate consecutive call
// reverts and leaves the guard unchanged. A local model mirrors the expected guard state and is
// checked after every step. Naming per testing-strategy.md: testFuzz_*.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract RangeEventGuardFuzzTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant LP = address(0x11A0);
    address internal constant INITIALIZER = address(0x1117);
    address internal constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    bytes32 internal constant SALT = bytes32(uint256(7));

    PoolKey internal poolKey;
    PoolId internal poolId;

    int24 internal constant IN_LOWER = -600; // tick 0 in range -> registers with guard true
    int24 internal constant IN_UPPER = 600;

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
        harness.stagePoolConfig(poolKey, _cfg(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);
    }

    function _cfg() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
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

    function _register() internal returns (bytes32 positionKey) {
        positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: IN_LOWER, tickUpper: IN_UPPER, liquidityDelta: 1e18, salt: SALT});
        harness.exposed_afterAddLiquidity(
            LP, poolKey, params, toBalanceDelta(0, -int128(10_000e6)), toBalanceDelta(0, 0), ""
        );
    }

    /// Why: across any sequence of attempted out/in transitions, the on-chain guard must always equal
    /// the strict-alternation model, and duplicate calls must revert without mutating the guard.
    function testFuzz_RangeEventGuard_AlternatesUnderArbitrarySequence(uint256 seed) public {
        bytes32 positionKey = _register();
        bool modelInRange = true; // in-range registration
        assertEq(harness.exposed_lastRangeEventInRange(poolId, positionKey), modelInRange, "init matches model");

        // Walk 64 bits of the seed; bit == 1 -> attempt out, bit == 0 -> attempt back-in.
        for (uint256 i = 0; i < 64; i++) {
            bool attemptOut = (seed >> i) & 1 == 1;

            if (attemptOut) {
                if (modelInRange) {
                    vm.prank(CALLBACK_PROXY);
                    harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
                    modelInRange = false;
                } else {
                    vm.prank(CALLBACK_PROXY);
                    vm.expectRevert(RangeGuardHook.PositionAlreadyOutOfRange.selector);
                    harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
                }
            } else {
                if (!modelInRange) {
                    vm.prank(CALLBACK_PROXY);
                    harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
                    modelInRange = true;
                } else {
                    vm.prank(CALLBACK_PROXY);
                    vm.expectRevert(RangeGuardHook.PositionAlreadyInRange.selector);
                    harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
                }
            }

            assertEq(
                harness.exposed_lastRangeEventInRange(poolId, positionKey),
                modelInRange,
                "guard tracks strict-alternation model"
            );
        }
    }

    /// Why: regardless of how the entry tick sits relative to the range, the guard initializes to the
    /// exact in-range predicate [tickLower, tickUpper) and never to an inconsistent value.
    function testFuzz_RangeEventGuard_InitMatchesEntryPredicate(int24 lower, int24 width) public {
        // Bound to a safe, ordered, non-empty range around tick 0's neighborhood.
        lower = int24(bound(int256(lower), -500, 500));
        int24 w = int24(bound(int256(width), 1, 500));
        int24 upper = lower + w;

        bytes32 positionKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: SALT});
        harness.exposed_afterAddLiquidity(
            LP, poolKey, params, toBalanceDelta(0, -int128(10_000e6)), toBalanceDelta(0, 0), ""
        );

        // Entry tick is 0 (getSlot0 on the uninitialized PoolManager pool).
        bool expected = (int24(0) >= lower && int24(0) < upper);
        assertEq(harness.exposed_lastRangeEventInRange(poolId, positionKey), expected, "guard == in-range predicate");
    }
}
