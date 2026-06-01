// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

/// @notice Unit coverage for `checkpoint()` — the permissionless, accrual-only Reactive entry point.
/// @dev    Driven directly against the harness. The pool's hook-side `_poolInitialized` flag is set
///         through the real stage+commit flow, but the underlying PoolManager pool is never
///         initialized, so `getSlot0` returns tick 0. In-range vs out-of-range is therefore
///         controlled purely by the seeded tick bounds relative to 0.
contract CheckpointTest is BaseRangeGuardTest {
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
    address internal constant KEEPER = address(0xCAFE); // arbitrary permissionless caller
    address internal constant INITIALIZER = address(0x1117);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant BASE_TS = 1_000_000;
    uint32 internal constant INTERVAL = 2 minutes; // matches _cfg().minCheckpointInterval
    uint256 internal constant NOTIONAL = 10_000e6;

    // In-range bounds (0 in range) vs out-of-range bounds (0 below range).
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

        // Real stage + commit so the hook-side _poolInitialized flag is set.
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

    /// @dev Seeds an active position with the given range and a `lastAccrualTime` of `BASE_TS`.
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

    /// @dev Mirrors the production accrual math for the in-range delta assertion.
    function _expectedDelta(uint256 dt) internal pure returns (uint256) {
        return (NOTIONAL * 0.5e18 * dt) / (uint256(31_536_000) * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                 REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_Checkpoint_WhenPoolNotInitialized_Reverts() public {
        // A pool that was never staged/committed in the hook.
        PoolKey memory altKey = poolKey;
        altKey.currency0 = Currency.wrap(address(0x9999));
        bytes32 positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, bytes32(0));

        vm.expectRevert(RangeGuardHook.PoolNotInitialized.selector);
        harness.checkpoint(altKey.toId(), positionKey);
    }

    function test_Checkpoint_WhenPositionNotActive_Reverts() public {
        bytes32 positionKey = harness.exposed_positionKey(LP, IN_LOWER, IN_UPPER, bytes32(0));
        vm.expectRevert(RangeGuardHook.PositionNotActive.selector);
        harness.checkpoint(poolId, positionKey);
    }

    function test_Checkpoint_WhenIntervalNotElapsed_RevertsCheckpointTooSoon() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL - 1); // one second short of the interval
        vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
        harness.checkpoint(poolId, positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                 SUCCESS
    //////////////////////////////////////////////////////////////*/

    /// Why: the interval gate is `>=`, so exactly `INTERVAL` elapsed must be accepted.
    function test_Checkpoint_WhenExactlyAtInterval_Succeeds() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL);
        harness.checkpoint(poolId, positionKey);
        assertEq(harness.getPosition(poolId, positionKey).lastAccrualTime, uint32(BASE_TS + INTERVAL));
    }

    function test_Checkpoint_WhenInRange_AccruesAndEmitsCheckpointed() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        uint256 dt = INTERVAL;
        vm.warp(BASE_TS + dt);

        // AccrualUpdated (from _accrue) then Checkpointed, both with the live values.
        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(poolId, positionKey, dt, _expectedDelta(dt), _expectedDelta(dt), true, BASE_TS + dt);
        vm.expectEmit(true, true, false, true, address(harness));
        emit Checkpointed(poolId, positionKey, BASE_TS + dt);

        harness.checkpoint(poolId, positionKey);

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertEq(pos.earnedCoverageStable, _expectedDelta(dt), "earned == expected accrual");
        assertGt(pos.earnedCoverageStable, 0, "accrued a non-zero amount");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + dt), "accrual clock advanced");
    }

    /// Why: out-of-range checkpoints must produce zero accrual delta but still advance the clock,
    /// so paused seconds are consumed and never retroactively earn.
    function test_Checkpoint_WhenOutOfRange_AdvancesClockZeroDelta() public {
        bytes32 positionKey = _seedActive(OUT_LOWER, OUT_UPPER); // tick 0 is below [120, 600)
        vm.warp(BASE_TS + INTERVAL);

        harness.checkpoint(poolId, positionKey);

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertEq(pos.earnedCoverageStable, 0, "no accrual out of range");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + INTERVAL), "clock still advances");
    }

    /// Why: checkpoint is permissionless — any address may drive accrual for an active position.
    function test_Checkpoint_WhenPermissionlessCaller_Succeeds() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);
        vm.warp(BASE_TS + INTERVAL);

        vm.prank(KEEPER);
        harness.checkpoint(poolId, positionKey);

        assertEq(harness.getPosition(poolId, positionKey).earnedCoverageStable, _expectedDelta(INTERVAL));
    }

    /// Why: after a successful checkpoint the clock resets, so an immediate second call must respect
    /// the interval again (rate limit is relative to lastAccrualTime, not depositTime).
    function test_Checkpoint_WhenCalledTwice_SecondRespectsInterval() public {
        bytes32 positionKey = _seedActive(IN_LOWER, IN_UPPER);

        vm.warp(BASE_TS + INTERVAL);
        harness.checkpoint(poolId, positionKey);

        // Immediately after: dt == 0 < INTERVAL -> too soon.
        vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
        harness.checkpoint(poolId, positionKey);

        // Another full interval later succeeds and accrues again. Each checkpoint truncates its
        // own interval independently, so the cumulative is 2 * delta(INTERVAL), which can differ
        // by rounding from a single delta(2 * INTERVAL) — the expected lazy-accrual behavior.
        vm.warp(BASE_TS + 2 * INTERVAL);
        harness.checkpoint(poolId, positionKey);
        assertEq(
            harness.getPosition(poolId, positionKey).earnedCoverageStable,
            2 * _expectedDelta(INTERVAL),
            "cumulative accrual over both intervals (per-checkpoint truncation)"
        );
    }
}
