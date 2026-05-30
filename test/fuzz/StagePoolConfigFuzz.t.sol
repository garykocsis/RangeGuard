// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardHook.stagePoolConfig().
// Naming per testing-strategy.md: testFuzz_Function_Property().
// Inherits BaseRangeGuardTest for canonical deployment; the owner-gated function is
// reached via RangeGuardHookHarness (owner == this test contract).

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract StagePoolConfigFuzz is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // Mirrors of the compile-time bounds (internal in src).
    uint24 internal constant MAX_BASE_FEE_BPS = 10_000;
    uint24 internal constant MAX_BUFFER_BPS = 5_000;
    uint256 internal constant MAX_COVERAGE_APR = 0.5e18;
    uint16 internal constant MAX_PAYOUT_PCT = 10_000;
    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant SECONDS_PER_YEAR_365F = 31_536_000;
    uint256 internal constant SECONDS_PER_YEAR_360 = 31_104_000;

    RangeGuardHookHarness internal harness;

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

    /// Why: any in-bounds config must stage successfully and round-trip into _pendingSetup.
    function testFuzz_StagePoolConfig_ValidConfigAlwaysSucceeds(
        uint24 baseLpFeeBps,
        uint24 bufferBps,
        uint256 coverageApr,
        bool use365,
        uint16 maxPayoutPctOfIl,
        uint16 maxPayoutPctOfBuffer,
        uint256 maxMultiple,
        address admin,
        address initializer,
        uint160 sqrtPrice
    ) public {
        baseLpFeeBps = uint24(bound(baseLpFeeBps, 0, MAX_BASE_FEE_BPS));
        bufferBps = uint24(bound(bufferBps, 0, MAX_BUFFER_BPS));
        coverageApr = bound(coverageApr, 1, MAX_COVERAGE_APR);
        maxPayoutPctOfIl = uint16(bound(maxPayoutPctOfIl, 0, MAX_PAYOUT_PCT));
        maxPayoutPctOfBuffer = uint16(bound(maxPayoutPctOfBuffer, 0, BPS_DENOM));
        maxMultiple = bound(maxMultiple, 0, 100e18); // 0 disables; no upper bound enforced
        vm.assume(admin != address(0));
        vm.assume(initializer != address(0));
        vm.assume(sqrtPrice != 0);

        RangeGuardHook.PoolConfig memory cfg;
        cfg.baseLpFeeBps = baseLpFeeBps;
        cfg.bufferBps = bufferBps;
        cfg.coverageApr = coverageApr;
        cfg.secondsPerYear = use365 ? SECONDS_PER_YEAR_365F : SECONDS_PER_YEAR_360;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = maxPayoutPctOfIl;
        cfg.maxPayoutPctOfBuffer = maxPayoutPctOfBuffer;
        cfg.maxAccruedCoverageMultiple = maxMultiple;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = admin;

        PoolKey memory key = _key();
        harness.stagePoolConfig(key, cfg, initializer, sqrtPrice);

        RangeGuardHook.PendingPoolSetup memory pending = harness.exposed_pendingSetup(key.toId());
        assertTrue(pending.exists, "valid config must stage");
        assertEq(pending.authorizedInitializer, initializer, "initializer round-trips");
        assertEq(pending.expectedSqrtPriceX96, sqrtPrice, "price round-trips");
        assertEq(pending.config.coverageApr, coverageApr, "apr round-trips");
        assertEq(pending.config.maxPayoutPctOfBuffer, maxPayoutPctOfBuffer, "buffer cap round-trips");
    }

    /// Why: maxPayoutPctOfBuffer above BPS_DENOM must always revert regardless of other
    /// fields — this bound is what protects the buffer-payout settlement invariant.
    function testFuzz_StagePoolConfig_BufferPctAboveDenomAlwaysReverts(uint16 bufferPct, uint256 coverageApr) public {
        bufferPct = uint16(bound(bufferPct, BPS_DENOM + 1, type(uint16).max));
        coverageApr = bound(coverageApr, 1, MAX_COVERAGE_APR);

        RangeGuardHook.PoolConfig memory cfg;
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = coverageApr;
        cfg.secondsPerYear = SECONDS_PER_YEAR_365F;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = bufferPct;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = address(0xA11CE);

        vm.expectRevert(RangeGuardHook.InvalidPayoutCaps.selector);
        harness.stagePoolConfig(_key(), cfg, address(0x1117), 79228162514264337593543950336);
    }

    /// Why: coverageApr of 0 or above MAX must always revert regardless of other fields.
    function testFuzz_StagePoolConfig_InvalidAprAlwaysReverts(uint256 coverageApr) public {
        // Map into the invalid region: either 0 or strictly above MAX_COVERAGE_APR.
        if (coverageApr % 2 == 0) {
            coverageApr = 0;
        } else {
            coverageApr = bound(coverageApr, MAX_COVERAGE_APR + 1, type(uint256).max);
        }

        RangeGuardHook.PoolConfig memory cfg;
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = coverageApr;
        cfg.secondsPerYear = SECONDS_PER_YEAR_365F;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = address(0xA11CE);

        vm.expectRevert(RangeGuardHook.InvalidApr.selector);
        harness.stagePoolConfig(_key(), cfg, address(0x1117), 79228162514264337593543950336);
    }
}
