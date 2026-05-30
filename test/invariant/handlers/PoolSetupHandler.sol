// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title PoolSetupHandler
/// @notice Invariant-test handler that drives the three-phase pool setup state machine
///         (stage -> initialize -> setReactive) across a fixed set of pools with
///         randomized ordering and inputs. The harness `owner` is the parent test
///         contract, so owner-gated calls are pranked as `harness.owner()` and the
///         Phase-2 commit is pranked as the PoolManager.
/// @dev    Inputs are bounded and actions are guarded by current state so the handler
///         advances the machine without spurious reverts. Always stages a VALID config,
///         so any committed pool must satisfy the pool-setup invariants by construction.
contract PoolSetupHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    address internal immutable manager;

    uint256 public constant POOL_COUNT = 4;

    // Fixed per-pool keys/ids.
    PoolKey[POOL_COUNT] internal _keys;
    PoolId[POOL_COUNT] internal _ids;

    // Per-pool staged expectations (so initialize() can satisfy the exact-match checks).
    address[POOL_COUNT] internal _initializer;
    uint160[POOL_COUNT] internal _expectedPrice;

    // Ghost: pools that have ever been reactive-registered (for monotonicity).
    bool[POOL_COUNT] internal _everReactiveSet;

    constructor(RangeGuardHookHarness _harness) {
        harness = _harness;
        manager = address(_harness.i_manager());

        for (uint256 i = 0; i < POOL_COUNT; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(uint160(0x1000 + i))),
                currency1: Currency.wrap(address(uint160(0x2000 + i))),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: 60,
                hooks: IHooks(address(_harness))
            });
            _keys[i] = key;
            _ids[i] = key.toId();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Phase 1: stage (or re-stage) a valid config on a not-yet-initialized pool.
    function stage(uint256 poolSeed, uint160 priceSeed, address initializerSeed) external {
        uint256 i = bound(poolSeed, 0, POOL_COUNT - 1);
        if (harness.exposed_poolInitialized(_ids[i])) return; // can't stage after init

        address initializer = initializerSeed == address(0) ? address(0xA11CE) : initializerSeed;
        uint160 price = priceSeed == 0 ? 1 : priceSeed;

        _initializer[i] = initializer;
        _expectedPrice[i] = price;

        vm.prank(harness.owner());
        harness.stagePoolConfig(_keys[i], _validConfig(), initializer, price);
    }

    /// @notice Phase 2: commit a staged pool via the PoolManager-gated callback.
    function initialize(uint256 poolSeed) external {
        uint256 i = bound(poolSeed, 0, POOL_COUNT - 1);
        if (harness.exposed_poolInitialized(_ids[i])) return;
        if (!harness.exposed_pendingSetup(_ids[i]).exists) return;

        vm.prank(manager);
        harness.beforeInitialize(_initializer[i], _keys[i], _expectedPrice[i]);
    }

    /// @notice Phase 3: register a non-zero reactive contract exactly once per pool.
    function setReactive(uint256 poolSeed, uint256 reactiveSeed) external {
        uint256 i = bound(poolSeed, 0, POOL_COUNT - 1);
        if (!harness.exposed_poolInitialized(_ids[i])) return;
        if (harness.exposed_reactiveSet(_ids[i])) return;

        address reactive = address(uint160(reactiveSeed | 1)); // force non-zero

        vm.prank(harness.owner());
        harness.setReactiveContract(_keys[i], reactive);
        _everReactiveSet[i] = true;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function idAt(uint256 i) external view returns (PoolId) {
        return _ids[i];
    }

    function everReactiveSet(uint256 i) external view returns (bool) {
        return _everReactiveSet[i];
    }

    function _validConfig() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
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
}
