// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title AccrueHandler
/// @notice Invariant-test handler that drives RangeGuardHook._accrue() with randomized
///         ticks and monotonically-advancing time across three positions:
///           - MAIN:     active, range-capable (exercises accrual, ceiling, clock).
///           - INACTIVE: active == false (must never accrue).
///           - OOR:      active but only ever touched with out-of-range ticks.
/// @dev    Maintains high-water ghost variables so the invariant suite can detect any
///         decrease in earned coverage or any rewind of the accrual clock. All inputs
///         are bounded so the handler never reverts and time never overflows uint32.
contract AccrueHandler is Test {
    RangeGuardHookHarness public immutable harness;

    PoolId public constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));
    bytes32 public constant KEY_MAIN = keccak256("inv-main");
    bytes32 public constant KEY_INACTIVE = keccak256("inv-inactive");
    bytes32 public constant KEY_OOR = keccak256("inv-oor");

    uint256 public constant START_TIME = 1_000_000;
    uint256 public constant COVERAGE_APR = 0.5e18;
    uint256 public constant SECONDS_PER_YEAR = 31_536_000;
    uint256 public constant MAX_MULTIPLE = 3e18;
    uint256 public constant NOTIONAL = 10_000e6;
    uint256 public constant CAP = NOTIONAL * MAX_MULTIPLE / 1e18; // 30,000e6

    int24 public constant TICK_LOWER = -100;
    int24 public constant TICK_UPPER = 100;
    int24 internal constant OOR_TICK = 1_000_000; // always above range

    uint256 internal constant MAX_TIME_JUMP = 60 days;

    // Ghosts.
    uint256 public time; // current simulated timestamp (monotonic)
    uint256 public ghost_earnedHighWater; // max MAIN earned ever observed
    uint256 public ghost_clockHighWater; // max MAIN lastAccrualTime ever observed
    uint256 public ghost_calls; // number of executed accrue rounds

    // Immutable entry snapshot baseline for MAIN.
    RangeGuardHook.PositionState internal _mainBaseline;

    constructor(RangeGuardHookHarness _harness) {
        harness = _harness;
        time = START_TIME;
        vm.warp(START_TIME);

        harness.seedConfig(POOL_ID, _config());
        harness.seedPosition(POOL_ID, KEY_MAIN, _position(true, NOTIONAL));
        harness.seedPosition(POOL_ID, KEY_INACTIVE, _position(false, NOTIONAL));
        harness.seedPosition(POOL_ID, KEY_OOR, _position(true, NOTIONAL));

        _mainBaseline = harness.getPosition(POOL_ID, KEY_MAIN);
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = COVERAGE_APR;
        cfg.secondsPerYear = SECONDS_PER_YEAR;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = MAX_MULTIPLE;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = address(0xA11CE);
    }

    function _position(bool active, uint256 notional) internal pure returns (RangeGuardHook.PositionState memory pos) {
        pos.entryAmt0 = 2.5e18;
        pos.entryAmt1 = 5_000e6;
        pos.entryTick = 0;
        pos.tickLower = TICK_LOWER;
        pos.tickUpper = TICK_UPPER;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = active;
        pos.entryNotionalStable = notional;
        pos.earnedCoverageStable = 0;
    }

    /// @notice The single fuzzed action: advance time, then accrue all three positions.
    /// @param tickSeed  Seed mapped to a tick spanning both in- and out-of-range values.
    /// @param timeJump  Forward time delta (bounded, keeps the clock monotonic).
    function accrue(uint256 tickSeed, uint256 timeJump) external {
        timeJump = bound(timeJump, 0, MAX_TIME_JUMP);
        time += timeJump;
        vm.warp(time);

        // tick in [-200, 199): straddles the [-100, 100) range (in and out).
        int24 tick = int24(int256(bound(tickSeed, 0, 399)) - 200);

        harness.exposed_accrue(POOL_ID, KEY_MAIN, tick);
        harness.exposed_accrue(POOL_ID, KEY_INACTIVE, tick);
        harness.exposed_accrue(POOL_ID, KEY_OOR, OOR_TICK);

        RangeGuardHook.PositionState memory main = harness.getPosition(POOL_ID, KEY_MAIN);
        if (main.earnedCoverageStable > ghost_earnedHighWater) {
            ghost_earnedHighWater = main.earnedCoverageStable;
        }
        if (main.lastAccrualTime > ghost_clockHighWater) {
            ghost_clockHighWater = main.lastAccrualTime;
        }
        ghost_calls++;
    }

    function mainBaseline() external view returns (RangeGuardHook.PositionState memory) {
        return _mainBaseline;
    }
}
