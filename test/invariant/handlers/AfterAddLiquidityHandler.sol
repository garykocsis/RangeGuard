// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title AfterAddLiquidityHandler
/// @notice Invariant-test handler that drives RangeGuardHook._afterAddLiquidity() with
///         randomized owners, amounts, ranges, and salts against a single committed pool,
///         while advancing time. A small key space forces frequent re-adds (top-ups), which
///         must be no-ops. The first registration of each key is captured into a ghost
///         snapshot so the invariant suite can prove entry snapshots never mutate.
/// @dev    The underlying PoolManager pool is never initialized, so getSlot0 returns tick 0;
///         the lifecycle properties asserted here are independent of the entry tick.
contract AfterAddLiquidityHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    PoolKey internal poolKey;
    PoolId public poolId;

    uint256 public constant START_TIME = 1_000_000;
    uint256 internal constant MAX_TIME_JUMP = 30 days;

    // Small fixed pools of owners / ranges / salts so distinct calls collide on keys.
    address[3] internal OWNERS = [address(0xA1), address(0xA2), address(0xA3)];
    int24[3] internal LOWERS = [int24(-200), int24(-100), int24(0)];
    int24[3] internal UPPERS = [int24(100), int24(200), int24(300)];
    bytes32[2] internal SALTS = [bytes32(uint256(1)), bytes32(uint256(2))];

    uint256 public time;
    uint256 public ghost_registrations; // distinct keys registered
    uint256 public ghost_calls; // total register() actions

    bytes32[] internal _keys;
    mapping(bytes32 => bool) internal _seen;
    mapping(bytes32 => RangeGuardHook.PositionState) internal _ghost;

    constructor(IPoolManager _manager) {
        // The handler owns its harness so it can drive onlyOwner staging directly.
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

        // owner == this handler, so it may call onlyOwner staging directly.
        harness.stagePoolConfig(poolKey, _config(), address(0x1117), 79228162514264337593543950336);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(address(0x1117), poolKey, 79228162514264337593543950336);
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

    /// @notice The single fuzzed action: advance time, then register (or re-add) a position.
    function register(
        uint256 ownerSeed,
        uint256 rangeSeed,
        uint256 saltSeed,
        uint128 amt0,
        uint128 amt1,
        uint256 timeJump
    ) external {
        timeJump = bound(timeJump, 0, MAX_TIME_JUMP);
        time += timeJump;
        vm.warp(time);

        address owner_ = OWNERS[ownerSeed % 3];
        uint256 r = rangeSeed % 3;
        int24 lower = LOWERS[r];
        int24 upper = UPPERS[r];
        bytes32 salt = SALTS[saltSeed % 2];
        amt0 = uint128(bound(amt0, 0, uint128(type(int128).max)));
        amt1 = uint128(bound(amt1, 0, uint128(type(int128).max)));

        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: salt});
        harness.exposed_afterAddLiquidity(
            owner_, poolKey, p, toBalanceDelta(-int128(amt0), -int128(amt1)), toBalanceDelta(0, 0), ""
        );

        bytes32 posKey = harness.exposed_positionKey(owner_, lower, upper, salt);
        if (!_seen[posKey]) {
            _seen[posKey] = true;
            _ghost[posKey] = harness.getPosition(poolId, posKey);
            _keys.push(posKey);
            ghost_registrations++;
        }
        ghost_calls++;
    }

    function keysLength() external view returns (uint256) {
        return _keys.length;
    }

    function keyAt(uint256 i) external view returns (bytes32) {
        return _keys[i];
    }

    function ghostOf(bytes32 posKey) external view returns (RangeGuardHook.PositionState memory) {
        return _ghost[posKey];
    }
}
