// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook.checkpointAndEmitBackInRange() — the atomic out->in range transition
// (accrue + flip _lastRangeEventInRange to true + emit PositionBackInRange). authorizedSenderOnly,
// NOT rate-limited, leading RVM-ID placeholder. Positions are registered through the real
// afterAddLiquidity path so the alternation guard is initialized as in production. getSlot0 returns
// tick 0. Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

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

contract CheckpointAndEmitBackInRangeTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event PositionBackInRange(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 earnedCoverageStable,
        uint256 timestamp
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

    address internal constant LP = address(0x11A0);
    address internal constant NOT_PROXY = address(0xBAD);
    address internal constant INITIALIZER = address(0x1117);
    address internal constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    bytes32 internal constant SALT = bytes32(uint256(7));

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant BASE_TS = 1_000_000;
    uint32 internal constant INTERVAL = 2 minutes;
    uint128 internal constant ENTRY1 = 10_000e6;

    int24 internal constant IN_LOWER = -600;
    int24 internal constant IN_UPPER = 600;
    int24 internal constant OUT_LOWER = 120; // tick 0 below [120, 600)
    int24 internal constant OUT_UPPER = 600;

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

        vm.warp(BASE_TS);
    }

    /*//////////////////////////////////////////////////////////////
                                FIXTURES
    //////////////////////////////////////////////////////////////*/

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
        cfg.minCheckpointInterval = INTERVAL;
        cfg.admin = address(0xA11CE);
    }

    function _register(int24 lower, int24 upper) internal returns (bytes32 positionKey) {
        positionKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: SALT});
        harness.exposed_afterAddLiquidity(
            LP, poolKey, params, toBalanceDelta(0, -int128(ENTRY1)), toBalanceDelta(0, 0), ""
        );
    }

    function _expectedDelta(uint256 dt) internal pure returns (uint256) {
        return (uint256(ENTRY1) * 0.5e18 * dt) / (uint256(31_536_000) * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_CheckpointAndEmitBackInRange_WhenNotCallbackProxy_Reverts() public {
        bytes32 positionKey = _register(OUT_LOWER, OUT_UPPER); // guard false
        vm.prank(NOT_PROXY);
        vm.expectRevert(bytes("Authorized sender only"));
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                 GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_CheckpointAndEmitBackInRange_WhenPositionNotActive_Reverts() public {
        bytes32 positionKey = harness.exposed_positionKey(LP, OUT_LOWER, OUT_UPPER, SALT);
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionNotActive.selector);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
    }

    /// Why: a position registered in range has the guard initialized true, so a back-in-range call is
    /// a no-op duplicate and must revert.
    function test_CheckpointAndEmitBackInRange_WhenRegisteredInRange_RevertsAlreadyInRange() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER); // flag initialized true
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard true at registration");

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionAlreadyInRange.selector);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
    }

    /// Why: after one successful back-in transition the guard is true; a second consecutive call reverts.
    function test_CheckpointAndEmitBackInRange_WhenCalledTwice_RevertsAlreadyInRange() public {
        bytes32 positionKey = _register(OUT_LOWER, OUT_UPPER); // flag false
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard flipped to true");

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionAlreadyInRange.selector);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                          SUCCESS (ATOMIC)
    //////////////////////////////////////////////////////////////*/

    /// Why: atomic accrue (invoked even when the read tick is out of range -> zero delta) + flip + emit.
    /// The guard flips false->true and PositionBackInRange carries the post-accrual coverage.
    function test_CheckpointAndEmitBackInRange_WhenRegisteredOutOfRange_AccruesFlipsAndEmits() public {
        bytes32 positionKey = _register(OUT_LOWER, OUT_UPPER); // flag false, tick 0 out of [120,600)
        vm.warp(BASE_TS + INTERVAL);

        // _accrue runs but the read tick (0) is out of this range -> zero delta; clock still advances.
        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, positionKey, INTERVAL, 0, 0, false, BASE_TS + INTERVAL);
        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionBackInRange(poolId, positionKey, OUT_LOWER, OUT_UPPER, 0, 0, BASE_TS + INTERVAL);

        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);

        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard now in-range");
        assertEq(harness.getPosition(poolId, positionKey).lastAccrualTime, uint32(BASE_TS + INTERVAL), "clock advanced");
    }

    /// Why: not rate-limited — must succeed with zero elapsed time.
    function test_CheckpointAndEmitBackInRange_WhenZeroElapsed_StillSucceeds() public {
        bytes32 positionKey = _register(OUT_LOWER, OUT_UPPER);
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey);
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "transition recorded");
    }

    /// Why: full alternation across both transition functions — out then back — accrues on the in-range
    /// reads (tick 0 in [-600,600)) and leaves the guard back at in-range.
    function test_CheckpointAndEmitBackInRange_AfterOutThenBack_AccruesAndAlternates() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER); // flag true, tick 0 in range

        vm.warp(BASE_TS + INTERVAL);
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey); // accrues d1, flag -> false
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "out recorded");

        vm.warp(BASE_TS + 2 * INTERVAL);
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey); // accrues d1 again, flag -> true
        assertTrue(harness.exposed_lastRangeEventInRange(poolId, positionKey), "back-in recorded");

        // Per-checkpoint truncation: two INTERVAL credits at the in-range read tick.
        assertEq(
            harness.getPosition(poolId, positionKey).earnedCoverageStable,
            2 * _expectedDelta(INTERVAL),
            "accrued across both transitions"
        );
    }
}
