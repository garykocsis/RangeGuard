// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Integration tests for beforeSwap/afterSwap through the REAL PoolManager + swap router against
// the canonically-deployed hook (correct address flags). Unlike the unit suites (which drive the
// harness internal directly, so getSlot0 returns tick 0 and the BalanceDelta is synthetic), this
// exercises the live callbacks: a real post-swap tick read via StateLibrary, a real swap delta,
// and proof that the OVERRIDE-flagged dynamic fee is actually charged on-chain.
// Naming per testing-strategy.md: test_Integration_WhenScenario_ExpectedOutcome().

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";

contract SwapIntegration is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal ownerAddr;
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);

    uint24 internal constant BUFFER_FEE = 1000; // 0.10% in v4 pips
    uint256 internal constant FEE_DENOM = 1_000_000;

    // Price 1.01 -> tick ~99, inside the [-600, 600] liquidity range.
    uint160 internal constant SQRT_PRICE_101_100 = 79623317895830914510639640423;

    PoolModifyLiquidityTest internal lpRouter;
    // `swapRouter` is inherited from Deployers (type PoolSwapTest); we instantiate it in setUp.

    function setUp() public override {
        super.setUp();
        manager = rangeGuardHook.i_manager();
        ownerAddr = rangeGuardHook.owner();
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
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

    /// @dev Deploy a fresh sorted/approved pair, stage + initialize the pool with the given fee
    ///      config, and seed deep in-range liquidity. Returns the live pool key.
    function _makePool(uint24 baseFee, uint24 bufferFee) internal returns (PoolKey memory key) {
        MockERC20 a = new MockERC20("TKA", "TKA", 18);
        MockERC20 b = new MockERC20("TKB", "TKB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(lpRouter), type(uint256).max);
        b.approve(address(lpRouter), type(uint256).max);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        (Currency c0, Currency c1) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(rangeGuardHook))
        });

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(baseFee, bufferFee), INITIALIZER, SQRT_PRICE_101_100);
        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_101_100);

        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(key, lp, "");
    }

    /// @dev Exact-input zeroForOne swap of `amountIn` token0; returns the resulting swap delta.
    function _swap(PoolKey memory key, int256 amountIn) internal returns (BalanceDelta) {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -amountIn, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    /// Why: end-to-end, a real swap funds the buffer by the bufferBps share of the realized
    /// stable-leg volume, and TickUpdated reflects the live post-swap tick read via getSlot0.
    function test_Integration_WhenSwap_FundsBufferAndUpdatesTick() public {
        PoolKey memory key = _makePool(3000, BUFFER_FEE);
        PoolId poolId = key.toId();

        (uint256 bufBefore,,) = rangeGuardHook.poolState(poolId);
        assertEq(bufBefore, 0, "buffer starts empty (no seed in this test)");

        BalanceDelta delta = _swap(key, 1e18);

        // The stable leg the swapper received (token1 out, positive for zeroForOne).
        uint256 stableVol = uint256(uint128(delta.amount1() >= 0 ? delta.amount1() : -delta.amount1()));
        uint256 expected = stableVol * BUFFER_FEE / FEE_DENOM;

        (uint256 bufAfter, uint256 skimmed,) = rangeGuardHook.poolState(poolId);
        assertGt(stableVol, 0, "swap moved a non-zero stable leg");
        assertEq(bufAfter, expected, "buffer credited the bufferBps share of realized stable volume");
        assertEq(skimmed, expected, "totalSkimmed tracks the contribution");

        (, int24 liveTick,,) = manager.getSlot0(poolId);
        assertLt(liveTick, 99, "price moved down after a zeroForOne swap");
    }

    /// Why: the OVERRIDE-flagged dynamic fee must ACTUALLY be charged on-chain. A fee'd pool and
    /// an otherwise-identical zero-fee pool, swapped with the same exact input, must return
    /// different outputs — if the override flag were missing, v4 would charge 0 in both and the
    /// outputs would be equal. The fee'd pool yields strictly less token1.
    function test_Integration_WhenFeeOverridden_SwapperPaysDerivedFee() public {
        PoolKey memory feedPool = _makePool(3000, BUFFER_FEE); // 0.40% total
        PoolKey memory freePool = _makePool(0, 0); // 0% total

        uint256 outFeed = uint256(uint128(_swap(feedPool, 1e18).amount1()));
        uint256 outFree = uint256(uint128(_swap(freePool, 1e18).amount1()));

        assertGt(outFree, outFeed, "zero-fee pool returns more output: the override fee was applied");
        // Sanity: the gap is roughly the 0.40% fee on the input (allow generous slack for price impact).
        assertApproxEqRel(outFree - outFeed, outFree * 4000 / FEE_DENOM, 0.2e18, "gap approximates the 0.40% fee");
    }
}
