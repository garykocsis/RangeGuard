// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Integration test for checkpoint() + seedBuffer() through the REAL PoolManager + routers against
// the canonically-deployed hook. Full lifecycle: add in range -> swap (funds notional buffer +
// moves price -> IL) -> admin seedBuffer (REAL token1 custody, replacing the mint-to-hook stand-in)
// -> checkpoint after the interval (intermediate accrual) -> warp past hold -> full removal settles
// a capped claim paid from the seeded custody. Naming: test_Integration_WhenScenario_ExpectedOutcome().

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
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";

contract CheckpointAndSeedIntegration is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event Checkpointed(PoolId indexed poolId, bytes32 indexed positionKey, uint256 timestamp);
    event BufferSeeded(PoolId indexed poolId, uint256 amount, uint256 newBufferBalance);

    address internal ownerAddr;
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);

    uint160 internal constant SQRT_PRICE_101_100 = 79623317895830914510639640423; // ~tick 99, in [-600, 600]
    uint256 internal constant START_TS = 1_000_000;
    uint256 internal constant SEED_AMOUNT = 1_000e18;

    PoolModifyLiquidityTest internal lpRouter;

    function setUp() public override {
        super.setUp();
        manager = rangeGuardHook.i_manager();
        ownerAddr = rangeGuardHook.owner();
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        vm.warp(START_TS);
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

    /// Why: end-to-end, a real admin seed gives the hook the custody payouts draw from; a permissionless
    /// checkpoint advances coverage mid-life; and a full withdrawal then settles a capped claim out of
    /// the seeded balance — buffer, totalPaidOut, and real custody all reconcile.
    function test_Integration_WhenSeedThenCheckpointThenWithdraw_SettlesFromSeededCustody() public {
        // --- Pool + in-range LP position (lpRouter is the v4 sender == position owner) ---
        (PoolKey memory key, PoolId poolId, MockERC20 stable) = _setupPoolWithPosition();
        bytes32 posKey = keccak256(abi.encode(address(lpRouter), int24(-600), int24(600), bytes32(0)));

        // --- Swap: funds the notional buffer (afterSwap) and moves the price (creates IL) ---
        _swap(key);
        (uint256 bufAfterSwap,,) = rangeGuardHook.poolState(poolId);
        assertGt(bufAfterSwap, 0, "swap funded the notional buffer");
        (, int24 tickAfterSwap,,) = manager.getSlot0(poolId);
        assertTrue(tickAfterSwap > -600 && tickAfterSwap < 600, "position still in range after swap");

        // --- Real admin seed: gives the hook actual token1 custody (R2 resolution) ---
        stable.mint(ADMIN, SEED_AMOUNT);
        vm.prank(ADMIN);
        stable.approve(address(rangeGuardHook), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(rangeGuardHook));
        emit BufferSeeded(poolId, SEED_AMOUNT, bufAfterSwap + SEED_AMOUNT);
        vm.prank(ADMIN);
        rangeGuardHook.seedBuffer(key, SEED_AMOUNT);

        (uint256 bufAfterSeed,,) = rangeGuardHook.poolState(poolId);
        assertEq(bufAfterSeed, bufAfterSwap + SEED_AMOUNT, "buffer credited by the seed");
        assertEq(stable.balanceOf(address(rangeGuardHook)), SEED_AMOUNT, "hook holds real seeded custody");

        // --- Checkpoint after the interval: intermediate accrual on the live in-range position ---
        vm.warp(START_TS + 10 days);
        vm.expectEmit(true, true, false, true, address(rangeGuardHook));
        emit Checkpointed(poolId, posKey, START_TS + 10 days);
        rangeGuardHook.checkpoint(poolId, posKey); // permissionless: called by this test contract
        assertGt(_earned(poolId, posKey), 0, "checkpoint accrued intermediate coverage");

        // --- Full withdrawal -> settlement, paid from the seeded custody ---
        uint256 hookStableBeforeRemove = stable.balanceOf(address(rangeGuardHook));
        vm.warp(START_TS + 30 days); // well past the 5-minute hold
        vm.recordLogs();
        _removeAll(key);

        (uint256 bufAfterRemove,, uint256 paidAfter) = rangeGuardHook.poolState(poolId);
        uint256 payout = bufAfterSeed - bufAfterRemove;
        assertGt(payout, 0, "a positive IL claim was paid");
        assertEq(paidAfter, payout, "totalPaidOut equals the payout");
        assertEq(
            hookStableBeforeRemove - stable.balanceOf(address(rangeGuardHook)),
            payout,
            "payout came out of the seeded custody"
        );
        assertFalse(_active(poolId, posKey), "position cleared after settlement");
        assertTrue(_sawSettlementEvent(), "a ClaimSettled or PartialPayout event was emitted");
    }

    /// @dev Deploys the token pair, stages+initializes the pool, and adds an in-range position.
    function _setupPoolWithPosition() internal returns (PoolKey memory key, PoolId poolId, MockERC20 stable) {
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
        poolId = key.toId();
        stable = MockERC20(Currency.unwrap(c1));

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_101_100);
        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_101_100);

        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(key, lp, "");
    }

    function _swap(PoolKey memory key) internal {
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -2e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        swapRouter.swap(key, sp, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function _removeAll(PoolKey memory key) internal {
        ModifyLiquidityParams memory rm =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -100e18, salt: bytes32(0)});
        lpRouter.modifyLiquidity(key, rm, "");
    }

    function _earned(PoolId poolId, bytes32 posKey) internal view returns (uint256 earned) {
        (,,,,,,,,, earned,) = rangeGuardHook.positions(poolId, posKey);
    }

    function _active(PoolId poolId, bytes32 posKey) internal view returns (bool active) {
        (,,,,,,, active,,,) = rangeGuardHook.positions(poolId, posKey);
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
