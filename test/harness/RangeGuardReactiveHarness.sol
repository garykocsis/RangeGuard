// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RangeGuardReactive} from "../../src/RangeGuardReactive.sol";

/// @title RangeGuardReactiveHarness
/// @notice Test-only harness exposing RangeGuardReactive's internal handlers and protected state so
///         the ReactVM logic can be unit-tested without a live Reactive Network. Tests construct
///         `LogRecord` structs manually and call the exposed handlers directly (bypassing the
///         `vmOnly`-gated `react()`), and read `service`/`paused`/the pausable subscription set.
/// @dev    Lives entirely in the test tree so no test-only code leaks into the production contract.
contract RangeGuardReactiveHarness is RangeGuardReactive {
    constructor(address _hook, uint256 _hookChainId, uint256 _cron, uint256 _interval)
        payable
        RangeGuardReactive(_hook, _hookChainId, _cron, _interval)
    {}

    function exposed_handlePositionRegistered(LogRecord calldata log) external {
        _handlePositionRegistered(log);
    }

    function exposed_handleTickUpdated(LogRecord calldata log) external {
        _handleTickUpdated(log);
    }

    function exposed_handleHeartbeat() external {
        _handleHeartbeat();
    }

    function exposed_handlePositionClosed(LogRecord calldata log) external {
        _handlePositionClosed(log);
    }

    /// @notice Exposes the resolved system-contract address (`service`) for routing assertions.
    function exposed_service() external view returns (address) {
        return address(service);
    }

    /// @notice Exposes the `vm` flag (true outside ReactVM, e.g. plain Foundry).
    function exposed_vm() external view returns (bool) {
        return vm;
    }

    /// @notice Exposes the `paused` flag from AbstractPausableReactive.
    function exposed_paused() external view returns (bool) {
        return paused;
    }

    /// @notice Exposes the pausable subscription set for the "only Cron is pausable" assertion.
    function exposed_getPausableSubscriptions() external view returns (Subscription[] memory) {
        return getPausableSubscriptions();
    }

    /// @notice Exposes the production topic0 constants for direct wiring checks against real hook events.
    function topicPositionRegistered() external pure returns (uint256) {
        return POSITION_REGISTERED_TOPIC_0;
    }

    function topicTickUpdated() external pure returns (uint256) {
        return TICK_UPDATED_TOPIC_0;
    }

    function topicPositionClosed() external pure returns (uint256) {
        return POSITION_CLOSED_TOPIC_0;
    }
}

