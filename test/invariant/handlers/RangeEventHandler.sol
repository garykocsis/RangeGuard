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
import {toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title RangeEventHandler
/// @notice Invariant-test handler driving the Reactive-callable checkpoint functions over a single
///         registered position. It exercises two properties simultaneously:
///           1. Authorization — the three reactive functions (checkpointCallback,
///              checkpointAndEmitOutOfRange, checkpointAndEmitBackInRange) must ALWAYS revert when
///              called from any address other than the Callback Proxy. A breach is recorded if any
///              such call ever succeeds.
///           2. Alternation — successful proxy-driven out/in transitions are mirrored in a ghost
///              `ghost_inRange`, which the invariant checks against the hook's `_lastRangeEventInRange`.
/// @dev    The position is registered in range (guard initialized true). getSlot0 returns tick 0.
contract RangeEventHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    PoolKey internal poolKey;
    PoolId public poolId;
    bytes32 public positionKey;

    address internal constant CALLBACK_PROXY = 0x0000000000000000000000000000000000fffFfF;
    address internal constant LP = address(0x11A0);
    bytes32 internal constant SALT = bytes32(uint256(7));

    bool public ghost_inRange; // mirror of the expected guard state
    bool public ghost_authBreached; // set true if any unauthorized call ever succeeds

    constructor(IPoolManager _manager) {
        harness = new RangeGuardHookHarness(_manager, address(this));
        vm.warp(1_000_000);

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

        // Register in range [-600, 600): guard initialized true.
        positionKey = harness.exposed_positionKey(LP, int24(-600), int24(600), SALT);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: SALT});
        harness.exposed_afterAddLiquidity(
            LP, poolKey, params, toBalanceDelta(0, -int128(10_000e6)), toBalanceDelta(0, 0), ""
        );
        ghost_inRange = true;
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

    /*//////////////////////////////////////////////////////////////
                          AUTHORIZED TRANSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Attempt an out-of-range transition via the Callback Proxy; ghost tracks success only.
    function emitOut() external {
        vm.prank(CALLBACK_PROXY);
        try harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey) {
            ghost_inRange = false;
        } catch {
            // Duplicate (already out of range) — reverts, guard unchanged.
        }
    }

    /// @notice Attempt a back-in-range transition via the Callback Proxy; ghost tracks success only.
    function emitIn() external {
        vm.prank(CALLBACK_PROXY);
        try harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey) {
            ghost_inRange = true;
        } catch {
            // Duplicate (already in range) — reverts, guard unchanged.
        }
    }

    /*//////////////////////////////////////////////////////////////
                           UNAUTHORIZED CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Call one of the three reactive functions from a non-proxy sender. Any success is an
    ///         authorization breach and is recorded for the invariant to catch.
    function unauthorized(uint256 senderSeed, uint256 fnSeed) external {
        address sender = address(uint160(bound(senderSeed, 1, type(uint160).max)));
        if (sender == CALLBACK_PROXY) sender = address(uint160(uint256(uint160(sender)) - 1));
        uint256 fn = fnSeed % 3;

        vm.prank(sender);
        if (fn == 0) {
            try harness.checkpointCallback(address(0), poolId, positionKey) {
                ghost_authBreached = true;
            } catch {}
        } else if (fn == 1) {
            try harness.checkpointAndEmitOutOfRange(address(0), poolId, positionKey) {
                ghost_authBreached = true;
            } catch {}
        } else {
            try harness.checkpointAndEmitBackInRange(address(0), poolId, positionKey) {
                ghost_authBreached = true;
            } catch {}
        }
    }
}
