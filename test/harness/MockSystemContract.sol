// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockSystemContract
/// @notice Minimal stand-in for the Reactive Network system contract at
///         0x0000000000000000000000000000000000fffFfF, used in Foundry tests.
/// @dev    Two uses:
///           1. Its bytecode is etched at the system-contract address so `AbstractReactive.detectVm()`
///              sees `extcodesize > 0` and sets `vm == false` — the "Reactive Network" path required to
///              exercise `pause()` / `resume()` (both are `rnOnly`).
///           2. `subscribe` / `unsubscribe` are no-ops so the reactive contract's constructor and
///              pause/resume can call them without reverting. Calls are counted for assertions.
contract MockSystemContract {
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCalls++;
    }

    /// @dev Present so any incidental IPayable interaction (e.g. via AbstractPayer) does not revert.
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
