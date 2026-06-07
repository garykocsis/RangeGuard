// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: LP deposit (Case B — price in range at deposit) against the live hook.
// Proves registration, the dt=0 accrual baseline, and that adding liquidity does not fund the buffer.

import {Vm} from "forge-std/Vm.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";

contract SepoliaLiquidityTest is SepoliaBaseTest {
    function test_Sepolia_WhenInRangeDeposit_RegistersPositionAtDt0Baseline() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        bytes32 positionKey = _derivePositionKey(LP_ROUTER, tickLower, tickUpper);

        // Price is in range at deposit (Case B): the current tick sits inside [tickLower, tickUpper).
        int24 tickAtDeposit = _currentTick();
        assertTrue(tickAtDeposit >= tickLower && tickAtDeposit < tickUpper, "deposit not in range (expected Case B)");

        (uint256 bufBefore,,) = _poolBuffer();

        vm.recordLogs();
        _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // PositionRegistered fired from the hook with the correct poolId + positionKey.
        assertTrue(
            _sawLog(logs, SIG_POSITION_REGISTERED, _poolIdB(), positionKey),
            "PositionRegistered not emitted for this position"
        );

        // AccrualUpdated baseline: dt=0 => delta=0, and isInRange=true (Case B).
        (bool found, Vm.Log memory accrual) = _findLog(logs, SIG_ACCRUAL_UPDATED, _poolIdB(), positionKey);
        assertTrue(found, "AccrualUpdated not emitted at registration");
        (, uint256 delta,, bool isInRange,) = abi.decode(accrual.data, (uint256, uint256, uint256, bool, uint256));
        assertEq(delta, 0, "baseline accrual delta must be 0 (dt=0 at registration)");
        assertTrue(isInRange, "registration AccrualUpdated must report in-range (Case B)");

        // Position state.
        Position memory p = _getPosition(positionKey);
        assertTrue(p.active, "position must be active after add");
        assertEq(p.earnedCoverageStable, 0, "no coverage earned yet (dt=0)");
        assertGt(p.entryNotionalStable, 0, "entry notional must be positive");
        assertGt(p.liquidity, 0, "position liquidity must be captured");
        assertEq(p.tickLower, tickLower, "tickLower recorded");
        assertEq(p.tickUpper, tickUpper, "tickUpper recorded");

        // Adding liquidity must NOT fund the buffer (only swaps do).
        (uint256 bufAfter,,) = _poolBuffer();
        assertEq(bufAfter, bufBefore, "buffer must be unchanged by a liquidity add");
    }
}
