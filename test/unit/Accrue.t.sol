// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._accrue() and its shared pure helper _accrueEarned().
// Follows testing-strategy.md naming: test_Function_WhenCondition_ExpectedBehavior().
// Inherits BaseRangeGuardTest for canonical deployment; the internal function is
// reached via the dedicated RangeGuardHookHarness (no test-only code in production).

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AccrueTest is BaseRangeGuardTest {
    // Mirror of the production event, redeclared for vm.expectEmit.
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

    // Canonical fixtures.
    PoolId internal constant POOL_ID = PoolId.wrap(bytes32(uint256(1)));
    bytes32 internal constant KEY = keccak256("position-1");

    uint256 internal constant START_TIME = 1_000_000;

    // Demo config values.
    uint256 internal constant COVERAGE_APR = 0.5e18; // 50%
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000; // A/365F
    uint256 internal constant MAX_MULTIPLE = 3e18; // 3x notional ceiling
    uint256 internal constant NOTIONAL = 10_000e6; // 10,000 USDC (6 decimals)

    // In-range when tickLower <= tick < tickUpper.
    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;
    int24 internal constant TICK_IN = 0;

    // Derived expectations.
    uint256 internal constant ONE_YEAR_DELTA = 5_000e6; // NOTIONAL * 50%
    uint256 internal constant CAP = 30_000e6; // NOTIONAL * 3x

    function setUp() public override {
        super.setUp();
        // Reuse the PoolManager from the canonically deployed hook; the harness skips
        // address-flag validation, so it can be deployed directly here.
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        harness.seedConfig(POOL_ID, _defaultConfig());
        vm.warp(START_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _defaultConfig() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
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

    function _defaultPosition() internal pure returns (RangeGuardHook.PositionState memory pos) {
        pos.entryAmt0 = 2.5e18; // arbitrary ETH leg
        pos.entryAmt1 = 5_000e6; // arbitrary USDC leg
        pos.entryTick = TICK_IN;
        pos.tickLower = TICK_LOWER;
        pos.tickUpper = TICK_UPPER;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = NOTIONAL;
        pos.earnedCoverageStable = 0;
    }

    function _seed(RangeGuardHook.PositionState memory pos) internal {
        harness.seedPosition(POOL_ID, KEY, pos);
    }

    function _pos() internal view returns (RangeGuardHook.PositionState memory) {
        return harness.getPosition(POOL_ID, KEY);
    }

    /*//////////////////////////////////////////////////////////////
                          GATING: ACTIVE / DT / RANGE
    //////////////////////////////////////////////////////////////*/

    /// Why: inactive positions must never accrue and must not even emit an event
    /// (invariant: "inactive positions must never accrue coverage"). Early return.
    function test_Accrue_WhenInactive_DoesNothing() public {
        RangeGuardHook.PositionState memory pos = _defaultPosition();
        pos.active = false;
        _seed(pos);

        vm.warp(START_TIME + SECONDS_PER_YEAR);

        vm.recordLogs();
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "inactive accrual must emit no event");
        assertEq(_pos().earnedCoverageStable, 0, "inactive must not accrue");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME), "inactive must not advance clock");
    }

    /// Why: zero dt must produce zero accrual and must not rewrite lastAccrualTime
    /// (invariant: "zero dt must always produce zero accrual delta").
    function test_Accrue_WhenDtZero_DoesNotModifyState() public {
        _seed(_defaultPosition()); // lastAccrualTime == block.timestamp

        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, 0, "dt=0 must not accrue");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME), "dt=0 must not advance clock");
    }

    /// Why: the core happy path — in range with elapsed time accrues the exact,
    /// conservatively-rounded amount (1 year @ 50% on 10k = 5k).
    function test_Accrue_WhenInRange_IncreasesCoverage() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, ONE_YEAR_DELTA, "one year @ 50% of 10k = 5k");
    }

    /// Why: half the year should accrue exactly half the coverage (APR scaling is linear).
    function test_Accrue_WhenHalfYearInRange_AccruesHalf() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR / 2);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, ONE_YEAR_DELTA / 2, "half year accrues half");
    }

    /// Why: out-of-range positions must accrue zero even with elapsed time, but the
    /// accrual clock must still advance so paused seconds never retro-accrue
    /// (invariants: "coverage only accrues while in range", "lastAccrualTime monotonic").
    function test_Accrue_WhenOutOfRange_DoesNotIncreaseCoverage() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_UPPER + 10); // above range

        assertEq(_pos().earnedCoverageStable, 0, "out of range accrues zero");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME + SECONDS_PER_YEAR), "clock still advances");
    }

    /*//////////////////////////////////////////////////////////////
                              RANGE BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// Why: the lower bound is inclusive — currentTick == tickLower is in range.
    function test_Accrue_WhenTickEqualsLower_IsInRange() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_LOWER);

        assertEq(_pos().earnedCoverageStable, ONE_YEAR_DELTA, "tickLower is inclusive (in range)");
    }

    /// Why: the upper bound is exclusive — currentTick == tickUpper is out of range.
    function test_Accrue_WhenTickEqualsUpper_IsOutOfRange() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_UPPER);

        assertEq(_pos().earnedCoverageStable, 0, "tickUpper is exclusive (out of range)");
    }

    /*//////////////////////////////////////////////////////////////
                              ACCRUAL CEILING
    //////////////////////////////////////////////////////////////*/

    /// Why: earnedCoverageStable must never exceed the configured ceiling; a long
    /// in-range period must clamp to cap = 3x notional.
    function test_Accrue_WhenCeilingExceeded_ClampsToCap() public {
        _seed(_defaultPosition());

        // 7 years @ 50% = 35k raw, must clamp to the 30k cap.
        vm.warp(START_TIME + SECONDS_PER_YEAR * 7);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, CAP, "must clamp to 3x notional cap");
    }

    /// Why: once at the cap, further in-range accrual must add zero (applied delta 0)
    /// while still advancing the clock.
    function test_Accrue_WhenAlreadyAtCap_AddsZero() public {
        RangeGuardHook.PositionState memory pos = _defaultPosition();
        pos.earnedCoverageStable = CAP;
        _seed(pos);

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, CAP, "at cap stays at cap");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME + SECONDS_PER_YEAR), "clock still advances");
    }

    /// Why: maxAccruedCoverageMultiple == 0 disables the ceiling; coverage may exceed
    /// 3x notional with no clamp.
    function test_Accrue_WhenCeilingDisabled_DoesNotClamp() public {
        RangeGuardHook.PoolConfig memory cfg = _defaultConfig();
        cfg.maxAccruedCoverageMultiple = 0;
        harness.seedConfig(POOL_ID, cfg);
        _seed(_defaultPosition());

        // 7 years @ 50% = 35k, exceeds 30k cap but ceiling is disabled.
        vm.warp(START_TIME + SECONDS_PER_YEAR * 7);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, ONE_YEAR_DELTA * 7, "no clamp when ceiling disabled");
    }

    /*//////////////////////////////////////////////////////////////
                          DEFENSIVE / EDGE INPUTS
    //////////////////////////////////////////////////////////////*/

    /// Why: dt underflow guard — if lastAccrualTime is ahead of block.timestamp, dt
    /// must fail safe to 0 (no revert, no accrual, clock not rewound)
    /// (invariant: "dt must never underflow").
    function test_Accrue_WhenLastAccrualInFuture_TreatsDtAsZero() public {
        RangeGuardHook.PositionState memory pos = _defaultPosition();
        pos.lastAccrualTime = uint32(START_TIME + SECONDS_PER_YEAR); // in the future
        _seed(pos);

        // block.timestamp is START_TIME (< lastAccrualTime).
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, 0, "future lastAccrual => zero accrual");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME + SECONDS_PER_YEAR), "clock not rewound");
    }

    /// Why: a zero entry notional has nothing to accrue on; delta must be zero while
    /// the clock advances.
    function test_Accrue_WhenZeroNotional_AccruesZero() public {
        RangeGuardHook.PositionState memory pos = _defaultPosition();
        pos.entryNotionalStable = 0;
        _seed(pos);

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, 0, "zero notional accrues zero");
        assertEq(_pos().lastAccrualTime, uint32(START_TIME + SECONDS_PER_YEAR), "clock advances");
    }

    /// Why: the helper defensively handles coverageApr == 0 (config init forbids it,
    /// but the math must still gate to zero).
    function test_Accrue_WhenZeroApr_AccruesZero() public {
        RangeGuardHook.PoolConfig memory cfg = _defaultConfig();
        cfg.coverageApr = 0;
        harness.seedConfig(POOL_ID, cfg);
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().earnedCoverageStable, 0, "zero APR accrues zero");
    }

    /*//////////////////////////////////////////////////////////////
                          CLOCK & ACCUMULATION
    //////////////////////////////////////////////////////////////*/

    /// Why: a successful in-range accrual must set lastAccrualTime to block.timestamp.
    function test_Accrue_WhenInRange_UpdatesLastAccrualTime() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);

        assertEq(_pos().lastAccrualTime, uint32(START_TIME + SECONDS_PER_YEAR), "clock set to now");
    }

    /// Why: repeated accruals accumulate and coverage is monotonic across touches;
    /// two half-years equal one full year.
    function test_Accrue_WhenAccruedTwice_Accumulates() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR / 2);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);
        uint256 afterFirst = _pos().earnedCoverageStable;

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);
        uint256 afterSecond = _pos().earnedCoverageStable;

        assertEq(afterFirst, ONE_YEAR_DELTA / 2, "first half year");
        assertGe(afterSecond, afterFirst, "coverage never decreases");
        assertEq(afterSecond, ONE_YEAR_DELTA, "two halves == one year");
    }

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// Why: every accrual on an active position emits AccrualUpdated with the applied
    /// delta and the new earned total (coverage-report source of truth).
    function test_Accrue_WhenInRange_EmitsAccrualUpdated() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(
            POOL_ID, KEY, SECONDS_PER_YEAR, ONE_YEAR_DELTA, ONE_YEAR_DELTA, true, START_TIME + SECONDS_PER_YEAR
        );
        harness.exposed_accrue(POOL_ID, KEY, TICK_IN);
    }

    /// Why: out-of-range accrual still emits, with isInRange=false and delta=0, so the
    /// coverage report can render paused periods.
    function test_Accrue_WhenOutOfRange_EmitsEventWithZeroDelta() public {
        _seed(_defaultPosition());

        vm.warp(START_TIME + SECONDS_PER_YEAR);
        vm.expectEmit(true, true, false, true, address(harness));
        emit AccrualUpdated(POOL_ID, KEY, SECONDS_PER_YEAR, 0, 0, false, START_TIME + SECONDS_PER_YEAR);
        harness.exposed_accrue(POOL_ID, KEY, TICK_UPPER);
    }
}
