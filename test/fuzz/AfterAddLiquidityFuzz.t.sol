// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardHook._afterAddLiquidity().
// Naming per testing-strategy.md: testFuzz_Function_Property(). Inherits BaseRangeGuardTest
// for canonical deployment; drives the internal callback via RangeGuardHookHarness.
//
// As in the unit suite, the underlying PoolManager pool is never initialized, so getSlot0
// returns tick 0 (P_entry == 1e18). Entry amounts are therefore the magnitudes of the
// principal delta and the notional is entryAmt1 + entryAmt0 (1:1 at tick 0). The properties
// asserted below hold independent of the specific entry tick.

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

contract AfterAddLiquidityFuzzTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);

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
        cfg.admin = ADMIN;
    }

    function _register(address lp, uint128 amt0, uint128 amt1, int24 lower, int24 upper, bytes32 salt)
        internal
        returns (bytes32 posKey)
    {
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: salt});
        harness.exposed_afterAddLiquidity(
            lp, poolKey, p, toBalanceDelta(-int128(amt0), -int128(amt1)), toBalanceDelta(0, 0), ""
        );
        posKey = harness.exposed_positionKey(lp, lower, upper, salt);
    }

    /// Why: entry amounts must equal the magnitudes of the principal delta, and at tick 0
    /// the notional must equal entryAmt1 + entryAmt0. Registration always activates and
    /// seeds a zero-coverage, now-stamped accrual baseline (dt == 0).
    function testFuzz_AfterAddLiquidity_RegistersConsistentSnapshot(
        uint128 amt0,
        uint128 amt1,
        int24 lower,
        int24 upper,
        bytes32 salt
    ) public {
        // Keep magnitudes within int128 range and ticks ordered/sane.
        amt0 = uint128(bound(amt0, 0, uint128(type(int128).max)));
        amt1 = uint128(bound(amt1, 0, uint128(type(int128).max)));
        lower = int24(bound(lower, -887000, 887000));
        upper = int24(bound(upper, -887000, 887000));
        if (lower >= upper) upper = lower + 1;

        bytes32 posKey = _register(address(0x11FE), amt0, amt1, lower, upper, salt);
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, posKey);

        assertTrue(pos.active, "registered position is active");
        assertEq(pos.entryAmt0, amt0, "entryAmt0 == |delta0|");
        assertEq(pos.entryAmt1, amt1, "entryAmt1 == |delta1|");
        assertEq(pos.entryTick, 0, "entryTick from getSlot0");
        assertEq(pos.entryNotionalStable, uint256(amt1) + uint256(amt0), "notional == stable + volatile at tick 0");
        assertEq(pos.earnedCoverageStable, 0, "no coverage at dt=0");
        assertEq(pos.lastAccrualTime, uint32(START_TIME), "accrual clock seeded to now");
        assertEq(pos.depositTime, uint32(START_TIME), "depositTime seeded to now");
    }

    /// Why: a larger stable-leg principal can never produce a smaller entry notional
    /// (monotonicity of the notional in the deposited amounts).
    function testFuzz_AfterAddLiquidity_NotionalMonotonicInStableLeg(uint128 amt1Small, uint128 extra) public {
        amt1Small = uint128(bound(amt1Small, 0, uint128(type(int128).max) / 2));
        extra = uint128(bound(extra, 0, uint128(type(int128).max) / 2));

        bytes32 kSmall = _register(address(0xA1), 1e18, amt1Small, -100, 100, bytes32(uint256(1)));
        bytes32 kLarge = _register(address(0xA2), 1e18, amt1Small + extra, -100, 100, bytes32(uint256(2)));

        uint256 nSmall = harness.getPosition(poolId, kSmall).entryNotionalStable;
        uint256 nLarge = harness.getPosition(poolId, kLarge).entryNotionalStable;
        assertGe(nLarge, nSmall, "notional monotonic in stable leg");
    }

    /// Why: re-adding to an active position must never mutate the immutable entry snapshot,
    /// regardless of the second add's amounts.
    function testFuzz_AfterAddLiquidity_ReAddNeverMutatesSnapshot(uint128 amt0b, uint128 amt1b) public {
        amt0b = uint128(bound(amt0b, 0, uint128(type(int128).max)));
        amt1b = uint128(bound(amt1b, 0, uint128(type(int128).max)));

        bytes32 posKey = _register(address(0xB1), 3e18, 5_000e6, -100, 100, bytes32(uint256(9)));
        RangeGuardHook.PositionState memory before = harness.getPosition(poolId, posKey);

        // Second add at the same (owner, range, salt) -> same key -> must be a no-op.
        _register(address(0xB1), amt0b, amt1b, -100, 100, bytes32(uint256(9)));
        RangeGuardHook.PositionState memory afterPos = harness.getPosition(poolId, posKey);

        assertEq(afterPos.entryAmt0, before.entryAmt0, "entryAmt0 immutable");
        assertEq(afterPos.entryAmt1, before.entryAmt1, "entryAmt1 immutable");
        assertEq(afterPos.entryNotionalStable, before.entryNotionalStable, "notional immutable");
        assertEq(afterPos.depositTime, before.depositTime, "depositTime immutable");
    }
}
