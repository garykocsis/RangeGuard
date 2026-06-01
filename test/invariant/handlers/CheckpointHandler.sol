// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title CheckpointHandler
/// @notice Invariant-test handler that drives the permissionless `checkpoint()` entry point over a
///         committed pool, advancing time by at least the checkpoint interval each round so calls
///         never revert. Three positions exercise the gating:
///           - MAIN: active, range straddles tick 0 (always in range) — accrues and is capped.
///           - OOR:  active, range above tick 0 (always out of range) — must never accrue.
///           - INACTIVE: never checkpointed (would revert) — must stay byte-for-byte unchanged.
/// @dev    The underlying PoolManager pool is never initialized, so `getSlot0` returns tick 0; the
///         in/out-of-range distinction is therefore fixed by each position's seeded bounds.
contract CheckpointHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    PoolKey internal poolKey;
    PoolId public poolId;

    bytes32 public keyMain;
    bytes32 public keyOor;
    bytes32 public keyInactive;

    uint256 public constant START_TIME = 1_000_000;
    uint32 public constant INTERVAL = 2 minutes;
    uint256 public constant NOTIONAL = 10_000e6;
    uint256 public constant MAX_MULTIPLE = 3e18;
    uint256 public constant CAP = NOTIONAL * MAX_MULTIPLE / 1e18; // 30,000e6
    uint256 internal constant MAX_TIME_JUMP = 60 days;

    uint256 public time;
    uint256 public ghost_earnedHighWater;
    uint256 public ghost_clockHighWater;
    uint256 public ghost_calls;

    constructor(IPoolManager _manager) {
        harness = new RangeGuardHookHarness(_manager, address(this));
        time = START_TIME;
        vm.warp(START_TIME);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();

        harness.stagePoolConfig(poolKey, _config(), address(0x1117), 79228162514264337593543950336);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(address(0x1117), poolKey, 79228162514264337593543950336);

        keyMain = harness.exposed_positionKey(address(0xA1), int24(-100), int24(100), bytes32(uint256(1)));
        keyOor = harness.exposed_positionKey(address(0xA2), int24(120), int24(600), bytes32(uint256(2)));
        keyInactive = harness.exposed_positionKey(address(0xA3), int24(-100), int24(100), bytes32(uint256(3)));

        harness.seedPosition(poolId, keyMain, _position(true, -100, 100));
        harness.seedPosition(poolId, keyOor, _position(true, 120, 600));
        harness.seedPosition(poolId, keyInactive, _position(false, -100, 100));
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = MAX_MULTIPLE;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = INTERVAL;
        cfg.admin = address(0xA11CE);
    }

    function _position(bool active, int24 lower, int24 upper)
        internal
        pure
        returns (RangeGuardHook.PositionState memory pos)
    {
        pos.entryAmt0 = 2.5e18;
        pos.entryAmt1 = 5_000e6;
        pos.tickLower = lower;
        pos.tickUpper = upper;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = active;
        pos.entryNotionalStable = NOTIONAL;
        pos.liquidity = 1_000_000;
    }

    /// @notice The single fuzzed action: advance time by >= INTERVAL, then checkpoint MAIN and OOR.
    /// @dev    Jumping at least one interval guarantees the rate-limit gate never reverts.
    function checkpoint(uint256 timeJump) external {
        timeJump = bound(timeJump, INTERVAL, MAX_TIME_JUMP);
        time += timeJump;
        vm.warp(time);

        harness.checkpoint(poolId, keyMain);
        harness.checkpoint(poolId, keyOor);

        RangeGuardHook.PositionState memory main = harness.getPosition(poolId, keyMain);
        if (main.earnedCoverageStable > ghost_earnedHighWater) ghost_earnedHighWater = main.earnedCoverageStable;
        if (main.lastAccrualTime > ghost_clockHighWater) ghost_clockHighWater = main.lastAccrualTime;
        ghost_calls++;
    }
}
