// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// End-to-end coverage-accrual lifecycle integration test (closes the Phase 3 gap):
//   register -> heartbeat checkpoint -> range out -> range back in -> heartbeat checkpoint -> close.
//
// Both contracts are exercised together with a faithful local relay of the Reactive Network's
// Callback Proxy: the RangeGuardReactive (ReactVM side) detects/dispatches via its handlers and emits
// `Callback` events; we relay each by pranking the Callback Proxy and invoking the corresponding
// authorizedSenderOnly hook function (host-chain side), which accrues coverage and emits the matching
// hook events. The hook is a RangeGuardHookHarness; getSlot0 returns tick 0, so the hook always
// accrues in range while the reactive tracks transitions from the ticks it is fed.
//
// Verifies: coverage accrues monotonically across checkpoints, range transitions flip the hook guard
// and dispatch the right callbacks, and closing settles a claim and untracks the position (activeKeys
// empty). Naming per testing-strategy.md: test_Integration_*.

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {RangeGuardReactiveHarness} from "../harness/RangeGuardReactiveHarness.sol";
import {MockSystemContract} from "../harness/MockSystemContract.sol";

contract CoverageAccrualLifecycleTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event PositionOutOfRange(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick,
        uint256 earnedCoverageStable,
        uint256 timestamp
    );
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    RangeGuardHookHarness internal hookH;
    RangeGuardReactiveHarness internal reactive;
    MockERC20 internal stable;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant LP = address(0x11FE);
    address internal constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
    // reactive-lib-omni system contract (SYSTEM); the etched mock re-emits Callback on dispatch.
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    bytes32 internal constant SALT = bytes32(uint256(7));
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;
    uint256 internal constant CRON_TOPIC = 0xC0FFEE;
    uint256 internal constant MIN_INTERVAL = 120;

    uint256 internal constant POSITION_REGISTERED_TOPIC_0 = uint256(
        keccak256(
            "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
        )
    );
    uint256 internal constant TICK_UPDATED_TOPIC_0 = uint256(keccak256("TickUpdated(bytes32,int24,uint256)"));
    uint256 internal constant POSITION_CLOSED_TOPIC_0 = uint256(keccak256("PositionClosed(bytes32,bytes32,address)"));

    // In range at the hook's tick 0.
    int24 internal constant LOWER = -100;
    int24 internal constant UPPER = 100;

    // Timeline (long so in-range coverage exceeds the IL cap and a real claim settles).
    uint256 internal constant START = 1_000_000;
    uint256 internal constant HB1 = START + 200 days;
    uint256 internal constant OUT_T = HB1 + 1 hours;
    uint256 internal constant IN_T = OUT_T + 1 hours;
    uint256 internal constant HB2 = IN_T + 1 hours;
    uint256 internal constant CLOSE_T = HB2 + 1 hours;

    PoolKey internal poolKey;
    PoolId internal poolId;
    bytes32 internal posKey;

    function setUp() public override {
        super.setUp();
        hookH = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        reactive = new RangeGuardReactiveHarness(address(hookH), SEPOLIA_CHAIN_ID, CRON_TOPIC, MIN_INTERVAL);
        // Etch the mock SYSTEM after construction (vm stays true, react() callable) so the reactive
        // handlers' SYSTEM.requestCallbackV_1_0 dispatch succeeds and re-emits the Callback event.
        vm.etch(SYSTEM_ADDR, address(new MockSystemContract()).code);

        stable = new MockERC20("USDC", "USDC", 6);
        stable.mint(address(hookH), 1e30); // real backing for the settlement payout

        vm.warp(START);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(stable)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hookH))
        });
        poolId = poolKey.toId();
        posKey = hookH.exposed_positionKey(LP, LOWER, UPPER, SALT);

        hookH.stagePoolConfig(poolKey, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(hookH.i_manager()));
        hookH.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);

        // Buffer large enough that the buffer cap never binds the payout.
        RangeGuardHook.PoolState memory ps;
        ps.bufferBalanceStable = 100e18;
        ps.totalSkimmedStable = 100e18;
        hookH.seedPoolState(poolId, ps);
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000; // 50%
        cfg.maxPayoutPctOfBuffer = 1000; // 10%
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = uint32(MIN_INTERVAL);
        cfg.admin = address(0xA11CE);
    }

    /*//////////////////////////////////////////////////////////////
                            LOGRECORD BUILDERS
    //////////////////////////////////////////////////////////////*/

    function _log(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = chainId;
        r.contractAddress = c;
        r.topic0 = t0;
        r.topic1 = t1;
        r.topic2 = t2;
        r.data = data;
    }

    function _poolIdU() internal view returns (uint256) {
        return uint256(PoolId.unwrap(poolId));
    }

    function _registeredLog(int24 entryTick) internal view returns (IReactive.LogRecord memory) {
        bytes memory data =
            abi.encode(LOWER, UPPER, uint128(0), uint128(0), uint256(0), entryTick, uint32(0), uint256(0), uint256(0));
        return _log(SEPOLIA_CHAIN_ID, address(hookH), POSITION_REGISTERED_TOPIC_0, _poolIdU(), uint256(posKey), data);
    }

    function _tickLog(int24 newTick) internal view returns (IReactive.LogRecord memory) {
        return _log(
            SEPOLIA_CHAIN_ID, address(hookH), TICK_UPDATED_TOPIC_0, _poolIdU(), 0, abi.encode(newTick, block.timestamp)
        );
    }

    function _closedLog() internal view returns (IReactive.LogRecord memory) {
        return
            _log(SEPOLIA_CHAIN_ID, address(hookH), POSITION_CLOSED_TOPIC_0, _poolIdU(), uint256(posKey), abi.encode(LP));
    }

    function _earned() internal view returns (uint256) {
        return hookH.getPosition(poolId, posKey).earnedCoverageStable;
    }

    /*//////////////////////////////////////////////////////////////
                            FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_Integration_FullCoverageAccrualLifecycle() public {
        // 1. REGISTER on the hook (real add), then track it on the reactive (in range -> guard true).
        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: LOWER, tickUpper: UPPER, liquidityDelta: 1e18, salt: SALT});
        hookH.exposed_afterAddLiquidity(LP, poolKey, addParams, toBalanceDelta(-1e18, -1e18), toBalanceDelta(0, 0), "");
        reactive.exposed_handlePositionRegistered(_registeredLog(0));

        assertTrue(hookH.getPosition(poolId, posKey).active, "hook: position active");
        (,,, bool rInRange, bool rActive,) = reactive.positions(posKey);
        assertTrue(rActive && rInRange, "reactive: tracked, in range");
        assertEq(reactive.activeKeysLength(), 1, "reactive: one active key");
        assertTrue(hookH.exposed_lastRangeEventInRange(poolId, posKey), "hook guard true at registration");
        assertEq(_earned(), 0, "no coverage at registration baseline");

        // 2. HEARTBEAT #1 — reactive dispatches checkpointCallback; relay executes it on the hook.
        vm.warp(HB1);
        vm.expectEmit(true, true, true, true, SYSTEM_ADDR);
        emit Callback(SEPOLIA_CHAIN_ID, address(hookH), CALLBACK_GAS_LIMIT, _checkpointPayload());
        reactive.exposed_handleHeartbeat();
        _relayCheckpoint();
        uint256 e1 = _earned();
        assertGt(e1, 0, "coverage accrued by heartbeat #1");

        // 3. RANGE OUT — reactive detects in->out, dispatches checkpointAndEmitOutOfRange; relay flips
        //    the hook guard to false and accrues.
        vm.warp(OUT_T);
        vm.expectEmit(true, true, true, true, SYSTEM_ADDR);
        emit Callback(SEPOLIA_CHAIN_ID, address(hookH), CALLBACK_GAS_LIMIT, _outOfRangePayload());
        reactive.exposed_handleTickUpdated(_tickLog(500)); // 500 out of [-100,100)
        _relayOutOfRange();
        uint256 e2 = _earned();
        assertGe(e2, e1, "coverage non-decreasing through range-out");
        assertFalse(hookH.exposed_lastRangeEventInRange(poolId, posKey), "hook guard out-of-range");
        (,,, bool rOut,,) = reactive.positions(posKey);
        assertFalse(rOut, "reactive tracks out-of-range");

        // 4. RANGE BACK IN — reactive detects out->in, dispatches checkpointAndEmitBackInRange; relay
        //    flips the hook guard back to true.
        vm.warp(IN_T);
        vm.expectEmit(true, true, true, true, SYSTEM_ADDR);
        emit Callback(SEPOLIA_CHAIN_ID, address(hookH), CALLBACK_GAS_LIMIT, _backInRangePayload());
        reactive.exposed_handleTickUpdated(_tickLog(0)); // back in range
        _relayBackInRange();
        uint256 e3 = _earned();
        assertGe(e3, e2, "coverage non-decreasing through range-in");
        assertTrue(hookH.exposed_lastRangeEventInRange(poolId, posKey), "hook guard in-range again");
        (,,, bool rIn,,) = reactive.positions(posKey);
        assertTrue(rIn, "reactive tracks back-in-range");

        // 5. HEARTBEAT #2 — another accrual.
        vm.warp(HB2);
        reactive.exposed_handleHeartbeat();
        _relayCheckpoint();
        uint256 e4 = _earned();
        assertGt(e4, e3, "coverage accrued by heartbeat #2");

        // 6. CLOSE — full withdrawal with IL settles a claim on the hook (emits PositionClosed); the
        //    reactive consumes PositionClosed and untracks the position.
        vm.warp(CLOSE_T);
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: LOWER,
            tickUpper: UPPER,
            liquidityDelta: -int256(uint256(1e18)),
            salt: SALT
        });
        // entry (1e18, 1e18) -> vHodl 2e18; withdraw (0.5e18, 1e18) -> vActual 1.5e18 -> IL 0.5e18.
        hookH.exposed_afterRemoveLiquidity(
            LP, poolKey, removeParams, toBalanceDelta(int128(0.5e18), int128(1e18)), toBalanceDelta(0, 0), ""
        );
        reactive.exposed_handlePositionClosed(_closedLog());

        // Coverage accrued over ~200 days far exceeds IL_covered (0.5e18 * 50% = 0.25e18), so the IL
        // cap binds and the LP is paid the full eligible coverage.
        assertGt(e4, 0.25e18, "accrued coverage exceeds IL cap (claim fully settles)");
        assertEq(stable.balanceOf(LP), 0.25e18, "LP paid the IL-capped claim");
        assertFalse(hookH.getPosition(poolId, posKey).active, "hook: position cleared after settlement");
        (,,,, bool stillActive,) = reactive.positions(posKey);
        assertFalse(stillActive, "reactive: position untracked");
        assertEq(reactive.activeKeysLength(), 0, "reactive: activeKeys empty after close");
    }

    /*//////////////////////////////////////////////////////////////
                        CALLBACK PROXY RELAY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _relayCheckpoint() internal {
        vm.prank(CALLBACK_PROXY);
        hookH.checkpointCallback(address(0), poolId, posKey);
    }

    function _relayOutOfRange() internal {
        vm.prank(CALLBACK_PROXY);
        hookH.checkpointAndEmitOutOfRange(address(0), poolId, posKey);
    }

    function _relayBackInRange() internal {
        vm.prank(CALLBACK_PROXY);
        hookH.checkpointAndEmitBackInRange(address(0), poolId, posKey);
    }

    function _checkpointPayload() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "checkpointCallback(address,bytes32,bytes32)", address(0), PoolId.unwrap(poolId), posKey
        );
    }

    function _outOfRangePayload() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "checkpointAndEmitOutOfRange(address,bytes32,bytes32)", address(0), PoolId.unwrap(poolId), posKey
        );
    }

    function _backInRangePayload() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "checkpointAndEmitBackInRange(address,bytes32,bytes32)", address(0), PoolId.unwrap(poolId), posKey
        );
    }
}
