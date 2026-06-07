// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: permissionless checkpoint() accrual driver against the live hook.
// Proves in-range accrual (delta>0), the minCheckpointInterval rate limit (CheckpointTooSoon),
// and out-of-range accrual gating (delta==0, earned unchanged). Range transitions here are driven
// by real swaps + permissionless checkpoint(); the onlyServiceProvider emit functions
// (checkpointAndEmitOutOfRange/BackInRange) are never called from tests — on live Sepolia those are
// fired by the Reactive Network through the Callback Proxy.

import {Vm} from "forge-std/Vm.sol";
import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";

contract SepoliaCheckpointTest is SepoliaBaseTest {
    function test_Sepolia_WhenInRangeCheckpoint_AccruesCoverage() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        _swap(true, 0.005 ether); // an in-range swap; keeps the position in range

        // The position is still in range after the small swap (precondition for accrual).
        assertTrue(_currentTick() >= _getTickLower() && _currentTick() < _getTickUpper(), "must remain in range");

        uint32 lastBefore = _posLastAccrual(positionKey);
        vm.warp(block.timestamp + 121); // past minCheckpointInterval (120)

        vm.recordLogs();
        hook.checkpoint(poolId, positionKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // AccrualUpdated with delta>0 (in range, dt>0) and Checkpointed both fired.
        (bool found, Vm.Log memory accrual) = _findLog(logs, SIG_ACCRUAL_UPDATED, _poolIdB(), positionKey);
        assertTrue(found, "AccrualUpdated not emitted");
        (, uint256 delta,, bool isInRange,) = abi.decode(accrual.data, (uint256, uint256, uint256, bool, uint256));
        assertGt(delta, 0, "in-range checkpoint must accrue a positive delta");
        assertTrue(isInRange, "checkpoint must report in-range");
        assertTrue(_sawLog(logs, SIG_CHECKPOINTED, _poolIdB(), positionKey), "Checkpointed not emitted");

        assertGt(_posEarned(positionKey), 0, "earned coverage must be positive after in-range checkpoint");
        assertEq(_posLastAccrual(positionKey), uint32(block.timestamp), "lastAccrualTime updated to now");
        assertGt(_posLastAccrual(positionKey), lastBefore, "lastAccrualTime advanced");
    }

    function test_Sepolia_WhenCheckpointTooSoon_Reverts() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);

        // Immediately (dt < minCheckpointInterval) -> CheckpointTooSoon.
        vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
        hook.checkpoint(poolId, positionKey);

        // Boundary: at t+119 still too soon; at t+120 it succeeds.
        vm.warp(block.timestamp + 119);
        vm.expectRevert(RangeGuardHook.CheckpointTooSoon.selector);
        hook.checkpoint(poolId, positionKey);

        vm.warp(block.timestamp + 1); // now exactly 120 since deposit
        hook.checkpoint(poolId, positionKey); // succeeds, no revert
    }

    function test_Sepolia_WhenOutOfRangeCheckpoint_NoAccrual() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        // Depth below the demo range so the price can cross tickLower.
        _addBackgroundLiquidity(1e14);

        // First, an in-range checkpoint to bank some coverage.
        _swap(true, 0.005 ether);
        vm.warp(block.timestamp + 121);
        hook.checkpoint(poolId, positionKey);
        uint256 earnedInRange = _posEarned(positionKey);
        assertGt(earnedInRange, 0, "coverage banked while in range");

        // Large ETH->USDC swap to push the tick BELOW tickLower (out of range).
        _swap(true, 5 ether);
        assertLt(_currentTick(), _getTickLower(), "tick must be below tickLower (out of range)");

        // Out-of-range checkpoint: delta==0, isInRange==false, earned unchanged.
        vm.warp(block.timestamp + 121);
        vm.recordLogs();
        hook.checkpoint(poolId, positionKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, Vm.Log memory accrual) = _findLog(logs, SIG_ACCRUAL_UPDATED, _poolIdB(), positionKey);
        assertTrue(found, "AccrualUpdated not emitted");
        (, uint256 delta,, bool isInRange,) = abi.decode(accrual.data, (uint256, uint256, uint256, bool, uint256));
        assertEq(delta, 0, "out-of-range checkpoint must accrue zero");
        assertFalse(isInRange, "checkpoint must report out-of-range");
        assertEq(_posEarned(positionKey), earnedInRange, "earned coverage unchanged while out of range");
    }

    /// Why (extra): coverage is monotonic and the out-of-range gap contributes nothing — two spaced
    /// in-range checkpoints strictly increase earned, and an intervening out-of-range checkpoint
    /// leaves it flat. Pins the accrual-gating invariant against live state.
    function test_Sepolia_WhenInRangeThenOut_CoverageMonotonicAndGated() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        _addBackgroundLiquidity(1e14);

        vm.warp(block.timestamp + 121);
        hook.checkpoint(poolId, positionKey);
        uint256 e1 = _posEarned(positionKey);

        vm.warp(block.timestamp + 121);
        hook.checkpoint(poolId, positionKey);
        uint256 e2 = _posEarned(positionKey);
        assertGt(e2, e1, "earned strictly increases across in-range checkpoints");

        // Push out of range; subsequent checkpoints add nothing.
        _swap(true, 5 ether);
        assertLt(_currentTick(), _getTickLower(), "out of range");
        vm.warp(block.timestamp + 121);
        hook.checkpoint(poolId, positionKey);
        assertEq(_posEarned(positionKey), e2, "no accrual while out of range");
    }
}
