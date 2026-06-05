// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook.checkpointCallback() — the Reactive-Network heartbeat accrual
// entry point. Mirrors checkpoint() (same gates/effects) but is gated to the Callback Proxy via
// `authorizedSenderOnly` and carries a leading RVM-ID placeholder `address` that must be ignored.
// Driven directly against the harness; the underlying PoolManager pool is never initialized, so
// getSlot0 returns tick 0 and in/out-of-range is controlled by the seeded tick bounds vs 0.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract CheckpointCallbackTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event Checkpointed(PoolId indexed poolId, bytes32 indexed positionKey, uint256 timestamp);
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
    address internal constant NOT_PROXY = address(0xBAD); // any non-Callback-Proxy caller
    address internal constant INITIALIZER = address(0x1117);
    // Callback Proxy injected by the harness as the hook's `_callbackSender`.
    address internal constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant BASE_TS = 1_000_000;
    uint32 internal constant INTERVAL = 2 minutes; // matches _cfg().minCheckpointInterval
    uint256 internal constant NOTIONAL = 10_000e6;

    int24 internal constant IN_LOWER = -600;
    int24 internal constant IN_UPPER = 600;
    int24 internal constant OUT_LOWER = 120; // tick 0 sits below [120, 600)
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

    function _seedActive(int24 tickLower, int24 tickUpper) internal returns (bytes32 positionKey) {
        positionKey = harness.exposed_positionKey(LP, tickLower, tickUpper, bytes32(0));
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = 5 ether;
        pos.entryAmt1 = uint128(NOTIONAL);
        pos.entryTick = 0;
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.depositTime = uint32(BASE_TS);
        pos.lastAccrualTime = uint32(BASE_TS);
        pos.active = true;
        pos.entryNotionalStable = NOTIONAL;
        pos.earnedCoverageStable = 0;
        pos.liquidity = 1_000_000;
        harness.seedPosition(poolId, positionKey, pos);
    }

    function _expectedDelta(uint256 dt) internal pure returns (uint256) {
        return (NOTIONAL * 0.5e18 * dt) / (uint256(31_536_000) * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// Why: authorizedSenderOnly — only the Callback Proxy may drive the heartbeat accrual.
    function test_CheckpointCallback_WhenNotCallbackProxy_Reverts() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL);

        vm.prank(NOT_PROXY);
        vm.expectRevert(bytes("Authorized sender only"));
        harness.checkpointCallback(address(0), poolId, positionKey);
    }

    /// Why: the leading address is an ignored RVM-ID placeholder; a junk value must not change behavior.
    function test_CheckpointCallback_WhenSenderParamNonZero_Ignored() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL);

        vm.prank(CALLBACK_PROXY);
        harness.checkpointCallback(address(0xDEADBEEF), poolId, positionKey);

        assertEq(harness.getPosition(poolId, positionKey).earnedCoverageStable, _expectedDelta(INTERVAL));
    }

    /*//////////////////////////////////////////////////////////////
                                 GATES
    //////////////////////////////////////////////////////////////*/

    function test_CheckpointCallback_WhenPoolNotInitialized_Reverts() public {
        PoolKey memory altKey = poolKey;
        altKey.currency0 = Currency.wrap(address(0x9999));
        bytes32 positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, bytes32(0));

        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PoolNotInitialized.selector);
        harness.checkpointCallback(address(0), altKey.toId(), positionKey);
    }

    function test_CheckpointCallback_WhenPositionNotActive_Reverts() public {
        bytes32 positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, bytes32(0));
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.PositionNotActive.selector);
        harness.checkpointCallback(address(0), poolId, positionKey);
    }

    function test_CheckpointCallback_WhenIntervalNotElapsed_RevertsCheckpointTooSoon() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL - 1);
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
        harness.checkpointCallback(address(0), poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                 SUCCESS
    //////////////////////////////////////////////////////////////*/

    /// Why: the interval gate is `>=`, so exactly `INTERVAL` elapsed must be accepted.
    function test_CheckpointCallback_WhenExactlyAtInterval_Succeeds() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL);
        vm.prank(CALLBACK_PROXY);
        harness.checkpointCallback(address(0), poolId, positionKey);
        assertEq(harness.getPosition(poolId, positionKey).lastAccrualTime, uint32(BASE_TS + INTERVAL));
    }

    function test_CheckpointCallback_WhenInRange_AccruesAndEmitsCheckpointed() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        uint256 dt = INTERVAL;
        vm.warp(BASE_TS + dt);

        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, positionKey, dt, _expectedDelta(dt), _expectedDelta(dt), true, BASE_TS + dt);
        vm.expectEmit(true, true, false, true, address(harness));
        emit Checkpointed(poolId, positionKey, BASE_TS + dt);

        vm.prank(CALLBACK_PROXY);
        harness.checkpointCallback(address(0), poolId, positionKey);

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertEq(pos.earnedCoverageStable, _expectedDelta(dt), "earned == expected accrual");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + dt), "accrual clock advanced");
    }

    /// Why: out-of-range heartbeat must produce zero accrual delta but still advance the clock.
    function test_CheckpointCallback_WhenOutOfRange_AdvancesClockZeroDelta() public {
        bytes32 positionKey = _seedActive(OUT_LOWER, OUT_UPPER);
        vm.warp(BASE_TS + INTERVAL);

        vm.prank(CALLBACK_PROXY);
        harness.checkpointCallback(address(0), poolId, positionKey);

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertEq(pos.earnedCoverageStable, 0, "no accrual out of range");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + INTERVAL), "clock still advances");
    }
}
