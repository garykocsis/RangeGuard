// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: the full coverage lifecycle through the live hook in a single test —
// deposit (in range) -> in-range swap -> checkpoint(accrue) -> out-of-range -> checkpoint(gated) ->
// back-in-range -> checkpoint(resumed) -> full withdrawal -> settlement. Closes with the buffer
// self-consistency invariant: bufferBalanceStable + totalPaidOut == initialBuffer + totalSkimmed
// (expressed as the conserved seed constant, robust to any nonzero starting totals on the fork).
// Range transitions are driven by real swaps + permissionless checkpoint(); the Reactive-only
// emit functions are exercised on live Sepolia, not here.

import {Vm} from "forge-std/Vm.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";

contract SepoliaEndToEnd is SepoliaBaseTest {
    function test_Sepolia_FullCoverageLifecycle() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();

        // [1] Deposit (Case B — in range) + background depth so the price can cross the boundaries.
        bytes32 positionKey = _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        _addBackgroundLiquidity(1e14);
        int256 seedBefore = _seedConstant();
        assertTrue(_currentTick() >= tickLower && _currentTick() < tickUpper, "must start in range");

        // [2] In-range swap: funds the buffer and updates the tick.
        {
            (uint256 buf0, uint256 skim0,) = _poolBuffer();
            vm.recordLogs();
            _swap(true, 0.01 ether);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertTrue(_sawLogPool(logs, SIG_TICK_UPDATED, _poolIdB()), "TickUpdated (in-range swap)");
            (bool funded, Vm.Log memory bf) = _findLogPool(logs, SIG_BUFFER_FUNDED, _poolIdB());
            assertTrue(funded, "BufferFunded (in-range swap)");
            (uint256 contribution,) = abi.decode(bf.data, (uint256, uint256));
            (uint256 buf1, uint256 skim1,) = _poolBuffer();
            assertEq(buf1, buf0 + contribution, "buffer += contribution");
            assertEq(skim1, skim0 + contribution, "skimmed += contribution");
        }

        // [3] Warp + checkpoint while in range -> positive accrual.
        vm.warp(block.timestamp + 121);
        (uint256 d1, bool r1) = _checkpoint(positionKey);
        assertTrue(r1, "checkpoint 1 in range");
        assertGt(d1, 0, "in-range checkpoint accrues > 0");
        uint256 earnedAfterFirst = _posEarned(positionKey);

        // [4] Large ETH->USDC swap pushes the tick below tickLower (out of range).
        _swap(true, 5 ether);
        assertLt(_currentTick(), tickLower, "tick crossed below tickLower (out of range)");

        // [5] Warp + checkpoint while out of range -> zero accrual, earned frozen.
        vm.warp(block.timestamp + 121);
        (uint256 d2, bool r2) = _checkpoint(positionKey);
        assertFalse(r2, "checkpoint 2 out of range");
        assertEq(d2, 0, "out-of-range checkpoint accrues 0");
        assertEq(_posEarned(positionKey), earnedAfterFirst, "earned frozen while out of range");

        // [6] Large USDC->ETH swap pushes the tick back into range (sized to land inside the band).
        _swap(false, 3_500e6);
        assertTrue(_currentTick() >= tickLower && _currentTick() < tickUpper, "tick crossed back into range");

        // [7] Warp + checkpoint -> accrual resumes (> 0 again).
        vm.warp(block.timestamp + 121);
        (uint256 d3, bool r3) = _checkpoint(positionKey);
        assertTrue(r3, "checkpoint 3 back in range");
        assertGt(d3, 0, "accrual resumed after re-entry");
        assertGt(_posEarned(positionKey), earnedAfterFirst, "earned grew after re-entry");

        // [8] Full withdrawal (well past minHold = 300s; we have warped 363s) -> settlement.
        vm.recordLogs();
        _removeLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        Vm.Log[] memory wlogs = vm.getRecordedLogs();

        // [9] Exactly one settlement event + PositionClosed; position cleared.
        bool settled = _sawLog(wlogs, SIG_CLAIM_SETTLED, _poolIdB(), positionKey)
            || _sawLog(wlogs, SIG_PARTIAL_PAYOUT, _poolIdB(), positionKey)
            || _sawLog(wlogs, SIG_NO_CLAIM, _poolIdB(), positionKey);
        assertTrue(settled, "a settlement event must fire");
        assertTrue(_sawLog(wlogs, SIG_POSITION_CLOSED, _poolIdB(), positionKey), "PositionClosed must fire");
        assertFalse(_posActive(positionKey), "position cleared");

        // [10] Buffer self-consistency end-to-end:
        // bufferBalanceStable + totalPaidOut - totalSkimmed is invariant (== initial seed).
        assertEq(_seedConstant(), seedBefore, "buffer self-consistent end-to-end");
    }

    /// @dev Calls permissionless checkpoint() recording logs, returns (delta, isInRange) from the
    ///      emitted AccrualUpdated. Kept as a helper to bound the main test's stack usage.
    function _checkpoint(bytes32 positionKey) internal returns (uint256 delta, bool isInRange) {
        vm.recordLogs();
        hook.checkpoint(poolId, positionKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, Vm.Log memory accrual) = _findLog(logs, SIG_ACCRUAL_UPDATED, _poolIdB(), positionKey);
        assertTrue(found, "AccrualUpdated not emitted by checkpoint");
        (, delta,, isInRange,) = abi.decode(accrual.data, (uint256, uint256, uint256, bool, uint256));
    }
}
