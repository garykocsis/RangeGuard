// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Integration test for the full withdrawal/settlement lifecycle through the REAL PoolManager +
// routers against the canonically-deployed hook. A position is added in range, a swap both funds
// the notional buffer (afterSwap) and moves the price (creating IL), time advances past the hold
// gate, the hook is funded with real token1 (simulating seedBuffer custody), and a FULL removal
// triggers settlement: final accrual -> IL -> three-cap payout -> transfer -> cleanup.
// Naming per testing-strategy.md: test_Integration_WhenScenario_ExpectedOutcome().

import {Vm} from "forge-std/Vm.sol";
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

contract RemoveLiquidityIntegration is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal ownerAddr;
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);

    // Price 1.01 -> tick ~99, inside the [-600, 600] liquidity range.
    uint160 internal constant SQRT_PRICE_101_100 = 79623317895830914510639640423;

    PoolModifyLiquidityTest internal lpRouter;

    function setUp() public override {
        super.setUp();
        manager = rangeGuardHook.i_manager();
        ownerAddr = rangeGuardHook.owner();
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
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

    /// Why: end-to-end, a full withdrawal after a price move pays a capped IL claim from the hook's
    /// real token1 custody, decrements the buffer by exactly the transferred amount, records it in
    /// totalPaidOut, clears the position, and emits a settlement event.
    function test_Integration_WhenFullWithdrawalAfterIL_SettlesClaim() public {
        // --- Pool + in-range LP position (lpRouter is the v4 sender == position owner) ---
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

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(rangeGuardHook))
        });
        PoolId poolId = key.toId();

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_101_100);
        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_101_100);

        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(key, lp, "");

        // --- Swap: funds the notional buffer (afterSwap) and moves the price (creates IL) ---
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -2e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(key, sp, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        (uint256 bufBefore,,) = rangeGuardHook.poolState(poolId);
        assertGt(bufBefore, 0, "swap funded the notional buffer");

        // Still in range so the final accrual earns coverage over the hold window.
        (, int24 tickAfterSwap,,) = manager.getSlot0(poolId);
        assertTrue(tickAfterSwap > -600 && tickAfterSwap < 600, "position still in range after swap");

        // Real backing for the payout (the buffer ledger is notional; simulate seedBuffer custody).
        MockERC20 stable = MockERC20(Currency.unwrap(c1));
        stable.mint(address(rangeGuardHook), 1_000e18);
        uint256 hookStableBefore = stable.balanceOf(address(rangeGuardHook));

        // Past the 5-minute hold gate; also gives a real accrual window.
        vm.warp(block.timestamp + 30 days);

        // --- Full withdrawal -> settlement ---
        uint256 lpStableBefore = stable.balanceOf(address(lpRouter));
        vm.recordLogs();

        ModifyLiquidityParams memory rm =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -100e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(key, rm, "");

        // --- Assert settlement accounting ---
        (uint256 bufAfter,, uint256 paidAfter) = rangeGuardHook.poolState(poolId);
        uint256 payout = bufBefore - bufAfter;

        assertGt(payout, 0, "a positive IL claim was paid");
        assertEq(paidAfter, payout, "totalPaidOut equals the payout");
        assertEq(
            hookStableBefore - stable.balanceOf(address(rangeGuardHook)), payout, "hook custody decreased by payout"
        );
        // The LP receives both their withdrawn principal (from the pool) and the hook payout.
        assertGe(stable.balanceOf(address(lpRouter)) - lpStableBefore, payout, "LP received at least the payout");

        // Position cleared (settled): the public getter's `active` flag is false.
        bytes32 posKey = keccak256(abi.encode(address(lpRouter), int24(-600), int24(600), bytes32(0)));
        (,,,,,,, bool active,,,) = rangeGuardHook.positions(poolId, posKey);
        assertFalse(active, "position cleared after settlement");

        // A settlement event (ClaimSettled or PartialPayout) fired from the hook.
        assertTrue(_sawSettlementEvent(), "a ClaimSettled or PartialPayout event was emitted");
    }

    /// @dev Scans recorded logs for either settlement event's topic0 from the hook.
    function _sawSettlementEvent() internal returns (bool) {
        bytes32 claimSig = keccak256("ClaimSettled(bytes32,bytes32,address,int24,int24,uint256,uint256,uint256,uint8)");
        bytes32 partialSig = keccak256("PartialPayout(bytes32,bytes32,address,int24,int24,uint256,uint256,uint8)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(rangeGuardHook)) continue;
            if (logs[i].topics[0] == claimSig || logs[i].topics[0] == partialSig) return true;
        }
        return false;
    }
}
