// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Property-based fuzz tests for RangeGuardHook._accrue().
// Follows testing-strategy.md naming: testFuzz_Function_Property().
// These assert protocol PROPERTIES that must hold across randomized inputs, rather
// than fixed scenarios (which live in test/unit/Accrue.t.sol). Inherits
// BaseRangeGuardTest for canonical deployment; reaches the internal function via the
// shared RangeGuardHookHarness.

import {PoolId} from "v4-core/types/PoolId.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AccrueFuzzTest is BaseRangeGuardTest {
    RangeGuardHookHarness internal harness;

    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));
    bytes32 internal constant KEY_A = keccak256("position-A");
    bytes32 internal constant KEY_B = keccak256("position-B");

    uint256 internal constant START_TIME = 1_000_000;

    uint256 internal constant COVERAGE_APR = 0.5e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant MAX_MULTIPLE = 3e18;

    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;
    int24 internal constant TICK_IN = 0;

    // Bounds chosen so notional * apr * dt cannot overflow uint256:
    // 1e33 * 0.5e18 * (80yr ~ 2.52e9) ~= 1.3e60 << 1.15e77.
    uint256 internal constant MAX_NOTIONAL = 1e33;
    uint256 internal constant MAX_DT = 80 * SECONDS_PER_YEAR;
    uint256 internal constant MAX_APR = 0.5e18; // MAX_COVERAGE_APR

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager());
        harness.seedConfig(POOL_ID, _config(COVERAGE_APR, MAX_MULTIPLE));
        vm.warp(START_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _config(uint256 apr, uint256 multiple) internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = apr;
        cfg.secondsPerYear = SECONDS_PER_YEAR;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = multiple;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = address(0xA11CE);
    }

    function _seed(bytes32 key, uint256 notional, bool active) internal {
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = 1e18;
        pos.entryAmt1 = 1e6;
        pos.entryTick = TICK_IN;
        pos.tickLower = TICK_LOWER;
        pos.tickUpper = TICK_UPPER;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = active;
        pos.entryNotionalStable = notional;
        pos.earnedCoverageStable = 0;
        pos.pendingPayout = 0;
        harness.seedPosition(POOL_ID, key, pos);
    }

    function _earned(bytes32 key) internal view returns (uint256) {
        return harness.getPosition(POOL_ID, key).earnedCoverageStable;
    }

    /*//////////////////////////////////////////////////////////////
                                  PROPERTIES
    //////////////////////////////////////////////////////////////*/

    /// Proves: zero dt always yields zero accrual and never advances the clock, for any
    /// notional/APR (invariant: "zero dt must always produce zero accrual delta").
    function testFuzz_Accrue_ZeroDtProducesNoAccrual(uint256 notional, uint256 apr) public {
        notional = bound(notional, 0, MAX_NOTIONAL);
        apr = bound(apr, 1, MAX_APR);
        harness.seedConfig(POOL_ID, _config(apr, MAX_MULTIPLE));
        _seed(KEY_A, notional, true);

        // No warp: block.timestamp == lastAccrualTime, so dt == 0.
        harness.exposed_accrue(POOL_ID, KEY_A, TICK_IN);

        assertEq(_earned(KEY_A), 0, "zero dt must not accrue");
        assertEq(harness.getPosition(POOL_ID, KEY_A).lastAccrualTime, uint32(START_TIME), "clock unchanged");
    }

    /// Proves: inactive positions never accrue, regardless of elapsed time or tick
    /// (invariant: "inactive positions must never accrue coverage").
    function testFuzz_Accrue_InactiveNeverAccrues(uint256 dt, int24 tick) public {
        dt = bound(dt, 0, MAX_DT);
        _seed(KEY_A, MAX_NOTIONAL, false);

        vm.warp(START_TIME + dt);
        harness.exposed_accrue(POOL_ID, KEY_A, tick);

        assertEq(_earned(KEY_A), 0, "inactive must never accrue");
    }

    /// Proves: out-of-range accrual is always zero, but the clock still advances when
    /// time elapsed (invariants: "out-of-range checkpoints produce zero accrual delta",
    /// "earnedCoverageStable remains unchanged while out of range").
    function testFuzz_Accrue_OutOfRangeProducesZero(uint256 dt, int24 tick) public {
        dt = bound(dt, 1, MAX_DT);
        vm.assume(tick < TICK_LOWER || tick >= TICK_UPPER); // strictly out of range
        _seed(KEY_A, MAX_NOTIONAL, true);

        vm.warp(START_TIME + dt);
        harness.exposed_accrue(POOL_ID, KEY_A, tick);

        assertEq(_earned(KEY_A), 0, "out of range must accrue zero");
        assertEq(harness.getPosition(POOL_ID, KEY_A).lastAccrualTime, uint32(START_TIME + dt), "clock advances");
    }

    /// Proves: earned coverage can never exceed the configured ceiling (cap = notional *
    /// multiple), for any elapsed time (invariant: "never exceed the accrual ceiling").
    function testFuzz_Accrue_NeverExceedsCeiling(uint256 notional, uint256 dt) public {
        notional = bound(notional, 0, MAX_NOTIONAL);
        dt = bound(dt, 0, MAX_DT);
        _seed(KEY_A, notional, true);

        vm.warp(START_TIME + dt);
        harness.exposed_accrue(POOL_ID, KEY_A, TICK_IN);

        uint256 cap = notional * MAX_MULTIPLE / 1e18;
        assertLe(_earned(KEY_A), cap, "earned must never exceed ceiling");
    }

    /// Proves: accrual is monotonic in notional — a larger entry notional never produces
    /// less coverage under identical config, range, and elapsed time.
    function testFuzz_Accrue_LargerNotionalProducesMoreCoverage(uint256 nA, uint256 nB, uint256 dt) public {
        nA = bound(nA, 0, MAX_NOTIONAL);
        nB = bound(nB, nA, MAX_NOTIONAL); // nB >= nA
        dt = bound(dt, 1, MAX_DT);

        _seed(KEY_A, nA, true);
        _seed(KEY_B, nB, true);

        vm.warp(START_TIME + dt);
        harness.exposed_accrue(POOL_ID, KEY_A, TICK_IN);
        harness.exposed_accrue(POOL_ID, KEY_B, TICK_IN);

        assertGe(_earned(KEY_B), _earned(KEY_A), "larger notional => >= coverage");
    }

    /// Proves: accrual is monotonic in time — a longer in-range duration never produces
    /// less coverage under identical config and notional.
    function testFuzz_Accrue_LongerDurationProducesMoreCoverage(uint256 dt1, uint256 dt2) public {
        dt1 = bound(dt1, 1, MAX_DT);
        dt2 = bound(dt2, dt1, MAX_DT); // dt2 >= dt1

        _seed(KEY_A, MAX_NOTIONAL, true);
        _seed(KEY_B, MAX_NOTIONAL, true);

        vm.warp(START_TIME + dt1);
        harness.exposed_accrue(POOL_ID, KEY_A, TICK_IN);

        vm.warp(START_TIME + dt2);
        harness.exposed_accrue(POOL_ID, KEY_B, TICK_IN);

        assertGe(_earned(KEY_B), _earned(KEY_A), "longer duration => >= coverage");
    }

    /// Proves: across two sequential accruals with arbitrary ticks and timing, earned
    /// coverage never decreases and the clock never rewinds (invariants:
    /// "earnedCoverageStable never decreases", "lastAccrualTime monotonically increases").
    function testFuzz_Accrue_CoverageNeverDecreases(uint256 dt1, uint256 dt2, int24 t1, int24 t2) public {
        dt1 = bound(dt1, 1, MAX_DT / 2);
        dt2 = bound(dt2, 1, MAX_DT / 2);
        _seed(KEY_A, MAX_NOTIONAL, true);

        vm.warp(START_TIME + dt1);
        harness.exposed_accrue(POOL_ID, KEY_A, t1);
        uint256 earnedAfter1 = _earned(KEY_A);
        uint32 clockAfter1 = harness.getPosition(POOL_ID, KEY_A).lastAccrualTime;

        vm.warp(START_TIME + dt1 + dt2);
        harness.exposed_accrue(POOL_ID, KEY_A, t2);
        uint256 earnedAfter2 = _earned(KEY_A);
        uint32 clockAfter2 = harness.getPosition(POOL_ID, KEY_A).lastAccrualTime;

        assertGe(earnedAfter2, earnedAfter1, "coverage must never decrease");
        assertGe(clockAfter2, clockAfter1, "clock must never rewind");
    }

    /// Proves: accrual never mutates the immutable entry snapshot, for any time or tick
    /// (invariant: "accrual must never modify entry position snapshots").
    function testFuzz_Accrue_EntrySnapshotImmutable(uint256 dt, int24 tick) public {
        dt = bound(dt, 0, MAX_DT);
        _seed(KEY_A, MAX_NOTIONAL, true);
        RangeGuardHook.PositionState memory before = harness.getPosition(POOL_ID, KEY_A);

        vm.warp(START_TIME + dt);
        harness.exposed_accrue(POOL_ID, KEY_A, tick);
        RangeGuardHook.PositionState memory afterPos = harness.getPosition(POOL_ID, KEY_A);

        assertEq(afterPos.entryAmt0, before.entryAmt0, "entryAmt0 immutable");
        assertEq(afterPos.entryAmt1, before.entryAmt1, "entryAmt1 immutable");
        assertEq(afterPos.entryTick, before.entryTick, "entryTick immutable");
        assertEq(afterPos.tickLower, before.tickLower, "tickLower immutable");
        assertEq(afterPos.tickUpper, before.tickUpper, "tickUpper immutable");
        assertEq(afterPos.depositTime, before.depositTime, "depositTime immutable");
        assertEq(afterPos.entryNotionalStable, before.entryNotionalStable, "entryNotional immutable");
    }
}
