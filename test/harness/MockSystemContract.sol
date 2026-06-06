// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISystemContract} from "reactive-lib/src/interfaces/ISystemContract.sol";

/// @title MockSystemContract
/// @notice Minimal stand-in for the reactive-lib-omni system contract at
///         0x8888888888888888888888888888888888888888, used in Foundry tests.
/// @dev    Three uses:
///           1. Its bytecode is etched at the system-contract address (`SYSTEM`) so the local
///              `AbstractPausableReactive.detectVm()` port sees `extcodesize > 0` and sets `vm == false`
///              — the "Reactive Network" path required to exercise `pause()` / `resume()` (both `rnOnly`).
///              (Reactive handler tests instead etch it AFTER construction so `vm` stays true and
///              `react()` remains callable, while the mock is still present for `requestCallbackV_1_0`.)
///           2. `subscribe` / `unsubscribe` are no-ops so the reactive contract's constructor and
///              pause/resume can call them without reverting. Calls are counted for assertions.
///           3. `requestCallbackV_1_0` is the reactive-lib-omni replacement for the deprecated
///              `emit Callback` dispatch. The mock re-emits the legacy `Callback` event from the struct
///              fields so existing `_countCallbacks` / `vm.expectEmit` assertions keep working (the
///              emitter is now the system contract, not the reactive contract).
contract MockSystemContract {
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;
    uint256 public callbackRequests;

    /// @dev Mirrors the legacy IReactive.Callback event so test log-matching is unchanged.
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCalls++;
    }

    /// @notice reactive-lib-omni callback request. Re-emits the legacy Callback event for test parity.
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
        callbackRequests++;
        emit Callback(config.chainId, config.recipient, config.gasLimit, config.payload);
    }

    /// @dev Present so any incidental IPayable interaction (e.g. via AbstractPayer) does not revert.
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
