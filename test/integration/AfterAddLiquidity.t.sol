// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Integration test for afterAddLiquidity through the REAL PoolManager + modify-liquidity
// router against the canonically-deployed hook (correct address flags). Unlike the unit
// suite (which drives the harness internal directly, so getSlot0 returns tick 0 and the
// BalanceDelta is synthetic), this exercises the live callback: a real non-zero entry tick
// read via StateLibrary and a real router-produced principal delta.
// Naming per testing-strategy.md: test_Integration_WhenScenario_ExpectedOutcome().

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";

contract AfterAddLiquidityIntegration is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal ownerAddr;
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);

    // Price 1.01 -> entry tick ~99, inside the [-120, 120] position range.
    uint160 internal constant SQRT_PRICE_101_100 = 79623317895830914510639640423;

    PoolModifyLiquidityTest internal lpRouter;
    Currency internal curr0;
    Currency internal curr1;

    function setUp() public override {
        super.setUp();
        manager = rangeGuardHook.i_manager();
        ownerAddr = rangeGuardHook.owner();

        // The canonical (script-based) deploy flow wires the hook + manager but not the test
        // routers, so stand up just the modify-liquidity router and a sorted, approved pair.
        lpRouter = new PoolModifyLiquidityTest(manager);
        (curr0, curr1) = _deployApprovedPair();
    }

    function _deployApprovedPair() internal returns (Currency, Currency) {
        MockERC20 a = new MockERC20("TKA", "TKA", 18);
        MockERC20 b = new MockERC20("TKB", "TKB", 18);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(lpRouter), type(uint256).max);
        b.approve(address(lpRouter), type(uint256).max);
        return address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
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

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: curr0,
            currency1: curr1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(rangeGuardHook))
        });
    }

    /// Why: end-to-end, a real add registers the position with the LIVE entry tick (read via
    /// getSlot0) and the real principal magnitudes from the router delta; the dt=0 baseline
    /// seeds the accrual clock and accrues nothing.
    function test_Integration_WhenLiquidityAdded_RegistersPositionWithLiveTick() public {
        PoolKey memory key = _key();
        PoolId poolId = key.toId();

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_101_100);
        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_101_100);

        // Live tick the hook should snapshot at deposit.
        (, int24 liveTick,,) = manager.getSlot0(poolId);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)});

        // The router is the caller into PoolManager, so it is the position `owner` (the v4
        // `sender`) — matching the documented MVP limitation.
        BalanceDelta delta = lpRouter.modifyLiquidity(key, params, "");
        bytes32 posKey = keccak256(abi.encode(address(lpRouter), int24(-120), int24(120), bytes32(0)));

        // Read in scoped chunks (the 11-field public getter + locals would otherwise blow
        // the stack without via-IR). Each block re-reads only the fields it asserts.
        {
            (,, int24 entryTick, int24 tickLower, int24 tickUpper,,, bool active,,,) =
                rangeGuardHook.positions(poolId, posKey);
            assertTrue(active, "position registered active");
            assertEq(entryTick, liveTick, "entryTick snapshots the live pool tick");
            assertEq(tickLower, -120, "tickLower");
            assertEq(tickUpper, 120, "tickUpper");
        }
        {
            // Adds make the caller delta negative; entry amounts record the magnitudes.
            (uint128 entryAmt0, uint128 entryAmt1,,,,,,, uint256 entryNotionalStable,,) =
                rangeGuardHook.positions(poolId, posKey);
            assertEq(entryAmt0, uint128(-delta.amount0()), "entryAmt0 == |delta0| (principal)");
            assertEq(entryAmt1, uint128(-delta.amount1()), "entryAmt1 == |delta1| (principal)");
            assertGt(entryAmt0, 0, "in-range add funds the volatile leg");
            assertGt(entryAmt1, 0, "in-range add funds the stable leg");
            // Notional includes the stable leg plus the (non-negative) priced volatile leg.
            assertGe(entryNotionalStable, entryAmt1, "notional covers at least the stable leg");
        }
        {
            // dt = 0 baseline: clock seeded, nothing accrued, nothing pending.
            (,,,,, uint32 depositTime, uint32 lastAccrualTime,,, uint256 earnedCoverageStable, uint256 pendingPayout) =
                rangeGuardHook.positions(poolId, posKey);
            assertEq(earnedCoverageStable, 0, "no coverage at registration");
            assertEq(pendingPayout, 0, "no pending payout");
            assertEq(depositTime, uint32(block.timestamp), "depositTime stamped now");
            assertEq(lastAccrualTime, depositTime, "accrual clock seeded to deposit time");
        }
    }
}
