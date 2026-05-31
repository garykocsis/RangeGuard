// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title AfterSwapHandler
/// @notice Invariant-test handler that drives RangeGuardHook._afterSwap() with randomized swap
///         deltas (any sign/magnitude on the stable leg) against a single committed pool, while
///         advancing time. It tracks the running sum of expected contributions as a ghost so the
///         invariant suite can prove the buffer exactly equals the sum of skims, and seeds one
///         active in-range position to prove afterSwap never accrues or mutates positions.
/// @dev    The underlying PoolManager pool is never initialized, so getSlot0 returns tick 0; the
///         buffer/accrual properties asserted here are independent of the tick.
contract AfterSwapHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FEE_DENOM = 1_000_000;
    uint24 internal constant BUFFER_FEE = 1000;

    RangeGuardHookHarness public immutable harness;
    PoolKey internal poolKey;
    PoolId public poolId;

    uint256 public constant START_TIME = 1_000_000;
    uint256 internal constant MAX_TIME_JUMP = 30 days;

    // Seeded position used to prove afterSwap never touches positions.
    bytes32 public seededKey;
    uint256 public constant SEEDED_COVERAGE = 123e6;
    uint32 public constant SEEDED_CLOCK = uint32(START_TIME - 1000);

    uint256 public time;
    uint256 public ghost_totalContribution; // running sum of expected buffer credits
    uint256 public ghost_swaps;

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

        // Seed one active position; it must remain byte-for-byte unchanged across all swaps.
        seededKey = harness.exposed_positionKey(address(0xA1), int24(-100), int24(100), bytes32(uint256(1)));
        RangeGuardHook.PositionState memory pos;
        pos.active = true;
        pos.entryNotionalStable = 10_000e6;
        pos.earnedCoverageStable = SEEDED_COVERAGE;
        pos.lastAccrualTime = SEEDED_CLOCK;
        pos.depositTime = SEEDED_CLOCK;
        pos.tickLower = -100;
        pos.tickUpper = 100;
        harness.seedPosition(poolId, seededKey, pos);
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = BUFFER_FEE;
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

    /// @notice The single fuzzed action: advance time, then run a swap with a random stable leg.
    function swap(uint128 stableMag, bool negative, int128 volatileLeg, uint256 timeJump) external {
        timeJump = bound(timeJump, 0, MAX_TIME_JUMP);
        time += timeJump;
        vm.warp(time);

        stableMag = uint128(bound(stableMag, 0, uint128(type(int128).max)));
        int128 stableLeg = negative ? -int128(stableMag) : int128(stableMag);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        harness.exposed_afterSwap(address(0x5AFE), poolKey, params, toBalanceDelta(volatileLeg, stableLeg), "");

        ghost_totalContribution += uint256(stableMag) * BUFFER_FEE / FEE_DENOM;
        ghost_swaps++;
    }
}
