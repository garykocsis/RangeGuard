// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook.checkpointAndEmitOutOfRange() — the atomic in->out range transition
// (accrue + flip _lastRangeEventInRange to false + emit PositionOutOfRange). authorizedSenderOnly,
// NOT rate-limited, with a leading RVM-ID placeholder. Positions are registered through the real
// afterAddLiquidity path so the alternation guard (_lastRangeEventInRange) is initialized exactly as
// in production. getSlot0 returns tick 0 (pool never PoolManager-initialized).
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

contract CheckpointAndEmitOutOfRangeTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event PositionOutOfRange(
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
    uint128 internal constant ENTRY1 = 10_000e6; // pure-stable deposit -> notional == ENTRY1

    // In range at tick 0; out of range at tick 0 (tick 0 below [120, 600)).
    int24 internal constant IN_LOWER = -600;
    int24 internal constant IN_UPPER = 600;
    int24 internal constant OUT_LOWER = 120;
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

    /// @dev Registers a position via the real afterAddLiquidity path so _lastRangeEventInRange is
    ///      initialized from the entry tick (0). Pure-stable deposit -> entryNotionalStable == ENTRY1.
    function _register(int24 lower, int24 upper) internal returns (bytes32 positionKey) {
        positionKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e18, salt: SALT});
        BalanceDelta delta = toBalanceDelta(0, -int128(ENTRY1)); // add: caller delta negative
        harness.exposed_afterAddLiquidity(LP, poolKey, params, delta, toBalanceDelta(0, 0), "");
    }

    function _expectedDelta(uint256 dt) internal pure returns (uint256) {
        return (uint256(ENTRY1) * 0.5e18 * dt) / (uint256(31_536_000) * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_CheckpointAndEmitOutOfRange_WhenNotCallbackProxy_Reverts() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER);
        vm.prank(NOT_PROXY);
        vm.expectRevert(bytes("Authorized sender only"));
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                 GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_CheckpointAndEmitOutOfRange_WhenPositionNotActive_Reverts() public {
        bytes32 positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, SALT); // never registered
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionNotActive.selector);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
    }

    /// Why: a position registered already out of range has the guard initialized false, so the first
    /// out-of-range call is a no-op duplicate and must revert.
    function test_CheckpointAndEmitOutOfRange_WhenRegisteredOutOfRange_RevertsAlreadyOutOfRange() public {
        bytes32 positionKey = _register(OUT_LOWER, OUT_UPPER); // flag initialized false
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard false at registration");

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionAlreadyOutOfRange.selector);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
    }

    /// Why: after one successful out-of-range transition the guard is false; a second consecutive call
    /// must revert (alternation guard), independent of the Reactive contract's own state.
    function test_CheckpointAndEmitOutOfRange_WhenCalledTwice_RevertsAlreadyOutOfRange() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER); // flag true
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard flipped to false");

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionAlreadyOutOfRange.selector);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                          SUCCESS (ATOMIC)
    //////////////////////////////////////////////////////////////*/

    /// Why: atomic accrue + flip + emit. In range for `INTERVAL` then transition out: accrual runs
    /// (AccrualUpdated), the guard flips to false, and PositionOutOfRange carries post-accrual coverage.
    function test_CheckpointAndEmitOutOfRange_WhenInRange_AccruesFlipsAndEmits() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER);
        uint256 dt = INTERVAL;
        vm.warp(BASE_TS + dt);

        // tick 0 is in [IN_LOWER, IN_UPPER), so _accrue credits the interval; not rate-limited.
        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, positionKey, dt, _expectedDelta(dt), _expectedDelta(dt), true, BASE_TS + dt);
        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionOutOfRange(poolId, positionKey, IN_LOWER, IN_UPPER, 0, _expectedDelta(dt), BASE_TS + dt);

        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);

        assertEq(
            harness.getPosition(poolId, positionKey).earnedCoverageStable, _expectedDelta(dt), "accrual ran atomically"
        );
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "guard now out-of-range");
    }

    /// Why: not rate-limited — must succeed even with zero elapsed time since the last accrual.
    function test_CheckpointAndEmitOutOfRange_WhenZeroElapsed_StillSucceeds() public {
        bytes32 positionKey = _register(IN_LOWER, IN_UPPER); // lastAccrualTime == BASE_TS
        // No warp: dt == 0, far below INTERVAL — a rate-limited fn would revert; this one must not.
        vm.prank(CALLBACK_PROXY);
        harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey);
        assertFalse(harness.exposed_lastRangeEventInRange(poolId, positionKey), "transition recorded");
    }
}
