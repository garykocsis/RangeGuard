// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardHook._beforeSwap(). Naming per testing-strategy.md:
// testFuzz_Function_Property(). Property: the returned dynamic fee is ALWAYS the derived sum
// baseLpFeeBps + bufferBps, carrying the v4 override flag, for any valid fee config.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract BeforeSwapFuzz is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;

    // Bounds mirror the contract's staging guards.
    uint24 internal constant MAX_BASE_FEE_BPS = 10_000;
    uint24 internal constant MAX_BUFFER_BPS = 5_000;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
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

    function _config(uint24 baseFee, uint24 bufferFee) internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = baseFee;
        cfg.bufferBps = bufferFee;
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

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function testFuzz_BeforeSwap_FeeAlwaysBasePlusBuffer(uint24 baseFee, uint24 bufferFee) public {
        baseFee = uint24(bound(baseFee, 0, MAX_BASE_FEE_BPS));
        bufferFee = uint24(bound(bufferFee, 0, MAX_BUFFER_BPS));

        PoolKey memory key = _key();
        harness.stagePoolConfig(key, _config(baseFee, bufferFee), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);

        (,, uint24 fee) = harness.exposed_beforeSwap(address(0x5AFE), key, _swapParams(), "");

        assertTrue(LPFeeLibrary.isOverride(fee), "override flag always set");
        assertEq(LPFeeLibrary.removeOverrideFlag(fee), uint24(baseFee + bufferFee), "fee == base + buffer");
        // The derived fee must always be a valid v4 LP fee (<= MAX_LP_FEE) so v4 applies it.
        assertLe(LPFeeLibrary.removeOverrideFlag(fee), LPFeeLibrary.MAX_LP_FEE, "fee within v4 bounds");
    }
}
