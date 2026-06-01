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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title SettlementHandler
/// @notice Invariant handler that drives full `_afterRemoveLiquidity()` settlements with
///         randomized positions, withdrawn amounts, earned coverage, and (in/out of) eligibility
///         against a single buffer-funded pool. Each action registers a fresh position at a
///         unique key, settles it, and the handler asserts per-call that the buffer decrement
///         equals the realized payout. The suite then asserts buffer conservation and that real
///         token custody tracks the ledger payouts.
/// @dev    The underlying PoolManager pool is never initialized (getSlot0 -> tick 0, P_exit ==
///         1e18); positions are seeded OUT of range so the final accrual adds nothing. The stable
///         leg is a real MockERC20 minted to the harness so payouts transfer.
contract SettlementHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    MockERC20 public immutable stable;
    PoolKey internal poolKey;
    PoolId public poolId;

    address public constant LP = address(0x11FE);
    uint256 public constant START_TIME = 1_000_000;
    uint256 public constant INITIAL_BUFFER = 1e24;
    uint256 public constant INITIAL_MINT = type(uint128).max;
    uint32 public constant MIN_HOLD = 5 minutes;
    uint256 internal constant MAX_TIME_JUMP = 7 days;

    // Out of range at tick 0 -> no accrual; earned is exactly seeded.
    int24 internal constant OOR_LOWER = 100;
    int24 internal constant OOR_UPPER = 200;
    uint128 internal constant LIQUIDITY = 1e18;

    uint256 public time;
    uint256 public ghost_settlements; // total settle() actions that registered + settled

    constructor(IPoolManager _manager) {
        harness = new RangeGuardHookHarness(_manager, address(this));
        time = START_TIME;
        vm.warp(START_TIME);

        stable = new MockERC20("USDC", "USDC", 6);
        stable.mint(address(harness), INITIAL_MINT);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(stable)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();
        harness.stagePoolConfig(poolKey, _config(), address(0x1117), 79228162514264337593543950336);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(address(0x1117), poolKey, 79228162514264337593543950336);

        RangeGuardHook.PoolState memory state;
        state.bufferBalanceStable = INITIAL_BUFFER;
        state.totalSkimmedStable = INITIAL_BUFFER;
        harness.seedPoolState(poolId, state);
    }

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
        cfg.admin = address(0xA11CE);
    }

    /// @notice One settlement: register a fresh position, then settle it via afterRemoveLiquidity.
    /// @dev    Split into `_register` / `_settleAndCheck` to keep each frame under the stack limit.
    function settle(uint128 entry0, uint128 entry1, uint128 out0, uint128 out1, uint128 earned, uint256 holdSeed)
        external
    {
        time += bound(holdSeed, 0, MAX_TIME_JUMP);
        vm.warp(time);

        bytes32 salt = bytes32(ghost_settlements);
        // Mix eligibility: depositTime is `hold` seconds in the past (hold may be below MIN_HOLD).
        bytes32 posKey = _register(salt, entry0, entry1, earned, bound(holdSeed, 0, 2 * MIN_HOLD));
        _settleAndCheck(salt, posKey, out0, out1);

        ghost_settlements++;
    }

    function _register(bytes32 salt, uint128 entry0, uint128 entry1, uint128 earned, uint256 hold)
        private
        returns (bytes32 posKey)
    {
        uint128 c = uint128(type(int128).max) / 4;
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = uint128(bound(entry0, 0, c));
        pos.entryAmt1 = uint128(bound(entry1, 0, c));
        pos.tickLower = OOR_LOWER;
        pos.tickUpper = OOR_UPPER;
        pos.depositTime = uint32(time - hold);
        pos.lastAccrualTime = uint32(time);
        pos.active = true;
        pos.entryNotionalStable = uint256(pos.entryAmt0) + uint256(pos.entryAmt1);
        pos.earnedCoverageStable = earned;
        pos.liquidity = LIQUIDITY;
        posKey = harness.exposed_positionKey(LP, OOR_LOWER, OOR_UPPER, salt);
        harness.seedPosition(poolId, posKey, pos);
    }

    function _settleAndCheck(bytes32 salt, bytes32 posKey, uint128 out0, uint128 out1) private {
        uint128 c = uint128(type(int128).max) / 4;
        out0 = uint128(bound(out0, 0, c));
        out1 = uint128(bound(out1, 0, c));

        (uint256 bufBefore,, uint256 paidBefore) = harness.poolState(poolId);

        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: OOR_LOWER,
            tickUpper: OOR_UPPER,
            liquidityDelta: -int256(uint256(LIQUIDITY)),
            salt: salt
        });
        harness.exposed_afterRemoveLiquidity(
            LP, poolKey, p, toBalanceDelta(int128(out0), int128(out1)), toBalanceDelta(0, 0), ""
        );

        (uint256 bufAfter,, uint256 paidAfter) = harness.poolState(poolId);

        // Per-call CEI accounting: the buffer decrement equals the recorded payout, and the
        // payout can never exceed the buffer (no underflow).
        uint256 payout = paidAfter - paidBefore;
        assertEq(bufBefore - bufAfter, payout, "buffer decrement != payout");
        assertLe(payout, bufBefore, "payout exceeded buffer");
        assertFalse(harness.getPosition(poolId, posKey).active, "settled position must be cleared");
    }
}
