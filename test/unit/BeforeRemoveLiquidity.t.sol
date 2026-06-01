// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._beforeRemoveLiquidity() — VALIDATION ONLY.
// v4 constraint: `beforeRemoveLiquidity` can only allow or revert; it never settles. These
// tests pin the two structural rules (position must be active; MVP full-withdrawal only) and
// prove the gate mutates no accrual / IL / payout / buffer state.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract BeforeRemoveLiquidityTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;

    int24 internal constant TICK_LOWER = -100;
    int24 internal constant TICK_UPPER = 100;
    uint128 internal constant LIQUIDITY = 1e18;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

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

    /// @dev Seeds an active position with `liquidity = LIQUIDITY` at the test range.
    function _seedActive(PoolId poolId) internal returns (bytes32 posKey) {
        posKey = harness.exposed_positionKey(LP, TICK_LOWER, TICK_UPPER, SALT);
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = 1e18;
        pos.entryAmt1 = 1e18;
        pos.tickLower = TICK_LOWER;
        pos.tickUpper = TICK_UPPER;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = 2e18;
        pos.earnedCoverageStable = 123;
        pos.liquidity = LIQUIDITY;
        harness.seedPosition(poolId, posKey, pos);
    }

    /// @dev Removal params: negative `liquidityDelta` of the given magnitude.
    function _removeParams(uint128 removed) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: -int256(uint256(removed)),
            salt: SALT
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_BeforeRemoveLiquidity_WhenPositionInactive_Reverts() public {
        (PoolKey memory key,) = _initPool(); // position never seeded -> inactive
        vm.expectRevert(RangeGuardHook.PositionNotActive.selector);
        harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(LIQUIDITY), "");
    }

    function test_BeforeRemoveLiquidity_WhenPartialWithdrawal_Reverts() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        _seedActive(poolId);
        // Remove less than the full position liquidity.
        vm.expectRevert(RangeGuardHook.PartialWithdrawalNotSupported.selector);
        harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(LIQUIDITY - 1), "");
    }

    function test_BeforeRemoveLiquidity_WhenRemovingMoreThanLiquidity_Reverts() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        _seedActive(poolId);
        vm.expectRevert(RangeGuardHook.PartialWithdrawalNotSupported.selector);
        harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(LIQUIDITY + 1), "");
    }

    function test_BeforeRemoveLiquidity_WhenZeroLiquidityRemoved_Reverts() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        _seedActive(poolId);
        vm.expectRevert(RangeGuardHook.PartialWithdrawalNotSupported.selector);
        harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(0), "");
    }

    /*//////////////////////////////////////////////////////////////
                              SUCCESS / PURITY
    //////////////////////////////////////////////////////////////*/

    function test_BeforeRemoveLiquidity_WhenFullWithdrawal_ReturnsSelector() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        _seedActive(poolId);
        bytes4 selector = harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(LIQUIDITY), "");
        assertEq(selector, harness.beforeRemoveLiquidity.selector, "returns beforeRemoveLiquidity selector");
    }

    /// Why: the gate is validation-only — it must not touch accrual, IL, payout, or buffer state.
    function test_BeforeRemoveLiquidity_WhenFullWithdrawal_DoesNotMutateState() public {
        (PoolKey memory key, PoolId poolId) = _initPool();
        bytes32 posKey = _seedActive(poolId);

        RangeGuardHook.PositionState memory before = harness.getPosition(poolId, posKey);
        (uint256 bufBefore, uint256 skimBefore, uint256 paidBefore) = harness.poolState(poolId);

        harness.exposed_beforeRemoveLiquidity(LP, key, _removeParams(LIQUIDITY), "");

        RangeGuardHook.PositionState memory afterPos = harness.getPosition(poolId, posKey);
        (uint256 bufAfter, uint256 skimAfter, uint256 paidAfter) = harness.poolState(poolId);

        assertTrue(afterPos.active, "position still active");
        assertEq(afterPos.earnedCoverageStable, before.earnedCoverageStable, "earned coverage unchanged");
        assertEq(afterPos.lastAccrualTime, before.lastAccrualTime, "accrual clock unchanged");
        assertEq(afterPos.liquidity, before.liquidity, "liquidity unchanged");
        assertEq(bufAfter, bufBefore, "buffer unchanged");
        assertEq(skimAfter, skimBefore, "skimmed unchanged");
        assertEq(paidAfter, paidBefore, "paid-out unchanged");
    }
}
