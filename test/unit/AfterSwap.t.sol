// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._afterSwap() (buffer funding + TickUpdated; no accrual).
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().
// Drives the internal callback via RangeGuardHookHarness. The underlying PoolManager pool is
// never initialized here, so getSlot0 returns tick 0 (TickUpdated newTick == 0); non-zero-tick
// behavior is covered by the integration suite. Buffer math is independent of the tick.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Vm} from "forge-std/Vm.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AfterSwapTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // Mirrors of the production events for vm.expectEmit.
    event BufferFunded(PoolId indexed poolId, uint256 contribution, uint256 newBufferBalance);
    event TickUpdated(PoolId indexed poolId, int24 newTick, uint256 timestamp);

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant SWAPPER = address(0x5AFE);

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;

    uint24 internal constant BUFFER_FEE = 1000; // 0.10% in v4 pips
    uint256 internal constant FEE_DENOM = 1_000_000;

    // Representative stable-leg (token1) volume of a swap: 5,000 USDC (6 decimals).
    uint128 internal constant STABLE_VOL = 5_000e6;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = BUFFER_FEE;
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

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
    }

    function _initPool() internal returns (PoolKey memory key, PoolId poolId) {
        key = _key();
        poolId = key.toId();
        harness.stagePoolConfig(key, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    /// @dev A token0->token1 swap: swapper pays token0 (amount0 < 0), receives stable token1
    ///      (amount1 > 0). Only the stable leg magnitude drives the buffer contribution.
    function _swapDelta(int128 amount0, int128 amount1) internal pure returns (BalanceDelta) {
        return toBalanceDelta(amount0, amount1);
    }

    function _expectedContribution(uint128 stableVol) internal pure returns (uint256) {
        return uint256(stableVol) * BUFFER_FEE / FEE_DENOM;
    }

    /*//////////////////////////////////////////////////////////////
                            BUFFER FUNDING
    //////////////////////////////////////////////////////////////*/

    function test_AfterSwap_WhenSwap_IncrementsBufferByContribution() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");

        uint256 expected = _expectedContribution(STABLE_VOL); // 5_000e6 * 1000 / 1e6 == 5e6 (5 USDC)
        (uint256 buf, uint256 skimmed, uint256 paidOut) = harness.poolState(poolId);
        assertEq(buf, expected, "buffer grew by the bufferBps share of the stable leg");
        assertEq(skimmed, expected, "totalSkimmed tracks the contribution");
        assertEq(paidOut, 0, "no payouts from a swap");
    }

    function test_AfterSwap_WhenBufferPreSeeded_AddsOnTop() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        harness.seedPoolState(
            poolId,
            RangeGuardHook.PoolState({bufferBalanceStable: 10_000e6, totalSkimmedStable: 200e6, totalPaidOutStable: 7e6})
        );

        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");

        uint256 c = _expectedContribution(STABLE_VOL);
        (uint256 buf, uint256 skimmed, uint256 paidOut) = harness.poolState(poolId);
        assertEq(buf, 10_000e6 + c, "buffer adds on top of seeded balance");
        assertEq(skimmed, 200e6 + c, "skimmed adds on top");
        assertEq(paidOut, 7e6, "paidOut untouched by a swap");
    }

    /// Why: the stable leg drives the contribution regardless of swap direction — a
    /// token1->token0 swap (amount1 < 0) credits the same magnitude.
    function test_AfterSwap_WhenStableLegNegative_SameContribution() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(int128(2e18), -int128(STABLE_VOL)), "");

        (uint256 buf,,) = harness.poolState(poolId);
        assertEq(buf, _expectedContribution(STABLE_VOL), "magnitude of the stable leg drives the credit");
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_AfterSwap_WhenSwap_EmitsBufferFunded() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        uint256 c = _expectedContribution(STABLE_VOL);

        vm.expectEmit(true, false, false, true, address(harness));
        emit BufferFunded(poolId, c, c); // starting from zero, newBalance == contribution
        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");
    }

    function test_AfterSwap_WhenSwap_EmitsTickUpdated() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        // Uninitialized underlying pool -> getSlot0 tick == 0 (real extsload).
        vm.expectEmit(true, false, false, true, address(harness));
        emit TickUpdated(poolId, int24(0), START_TIME);
        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");
    }

    /*//////////////////////////////////////////////////////////////
                          ZERO / ROUNDING EDGES
    //////////////////////////////////////////////////////////////*/

    /// Why: a swap with no stable leg contributes nothing — no buffer write, no BufferFunded,
    /// but TickUpdated still fires (deterministic, one per swap).
    function test_AfterSwap_WhenZeroStableLeg_NoBufferChangeStillEmitsTick() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(harness));
        emit TickUpdated(poolId, int24(0), START_TIME);
        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(0)), "");

        (uint256 buf, uint256 skimmed,) = harness.poolState(poolId);
        assertEq(buf, 0, "no buffer change on zero contribution");
        assertEq(skimmed, 0, "no skim on zero contribution");

        // No BufferFunded log should have been emitted.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 bufferFundedSig = keccak256("BufferFunded(bytes32,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != bufferFundedSig, "BufferFunded must be skipped on zero contribution");
        }
    }

    /// Why: a sub-threshold stable leg rounds the contribution down to zero (conservative).
    /// bufferBps == 1000, FEE_DENOM == 1e6 -> stableVol < 1000 yields 0.
    function test_AfterSwap_WhenTinyStableLeg_ContributionRoundsToZero() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(999)), "");

        (uint256 buf,,) = harness.poolState(poolId);
        assertEq(buf, 0, "999 * 1000 / 1e6 truncates to 0");
    }

    /*//////////////////////////////////////////////////////////////
                       NO ACCRUAL / NO POSITION TOUCH
    //////////////////////////////////////////////////////////////*/

    /// Why: afterSwap must NEVER accrue a position. A seeded active position must be byte-for-
    /// byte unchanged after a swap (afterSwap has no position key and never iterates the set).
    function test_AfterSwap_WhenSwap_DoesNotTouchPositions() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        bytes32 posKey = harness.exposed_positionKey(SWAPPER, int24(-100), int24(100), bytes32(uint256(1)));
        RangeGuardHook.PositionState memory seeded;
        seeded.active = true;
        seeded.entryNotionalStable = 10_000e6;
        seeded.earnedCoverageStable = 123e6;
        seeded.lastAccrualTime = uint32(START_TIME - 1000);
        seeded.depositTime = uint32(START_TIME - 1000);
        harness.seedPosition(poolId, posKey, seeded);

        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");

        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, posKey);
        assertEq(pos.earnedCoverageStable, 123e6, "coverage unchanged (no accrual)");
        assertEq(pos.lastAccrualTime, uint32(START_TIME - 1000), "accrual clock unchanged");
        assertTrue(pos.active, "position still active");
    }

    /*//////////////////////////////////////////////////////////////
                            RETURN VALUES
    //////////////////////////////////////////////////////////////*/

    function test_AfterSwap_WhenCalled_ReturnsSelectorAndZeroDelta() public {
        (PoolKey memory key,) = _initPool();

        (bytes4 selector, int128 hookDelta) =
            harness.exposed_afterSwap(SWAPPER, key, _swapParams(), _swapDelta(-3e18, int128(STABLE_VOL)), "");

        assertEq(selector, harness.afterSwap.selector, "returns afterSwap selector");
        assertEq(hookDelta, int128(0), "takes no hook delta from the swap");
    }
}
