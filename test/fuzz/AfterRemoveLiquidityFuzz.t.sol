// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardHook._afterRemoveLiquidity() settlement.
// Naming per testing-strategy.md: testFuzz_Function_Property(). The callback is driven via
// RangeGuardHookHarness (getSlot0 -> tick 0, P_exit == 1e18, so V_HODL/V_actual map 1:1). The
// stable leg is a real MockERC20 minted to the harness so payouts transfer.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AfterRemoveLiquidityFuzzTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;
    MockERC20 internal stable;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;
    uint256 internal constant START_TIME = 1_000_000;
    uint32 internal constant MIN_HOLD = 5 minutes;

    // Out of range at tick 0 -> final accrue adds nothing, so `earned` is exactly seeded.
    int24 internal constant OOR_LOWER = 100;
    int24 internal constant OOR_UPPER = 200;
    uint128 internal constant LIQUIDITY = 1e18;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);

        stable = new MockERC20("USDC", "USDC", 6);
        stable.mint(address(harness), type(uint128).max); // ample real backing

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(stable)),
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
        cfg.minHoldSeconds = MIN_HOLD;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = ADMIN;
    }

    function _seed(uint128 entry0, uint128 entry1, uint256 earned) internal returns (bytes32 posKey) {
        posKey = harness.exposed_positionKey(LP, OOR_LOWER, OOR_UPPER, SALT);
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = entry0;
        pos.entryAmt1 = entry1;
        pos.tickLower = OOR_LOWER;
        pos.tickUpper = OOR_UPPER;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = uint256(entry0) + uint256(entry1);
        pos.earnedCoverageStable = earned;
        pos.liquidity = LIQUIDITY;
        harness.seedPosition(poolId, posKey, pos);
    }

    function _params() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: OOR_LOWER,
            tickUpper: OOR_UPPER,
            liquidityDelta: -int256(uint256(LIQUIDITY)),
            salt: SALT
        });
    }

    /// Why: for any seeded position/out-amounts/earned/buffer, a settled payout never exceeds any
    /// of the three caps nor the raw buffer, the buffer is decremented by exactly the payout, the
    /// LP receives exactly the payout, and totalPaidOut rises by exactly the payout (CEI accounting
    /// is consistent). Out-of-range so the seeded `earned` is the coverage cap input verbatim.
    function testFuzz_AfterRemoveLiquidity_PayoutWithinCapsAndConserves(
        uint128 entry0,
        uint128 entry1,
        uint128 out0,
        uint128 out1,
        uint128 earned,
        uint128 buffer
    ) public {
        // Bound magnitudes well within int128 so the delta/notional math cannot overflow.
        entry0 = uint128(bound(entry0, 0, uint128(type(int128).max) / 4));
        entry1 = uint128(bound(entry1, 0, uint128(type(int128).max) / 4));
        out0 = uint128(bound(out0, 0, uint128(type(int128).max) / 4));
        out1 = uint128(bound(out1, 0, uint128(type(int128).max) / 4));

        _seed(entry0, entry1, earned);
        RangeGuardHook.PoolState memory state;
        state.bufferBalanceStable = buffer;
        state.totalSkimmedStable = buffer;
        harness.seedPoolState(poolId, state);

        vm.warp(START_TIME + MIN_HOLD + 1); // eligible

        // Expected three-cap minimum at tick 0 (P_exit == 1e18). Scoped so the cap intermediates
        // free before the settlement call (keeps the frame under the stack limit, no via-IR).
        uint256 expectedPayout = _expectedPayout(entry0, entry1, out0, out1, earned, buffer);

        uint256 lpBefore = stable.balanceOf(LP);
        harness.exposed_afterRemoveLiquidity(
            LP, poolKey, _params(), toBalanceDelta(int128(out0), int128(out1)), toBalanceDelta(0, 0), ""
        );

        (uint256 bufAfter,, uint256 paidAfter) = harness.poolState(poolId);
        assertEq(stable.balanceOf(LP) - lpBefore, expectedPayout, "payout transferred matches three-cap minimum");
        assertLe(expectedPayout, buffer, "payout <= buffer balance");
        assertEq(bufAfter, uint256(buffer) - expectedPayout, "buffer decremented by exactly the payout");
        assertEq(paidAfter, expectedPayout, "totalPaidOut rose by exactly the payout");
    }

    /// @dev Mirrors the contract's three-cap selection for the fuzz oracle (tick 0, P_exit == 1e18).
    function _expectedPayout(uint128 entry0, uint128 entry1, uint128 out0, uint128 out1, uint128 earned, uint128 buffer)
        internal
        pure
        returns (uint256 payout)
    {
        uint256 vHodl = uint256(entry1) + uint256(entry0);
        uint256 vActual = uint256(out1) + uint256(out0);
        uint256 ilRaw = vHodl > vActual ? vHodl - vActual : 0;
        payout = ilRaw * 5000 / 10000; // IL_covered (50%)
        if (earned < payout) payout = earned;
        uint256 bufferCap = uint256(buffer) * 1000 / 10000; // 10% of buffer
        if (bufferCap < payout) payout = bufferCap;
    }

    /// Why: a position below the min-hold gate ALWAYS yields zero payout and a cleared slot,
    /// regardless of amounts/earned/buffer — the hard eligibility gate can never be bypassed.
    function testFuzz_AfterRemoveLiquidity_IneligibleAlwaysZeroPayout(
        uint128 entry0,
        uint128 out0,
        uint128 earned,
        uint128 buffer,
        uint256 holdElapsed
    ) public {
        uint128 c = uint128(type(int128).max) / 4;
        entry0 = uint128(bound(entry0, 0, c));
        out0 = uint128(bound(out0, 0, c));
        holdElapsed = bound(holdElapsed, 0, MIN_HOLD - 1); // strictly below the gate

        bytes32 posKey = _seed(entry0, 0, earned);
        RangeGuardHook.PoolState memory state;
        state.bufferBalanceStable = buffer;
        harness.seedPoolState(poolId, state);

        vm.warp(START_TIME + holdElapsed);

        uint256 lpBefore = stable.balanceOf(LP);
        harness.exposed_afterRemoveLiquidity(
            LP, poolKey, _params(), toBalanceDelta(int128(out0), int128(0)), toBalanceDelta(0, 0), ""
        );

        assertEq(stable.balanceOf(LP), lpBefore, "ineligible position pays nothing");
        (uint256 bufAfter,, uint256 paidAfter) = harness.poolState(poolId);
        assertEq(bufAfter, buffer, "buffer untouched when ineligible");
        assertEq(paidAfter, 0, "no payout recorded when ineligible");
        assertFalse(harness.getPosition(poolId, posKey).active, "ineligible position still cleared");
    }
}
