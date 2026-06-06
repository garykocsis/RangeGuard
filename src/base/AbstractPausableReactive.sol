// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/src/base/AbstractReactive.sol";

/// @title  AbstractPausableReactive (local port for reactive-lib-omni)
/// @notice reactive-lib-omni REMOVED the upstream `AbstractPausableReactive` and dropped the
///         `vm` / `detectVm()` environment detection (and the `rnOnly` / `vmOnly` modifiers) from
///         `AbstractReactive`. This local port restores both, byte-for-byte equivalent to the
///         pre-Omni `reactive-lib` v0.2.0 behaviour, so RangeGuard's pausable-subscription model and
///         its `if (!vm)` constructor deploy-guard keep working unchanged. The only substantive change
///         from the original is the system-contract address probed by `detectVm()` and used by
///         pause/resume: the new ReactVM system contract `SYSTEM` (0x8888…8888) instead of the legacy
///         0x…fffFfF.
/// @dev    Inherits the new `AbstractReactive`, which supplies `SYSTEM`, `REACTIVE_IGNORE`,
///         `onlySystem`, and the `AbstractPayer` payment plumbing. Subscription mutation now goes
///         through `SYSTEM.subscribe` / `SYSTEM.unsubscribe` (the `service` field was removed upstream).
///         The `Subscription` struct keeps its original snake_case field names — it is RangeGuard's
///         own type, decoupled from the renamed library `LogRecord`.
abstract contract AbstractPausableReactive is AbstractReactive {
    /*//////////////////////////////////////////////////////////////
                              TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    struct Subscription {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
    }

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice True when this instance runs on a ReactVM (no system contract at `SYSTEM`); false on
    ///         the top-level Reactive Network where subscriptions and pause/resume execute.
    bool internal vm;

    /// @notice Contract owner (deployer); gates pause/resume.
    address internal owner;

    /// @notice Whether the pausable subscriptions are currently paused.
    bool internal paused;

    /*//////////////////////////////////////////////////////////////
                                 MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    /// @notice Restricts to the Reactive Network instance (not a ReactVM).
    modifier rnOnly() {
        require(!vm, "Reactive Network only");
        _;
    }

    /// @notice Restricts to a ReactVM instance.
    modifier vmOnly() {
        require(vm, "VM only");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = msg.sender;
        detectVm();
    }

    /// @notice Pauses the contract by unsubscribing from the pausable subscription set.
    function pause() external rnOnly onlyOwner {
        require(!paused, "Already paused");
        Subscription[] memory subscriptions = getPausableSubscriptions();
        for (uint256 ix = 0; ix != subscriptions.length; ++ix) {
            SYSTEM.unsubscribe(
                subscriptions[ix].chain_id,
                subscriptions[ix]._contract,
                subscriptions[ix].topic_0,
                subscriptions[ix].topic_1,
                subscriptions[ix].topic_2,
                subscriptions[ix].topic_3
            );
        }
        paused = true;
    }

    /// @notice Resumes the contract by re-subscribing to the pausable subscription set.
    function resume() external rnOnly onlyOwner {
        require(paused, "Not paused");
        Subscription[] memory subscriptions = getPausableSubscriptions();
        for (uint256 ix = 0; ix != subscriptions.length; ++ix) {
            SYSTEM.subscribe(
                subscriptions[ix].chain_id,
                subscriptions[ix]._contract,
                subscriptions[ix].topic_0,
                subscriptions[ix].topic_1,
                subscriptions[ix].topic_2,
                subscriptions[ix].topic_3
            );
        }
        paused = false;
    }

    /// @notice Implementations return the subscription set that pause/resume toggles.
    function getPausableSubscriptions() internal view virtual returns (Subscription[] memory);

    /// @notice Determines whether this copy runs on a ReactVM (no system contract present) or the
    ///         top-level Reactive Network, by probing for code at the `SYSTEM` address.
    function detectVm() internal {
        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(0x8888888888888888888888888888888888888888)
        }
        vm = size == 0;
    }
}
