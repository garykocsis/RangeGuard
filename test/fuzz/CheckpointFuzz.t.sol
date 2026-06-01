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

/// @notice Fuzz coverage for `checkpoint()`: interval gating, accrual monotonicity, range gating.
contract CheckpointFuzzTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant LP = address(0x11A0);
    address internal constant INITIALIZER = address(0x1117);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant BASE_TS = 1_000_000;
    uint32 internal constant INTERVAL = 2 minutes;
    uint256 internal constant NOTIONAL = 10_000e6;

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
        pos.entryAmt1 = uint128(NOTIONAL);
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.depositTime = uint32(BASE_TS);
        pos.lastAccrualTime = uint32(BASE_TS);
        pos.active = true;
        pos.entryNotionalStable = NOTIONAL;
        pos.liquidity = 1_000_000;
        harness.seedPosition(poolId, positionKey, pos);
    }

    /// @notice Interval gate: checkpoint reverts iff elapsed < minCheckpointInterval; otherwise it
    ///         advances the clock and never reduces earned coverage (monotonicity).
    function testFuzz_Checkpoint_RespectsIntervalAndMonotonic(uint32 warpBy) public {
        warpBy = uint32(bound(warpBy, 0, 365 days));
        bytes32 positionKey = _seedActive(-600, 600); // in range at tick 0
        vm.warp(BASE_TS + warpBy);

        if (warpBy < INTERVAL) {
            vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
            harness.checkpoint(poolId, positionKey);
            return;
        }

        harness.checkpoint(poolId, positionKey);
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertGe(pos.earnedCoverageStable, 0, "coverage never negative");
        assertGt(pos.earnedCoverageStable, 0, "in-range elapsed time accrues");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + warpBy), "clock advanced to now");
    }

    /// @notice Range gate: an out-of-range position never accrues, for any elapsed time.
    function testFuzz_Checkpoint_OutOfRangeNeverAccrues(uint32 warpBy) public {
        warpBy = uint32(bound(warpBy, INTERVAL, 365 days));
        bytes32 positionKey = _seedActive(120, 600); // tick 0 sits below the range
        vm.warp(BASE_TS + warpBy);

        harness.checkpoint(poolId, positionKey);
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, positionKey);
        assertEq(pos.earnedCoverageStable, 0, "no accrual while out of range");
        assertEq(pos.lastAccrualTime, uint32(BASE_TS + warpBy), "clock still advances");
    }
}
