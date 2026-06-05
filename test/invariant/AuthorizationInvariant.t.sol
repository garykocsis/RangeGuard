// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for Reactive-callable authorization and the range-event alternation guard.
// invariant-mapping.md (Authorization): the three reactive functions are callable only via the
// Callback Proxy (authorizedSenderOnly); unauthorized actors must never mutate state. And the
// range-event guard `_lastRangeEventInRange` must alternate correctly across arbitrary transition
// sequences. Driven by RangeEventHandler over the shared harness. Protocol-domain naming per
// testing-strategy.md (AuthorizationInvariant), with invariant_PropertyName() functions.

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeEventHandler} from "./handlers/RangeEventHandler.sol";

contract AuthorizationInvariant is BaseRangeGuardTest {
    RangeEventHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RangeEventHandler(rangeGuardHook.i_manager());

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RangeEventHandler.emitOut.selector;
        selectors[1] = RangeEventHandler.emitIn.selector;
        selectors[2] = RangeEventHandler.unauthorized.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// invariant-mapping.md (Authorization): "checkpointCallback / checkpointAndEmitOutOfRange /
    /// checkpointAndEmitBackInRange are callable only via the Callback Proxy". No call from any other
    /// sender may ever succeed.
    function invariant_ReactiveFunctionsOnlyCallableViaCallbackProxy() public view {
        assertFalse(handler.ghost_authBreached(), "an unauthorized reactive call succeeded");
    }

    /// invariant-mapping.md (Range events): "_lastRangeEventInRange must alternate correctly". The
    /// on-chain guard always equals the strict-alternation ghost driven by successful proxy calls.
    function invariant_RangeEventGuardMatchesAlternationModel() public view {
        assertEq(
            handler.harness().exposed_lastRangeEventInRange(handler.poolId(), handler.positionKey()),
            handler.ghost_inRange(),
            "guard diverged from alternation model"
        );
    }

    /// Why: unauthorized calls and range transitions never settle or clear a position — it stays
    /// registered throughout (only afterRemoveLiquidity closes it).
    function invariant_PositionRemainsActive() public view {
        assertTrue(
            handler.harness().getPosition(handler.poolId(), handler.positionKey()).active,
            "position was deactivated by a reactive/unauthorized call"
        );
    }
}
