// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Verifies that RangeGuardReactive's subscription topic0 constants exactly match the hook's REAL
// emitted event topics. A single-character signature drift would silently break subscriptions in
// production (reactiveSpec §18.1), so this triggers each hook event for real (via the hook harness),
// captures the emitted topic0 with vm.recordLogs, and asserts equality with the reactive constants.

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {RangeGuardReactiveHarness} from "../harness/RangeGuardReactiveHarness.sol";

contract ReactiveTopicWiringTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal hookH;
    RangeGuardReactiveHarness internal reactive;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;
    uint256 internal constant START_TIME = 1_000_000;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        hookH = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        reactive = new RangeGuardReactiveHarness(address(hookH), 11155111, 0xC0FFEE, 120);
        vm.warp(START_TIME);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hookH))
        });
        poolId = poolKey.toId();
        hookH.stagePoolConfig(poolKey, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(hookH.i_manager()));
        hookH.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);
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
        cfg.admin = address(0xA11CE);
    }

    /// @dev True if any recorded log carries the given topic0.
    function _hasTopic(Vm.Log[] memory logs, uint256 topic0) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == bytes32(topic0)) return true;
        }
        return false;
    }

    /// Why: the real PositionRegistered topic must equal the reactive subscription constant.
    function test_TopicWiring_PositionRegistered_MatchesRealEvent() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: 1e18, salt: SALT});

        vm.recordLogs();
        hookH.exposed_afterAddLiquidity(LP, poolKey, params, toBalanceDelta(-1e18, -1e18), toBalanceDelta(0, 0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasTopic(logs, reactive.topicPositionRegistered()), "PositionRegistered topic0 matches");
    }

    /// Why: the real TickUpdated topic must equal the reactive subscription constant.
    function test_TopicWiring_TickUpdated_MatchesRealEvent() public {
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

        vm.recordLogs();
        hookH.exposed_afterSwap(LP, poolKey, sp, toBalanceDelta(int128(1e18), int128(1e18)), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasTopic(logs, reactive.topicTickUpdated()), "TickUpdated topic0 matches");
    }

    /// Why: the real PositionClosed topic must equal the reactive subscription constant. Triggered via
    /// the IneligibleClaim settlement path (minHold not met) — emits PositionClosed with no transfer.
    function test_TopicWiring_PositionClosed_MatchesRealEvent() public {
        // Seed an active position; remove immediately (below min hold) -> IneligibleClaim + PositionClosed.
        bytes32 posKey = hookH.exposed_positionKey(LP, -100, 100, SALT);
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = 1e18;
        pos.entryAmt1 = 1e18;
        pos.tickLower = -100;
        pos.tickUpper = 100;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = 2e18;
        pos.liquidity = 1e18;
        hookH.seedPosition(poolId, posKey, pos);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -100, tickUpper: 100, liquidityDelta: -int256(uint256(1e18)), salt: SALT});

        vm.recordLogs();
        hookH.exposed_afterRemoveLiquidity(
            LP, poolKey, params, toBalanceDelta(int128(1e18), int128(1e18)), toBalanceDelta(0, 0), ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasTopic(logs, reactive.topicPositionClosed()), "PositionClosed topic0 matches");
    }
}
