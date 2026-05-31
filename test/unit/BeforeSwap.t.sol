// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._beforeSwap() (derived dynamic fee; no state touched).
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().
// Drives the internal callback via RangeGuardHookHarness (no test-only code in production).
// _beforeSwap reads poolConfig only (no getSlot0), so these run entirely against the harness.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract BeforeSwapTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant SWAPPER = address(0x5AFE);

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1

    uint24 internal constant BASE_FEE = 3000; // 0.30% in v4 pips
    uint24 internal constant BUFFER_FEE = 1000; // 0.10% in v4 pips

    function setUp() public override {
        super.setUp();
        // owner == this test contract so it can call onlyOwner setup directly.
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = BASE_FEE;
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

    /*//////////////////////////////////////////////////////////////
                              DERIVED FEE
    //////////////////////////////////////////////////////////////*/

    /// Why: the dynamic fee must be the derived sum baseLpFeeBps + bufferBps, carrying the
    /// v4 OVERRIDE flag so the PoolManager actually applies it (else it falls back to
    /// slot0.lpFee() == 0 on a dynamic pool).
    function test_BeforeSwap_WhenConfigured_ReturnsDerivedFeeWithOverrideFlag() public {
        (PoolKey memory key,) = _initPool();

        (,, uint24 fee) = harness.exposed_beforeSwap(SWAPPER, key, _swapParams(), "");

        assertTrue(LPFeeLibrary.isOverride(fee), "override flag set so v4 applies the fee");
        assertEq(LPFeeLibrary.removeOverrideFlag(fee), uint24(BASE_FEE + BUFFER_FEE), "fee == base + buffer");
    }

    function test_BeforeSwap_WhenCalled_ReturnsSelectorAndZeroDelta() public {
        (PoolKey memory key,) = _initPool();

        (bytes4 selector, BeforeSwapDelta bsd,) = harness.exposed_beforeSwap(SWAPPER, key, _swapParams(), "");

        assertEq(selector, harness.beforeSwap.selector, "returns beforeSwap selector");
        assertEq(
            BeforeSwapDelta.unwrap(bsd),
            BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA),
            "no swap delta taken"
        );
    }

    /// Why: the fee is always DERIVED, never stored — changing the config must change the fee.
    function test_BeforeSwap_WhenConfigVaries_FeeTracksConfig() public {
        PoolKey memory key = _key();

        RangeGuardHook.PoolConfig memory cfg = _config();
        cfg.baseLpFeeBps = 500; // 0.05%
        cfg.bufferBps = 2500; // 0.25%
        harness.stagePoolConfig(key, cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);

        (,, uint24 fee) = harness.exposed_beforeSwap(SWAPPER, key, _swapParams(), "");
        assertEq(LPFeeLibrary.removeOverrideFlag(fee), uint24(500 + 2500), "fee reflects the live config");
    }

    /*//////////////////////////////////////////////////////////////
                          NO STATE MUTATION
    //////////////////////////////////////////////////////////////*/

    /// Why: beforeSwap must touch no accounting state — it only derives the fee. (It is `view`,
    /// so it cannot mutate; this asserts the buffer and a seeded position are untouched.)
    function test_BeforeSwap_WhenCalled_DoesNotMutateState() public {
        (PoolKey memory key, PoolId poolId) = _initPool();

        // Seed a buffer and an active position.
        harness.seedPoolState(
            poolId,
            RangeGuardHook.PoolState({bufferBalanceStable: 1234, totalSkimmedStable: 1234, totalPaidOutStable: 0})
        );
        bytes32 posKey = harness.exposed_positionKey(SWAPPER, int24(-100), int24(100), bytes32(uint256(1)));
        RangeGuardHook.PositionState memory seeded;
        seeded.active = true;
        seeded.entryAmt0 = 7;
        seeded.earnedCoverageStable = 99;
        seeded.lastAccrualTime = 42;
        harness.seedPosition(poolId, posKey, seeded);

        harness.exposed_beforeSwap(SWAPPER, key, _swapParams(), "");

        (uint256 buf, uint256 skimmed,) = harness.poolState(poolId);
        assertEq(buf, 1234, "buffer unchanged");
        assertEq(skimmed, 1234, "skimmed unchanged");
        RangeGuardHook.PositionState memory pos = harness.getPosition(poolId, posKey);
        assertEq(pos.earnedCoverageStable, 99, "position coverage unchanged");
        assertEq(pos.lastAccrualTime, 42, "position clock unchanged");
    }
}
