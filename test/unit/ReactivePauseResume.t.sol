// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardReactive pause/resume and the pausable subscription set.
//
// pause()/resume() are `rnOnly` (require !vm) and call service.unsubscribe/subscribe, so they can only
// run in the "Reactive Network" environment (vm == false). To simulate that locally we etch a mock
// system contract at the Reactive service address (0x…fffFfF) BEFORE deploying the contract, so
// AbstractReactive.detectVm() sees code and sets vm == false. The mock no-ops subscribe/unsubscribe
// and counts calls. The "only Cron is pausable" property is asserted directly on
// getPausableSubscriptions(). Naming per testing-strategy.md.

import {IReactive} from "reactive-lib/src/interfaces/IReactive.sol";
import {AbstractPausableReactive} from "../../src/base/AbstractPausableReactive.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardReactiveHarness} from "../harness/RangeGuardReactiveHarness.sol";
import {MockSystemContract} from "../harness/MockSystemContract.sol";

contract ReactivePauseResumeTest is BaseRangeGuardTest {
    RangeGuardReactiveHarness internal reactive;
    MockSystemContract internal sys;

    address internal constant SERVICE_ADDR = 0x8888888888888888888888888888888888888888;
    // AbstractReactive.REACTIVE_IGNORE.
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 internal constant CRON_TOPIC = 0xC0FFEE;
    uint256 internal constant MIN_INTERVAL = 120;
    address internal constant NOT_OWNER = address(0xBAD);

    function setUp() public override {
        super.setUp();
        // Etch the mock system contract at the service address BEFORE deploying, so detectVm() sets
        // vm == false (the Reactive Network path) and pause/resume's rnOnly gate passes.
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SERVICE_ADDR, address(impl).code);
        sys = MockSystemContract(payable(SERVICE_ADDR));

        reactive = new RangeGuardReactiveHarness(address(rangeGuardHook), 11155111, CRON_TOPIC, MIN_INTERVAL);
    }

    /// Why: with the system contract present, the contract is on the "Reactive Network" path.
    function test_Setup_VmIsFalse() public view {
        assertFalse(reactive.exposed_vm(), "vm == false with system contract present");
    }

    /// Why: the constructor subscribes to all four sources (Cron + 3 hook events) when !vm.
    function test_Constructor_SubscribesToFourSources() public view {
        assertEq(sys.subscribeCalls(), 4, "four subscriptions in constructor");
    }

    /// Why: only the Cron subscription is pausable; hook event subscriptions stay live.
    function test_GetPausableSubscriptions_ReturnsOnlyCron() public view {
        AbstractPausableReactive.Subscription[] memory subs = reactive.exposed_getPausableSubscriptions();
        assertEq(subs.length, 1, "exactly one pausable subscription");
        assertEq(subs[0].chain_id, block.chainid, "cron on the ReactVM chain");
        assertEq(subs[0]._contract, SERVICE_ADDR, "cron from the system contract");
        assertEq(subs[0].topic_0, CRON_TOPIC, "cron topic");
        assertEq(subs[0].topic_1, REACTIVE_IGNORE, "topic_1 ignored");
        assertEq(subs[0].topic_2, REACTIVE_IGNORE, "topic_2 ignored");
        assertEq(subs[0].topic_3, REACTIVE_IGNORE, "topic_3 ignored");
    }

    /// Why: pause() unsubscribes only the pausable set (one Cron sub) and sets paused.
    function test_Pause_UnsubscribesCronOnly() public {
        reactive.pause();
        assertTrue(reactive.exposed_paused(), "paused");
        assertEq(sys.unsubscribeCalls(), 1, "unsubscribed exactly the Cron subscription");
    }

    /// Why: resume() re-subscribes the Cron set and clears paused.
    function test_Resume_ReSubscribesCron() public {
        reactive.pause();
        uint256 beforeResume = sys.subscribeCalls();
        reactive.resume();
        assertFalse(reactive.exposed_paused(), "resumed");
        assertEq(sys.subscribeCalls(), beforeResume + 1, "re-subscribed the Cron subscription");
    }

    /// Why: only the owner (deployer) may pause.
    function test_Pause_WhenNotOwner_Reverts() public {
        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("Unauthorized"));
        reactive.pause();
    }

    /// Why: only the owner may resume.
    function test_Resume_WhenNotOwner_Reverts() public {
        reactive.pause();
        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("Unauthorized"));
        reactive.resume();
    }

    /// Why: pausing twice reverts (AbstractPausableReactive guard).
    function test_Pause_WhenAlreadyPaused_Reverts() public {
        reactive.pause();
        vm.expectRevert(bytes("Already paused"));
        reactive.pause();
    }

    /// Why: resuming when not paused reverts.
    function test_Resume_WhenNotPaused_Reverts() public {
        vm.expectRevert(bytes("Not paused"));
        reactive.resume();
    }

    /// Why: in the Reactive Network environment (vm == false), react() is not callable (vmOnly).
    function test_React_WhenVmFalse_Reverts() public {
        IReactive.LogRecord memory log;
        vm.expectRevert(bytes("VM only"));
        reactive.react(log);
    }
}
