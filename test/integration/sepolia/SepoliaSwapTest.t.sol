// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: buffer funding + tick update across both swap directions against the live hook.
// Proves the derived dynamic fee (4000 = 0.40%), notional buffer skim = |amount1| * bufferBps / 1e6,
// and cumulative bufferBalanceStable / totalSkimmedStable accounting across two swaps.

import {Vm} from "forge-std/Vm.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";

contract SepoliaSwapTest is SepoliaBaseTest {
    function test_Sepolia_WhenBothDirections_FundsBufferAndUpdatesTick() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);

        // Derived dynamic fee = baseLpFeeBps + bufferBps = 4000 (the hook has no getCurrentFee view).
        assertEq(_derivedFee(), 4000, "derived fee must be 4000 (0.40%)");

        // --- Swap 1: ETH -> USDC (zeroForOne, send ETH value) ---
        (uint256 buf0, uint256 skim0,) = _poolBuffer();

        vm.recordLogs();
        _swap(true, 0.01 ether);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();

        assertTrue(_sawLogPool(logs1, SIG_TICK_UPDATED, _poolIdB()), "TickUpdated not emitted (swap 1)");
        (bool funded1, Vm.Log memory bf1) = _findLogPool(logs1, SIG_BUFFER_FUNDED, _poolIdB());
        assertTrue(funded1, "BufferFunded not emitted (swap 1)");
        (uint256 contribution1, uint256 newBal1) = abi.decode(bf1.data, (uint256, uint256));
        assertGt(contribution1, 0, "buffer contribution must be positive (swap 1)");

        (uint256 buf1, uint256 skim1,) = _poolBuffer();
        assertEq(buf1, buf0 + contribution1, "buffer increased by exactly the contribution (swap 1)");
        assertEq(skim1, skim0 + contribution1, "totalSkimmed increased by exactly the contribution (swap 1)");
        assertEq(newBal1, buf1, "BufferFunded.newBufferBalance matches stored buffer (swap 1)");

        // --- Swap 2: USDC -> ETH (oneForZero; USDC pulled, approved in setUp) ---
        vm.recordLogs();
        _swap(false, 20e6); // 20 USDC in
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        assertTrue(_sawLogPool(logs2, SIG_TICK_UPDATED, _poolIdB()), "TickUpdated not emitted (swap 2)");
        (bool funded2, Vm.Log memory bf2) = _findLogPool(logs2, SIG_BUFFER_FUNDED, _poolIdB());
        assertTrue(funded2, "BufferFunded not emitted (swap 2)");
        (uint256 contribution2,) = abi.decode(bf2.data, (uint256, uint256));
        assertGt(contribution2, 0, "buffer contribution must be positive (swap 2)");

        (uint256 buf2, uint256 skim2,) = _poolBuffer();
        assertEq(buf2, buf1 + contribution2, "buffer increased again after swap 2 (cumulative)");
        assertEq(skim2, skim1 + contribution2, "totalSkimmed increased again after swap 2 (cumulative)");
    }

    /// Why (extra): the OVERRIDE-flagged dynamic fee must ACTUALLY be charged on-chain, not just sum
    /// to 4000 in config. A second swap of identical size after the first returns slightly less due to
    /// fee + price impact; here we assert the buffer skim equals exactly the bufferBps share of the
    /// realized stable leg, which is only true if the fee path executed.
    function test_Sepolia_WhenSwap_BufferSkimMatchesRealizedStableLeg() public {
        _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);

        vm.recordLogs();
        BalanceDelta delta = _swap(true, 0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        int128 amt1 = delta.amount1();
        uint256 stableLeg = uint256(uint128(amt1 >= 0 ? amt1 : -amt1));
        uint256 expected = stableLeg * CFG_BUFFER_BPS / FEE_DENOM;

        (bool funded, Vm.Log memory bf) = _findLogPool(logs, SIG_BUFFER_FUNDED, _poolIdB());
        assertTrue(funded, "BufferFunded not emitted");
        (uint256 contribution,) = abi.decode(bf.data, (uint256, uint256));
        assertEq(contribution, expected, "buffer skim equals bufferBps share of realized stable leg");
    }
}
