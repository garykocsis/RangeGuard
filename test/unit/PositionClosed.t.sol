// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests asserting RangeGuardHook.afterRemoveLiquidity emits PositionClosed on EVERY settlement
// path (IneligibleClaim, NoClaim, ClaimSettled, PartialPayout) — the single lifecycle signal the
// Reactive contract uses to stop tracking a position. Setup mirrors AfterRemoveLiquidity.t.sol: a
// real MockERC20 token1 backs payouts, getSlot0 returns tick 0 (P_exit == 1e18). Naming per
// testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

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

contract PositionClosedTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event PositionClosed(PoolId indexed poolId, bytes32 indexed positionKey, address owner);

    RangeGuardHookHarness internal harness;
    MockERC20 internal stable;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;
    uint32 internal constant MIN_HOLD = 5 minutes;

    int24 internal constant IR_LOWER = -100; // in range at tick 0
    int24 internal constant IR_UPPER = 100;
    int24 internal constant OOR_LOWER = 100; // out of range at tick 0
    int24 internal constant OOR_UPPER = 200;

    uint128 internal constant LIQUIDITY = 1e18;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);

        stable = new MockERC20("USDC", "USDC", 6);
        stable.mint(address(harness), 1e30);

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

    /*//////////////////////////////////////////////////////////////
                                FIXTURES
    //////////////////////////////////////////////////////////////*/

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

    function _seed(int24 lower, int24 upper, uint128 entry0, uint128 entry1, uint256 earned, uint256 notional)
        internal
        returns (bytes32 posKey)
    {
        posKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = entry0;
        pos.entryAmt1 = entry1;
        pos.tickLower = lower;
        pos.tickUpper = upper;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = notional;
        pos.earnedCoverageStable = earned;
        pos.liquidity = LIQUIDITY;
        harness.seedPosition(poolId, posKey, pos);
    }

    function _seedBuffer(uint256 buffer) internal {
        RangeGuardHook.PoolState memory state;
        state.bufferBalanceStable = buffer;
        state.totalSkimmedStable = buffer;
        harness.seedPoolState(poolId, state);
    }

    function _params(int24 lower, int24 upper) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: -int256(uint256(LIQUIDITY)),
            salt: SALT
        });
    }

    function _outDelta(uint128 out0, uint128 out1) internal pure returns (BalanceDelta) {
        return toBalanceDelta(int128(out0), int128(out1));
    }

    function _remove(int24 lower, int24 upper, BalanceDelta delta) internal {
        harness.exposed_afterRemoveLiquidity(LP, poolKey, _params(lower, upper), delta, toBalanceDelta(0, 0), "");
    }

    /*//////////////////////////////////////////////////////////////
                    PositionClosed ON ALL FOUR PATHS
    //////////////////////////////////////////////////////////////*/

    /// Path 1: minHold not met -> IneligibleClaim. PositionClosed must still fire.
    function test_AfterRemoveLiquidity_WhenIneligible_EmitsPositionClosed() public {
        bytes32 posKey = _seed(IR_LOWER, IR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 10); // below min hold

        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionClosed(poolId, posKey, LP);
        _remove(IR_LOWER, IR_UPPER, _outDelta(0.5e18, 1e18));

        assertFalse(harness.getPosition(poolId, posKey).active, "cleared");
    }

    /// Path 2: IL_raw == 0 -> NoClaim. PositionClosed must fire.
    function test_AfterRemoveLiquidity_WhenNoClaim_EmitsPositionClosed() public {
        bytes32 posKey = _seed(IR_LOWER, IR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days); // eligible

        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionClosed(poolId, posKey, LP);
        _remove(IR_LOWER, IR_UPPER, _outDelta(1e18, 1e18)); // out == entry -> IL 0

        assertFalse(harness.getPosition(poolId, posKey).active, "cleared");
    }

    /// Path 3: IL cap binds with payout > 0 -> ClaimSettled. PositionClosed must fire.
    function test_AfterRemoveLiquidity_WhenClaimSettled_EmitsPositionClosed() public {
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days);

        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionClosed(poolId, posKey, LP);
        _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18)); // IL cap binds

        assertEq(stable.balanceOf(LP), 0.25e18, "payout transferred");
        assertFalse(harness.getPosition(poolId, posKey).active, "cleared");
    }

    /// Path 4: coverage cap binds -> PartialPayout. PositionClosed must fire.
    function test_AfterRemoveLiquidity_WhenPartialPayout_EmitsPositionClosed() public {
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 0.1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days);

        vm.expectEmit(true, true, false, true, address(harness));
        emit PositionClosed(poolId, posKey, LP);
        _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18)); // coverage cap binds

        assertEq(stable.balanceOf(LP), 0.1e18, "partial payout transferred");
        assertFalse(harness.getPosition(poolId, posKey).active, "cleared");
    }
}
