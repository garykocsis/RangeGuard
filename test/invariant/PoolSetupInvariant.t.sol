// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for the three-phase pool setup lifecycle.
// Protocol-domain naming per testing-strategy.md (PoolSetupInvariant), with
// invariant_PropertyName() functions. Each invariant cites the exact rule it validates
// from invariant-mapping.md. Randomized stage/initialize/setReactive ordering is driven
// by PoolSetupHandler over the shared harness.

import {PoolId} from "v4-core/types/PoolId.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {PoolSetupHandler} from "./handlers/PoolSetupHandler.sol";

contract PoolSetupInvariant is BaseRangeGuardTest {
    uint256 internal constant BPS_DENOM = 10_000;

    RangeGuardHookHarness internal harness;
    PoolSetupHandler internal handler;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        handler = new PoolSetupHandler(harness);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PoolSetupHandler.stage.selector;
        selectors[1] = PoolSetupHandler.initialize.selector;
        selectors[2] = PoolSetupHandler.setReactive.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// invariant-mapping.md (Pool Setup / Initialization): "_poolInitialized[id] == true
    /// must imply _pendingSetup[id].exists == false (pending setup deleted on commit)".
    function invariant_PoolInitializedImpliesPendingSetupDeleted() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            PoolId id = handler.idAt(i);
            if (harness.exposed_poolInitialized(id)) {
                assertFalse(harness.exposed_pendingSetup(id).exists, "pending not deleted after init");
            }
        }
    }

    /// invariant-mapping.md (Initialization): "_poolInitialized[id] == true must imply
    /// poolConfig[id].admin != address(0) (config was validly committed)".
    function invariant_PoolInitializedImpliesAdminNonZero() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            PoolId id = handler.idAt(i);
            if (harness.exposed_poolInitialized(id)) {
                (,,,,,,,,,, address admin) = harness.poolConfig(id);
                assertTrue(admin != address(0), "committed config has zero admin");
            }
        }
    }

    /// invariant-mapping.md (Accounting/Initialization): "_poolInitialized[id] == true must
    /// imply poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM" — protects the buffer-payout
    /// settlement invariant.
    function invariant_PoolInitializedImpliesBufferPctWithinDenom() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            PoolId id = handler.idAt(i);
            if (harness.exposed_poolInitialized(id)) {
                (,,,,,, uint16 maxPayoutPctOfBuffer,,,,) = harness.poolConfig(id);
                assertLe(uint256(maxPayoutPctOfBuffer), BPS_DENOM, "buffer pct exceeds denom");
            }
        }
    }

    /// invariant-mapping.md (Reactive registration): "_reactiveSet[id] == true must imply
    /// reactiveContract[id] != address(0)".
    function invariant_ReactiveSetImpliesReactiveNonZero() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            PoolId id = handler.idAt(i);
            if (harness.exposed_reactiveSet(id)) {
                assertTrue(harness.reactiveContract(id) != address(0), "reactive set but zero address");
            }
        }
    }

    /// invariant-mapping.md (Reactive registration): "_reactiveSet[id] == true must imply
    /// _poolInitialized[id] == true (reactive can only be set on an initialized pool)".
    function invariant_ReactiveSetImpliesInitialized() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            PoolId id = handler.idAt(i);
            if (harness.exposed_reactiveSet(id)) {
                assertTrue(harness.exposed_poolInitialized(id), "reactive set on uninitialized pool");
            }
        }
    }

    /// invariant-mapping.md (Reactive registration): "_reactiveSet[id] is monotonically
    /// true — once set, it can never return to false". Every pool the handler has ever
    /// registered must still report the guard as locked.
    function invariant_ReactiveSetIsMonotonicallyTrue() public view {
        for (uint256 i = 0; i < handler.POOL_COUNT(); i++) {
            if (handler.everReactiveSet(i)) {
                assertTrue(harness.exposed_reactiveSet(handler.idAt(i)), "reactiveSet reverted to false");
            }
        }
    }
}
