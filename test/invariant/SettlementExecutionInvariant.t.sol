// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for the FULL settlement-execution path (_afterRemoveLiquidity), distinct from
// SettlementInvariant.t.sol which covers the pure _computeIL / _computePayout math. Here the
// SettlementHandler runs end-to-end settlements (final accrue -> IL -> three-cap payout ->
// ERC20 transfer -> buffer update -> cleanup) against a buffer-funded pool, and these invariants
// assert the protocol-level accounting laws hold under arbitrary ordering. Each invariant cites
// the line it validates from invariant-mapping.md.

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {SettlementHandler} from "./handlers/SettlementHandler.sol";

contract SettlementExecutionInvariant is BaseRangeGuardTest {
    SettlementHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SettlementHandler(rangeGuardHook.i_manager());

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SettlementHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _poolState() internal view returns (uint256 buffer, uint256 paidOut) {
        (buffer,, paidOut) = handler.harness().poolState(handler.poolId());
    }

    /// invariant-mapping.md (Settlement): "bufferBalanceStable must never be negative" and
    /// "payout must never exceed bufferBalanceStable". The buffer only ever leaves via payouts,
    /// so the live buffer plus everything paid out must equal the initial seed exactly — a
    /// conservation law that an underflow or over-payment would break.
    function invariant_BufferConservedAcrossSettlements() public view {
        (uint256 buffer, uint256 paidOut) = _poolState();
        assertEq(buffer + paidOut, handler.INITIAL_BUFFER(), "buffer + paidOut != initial seed");
    }

    /// invariant-mapping.md (Settlement): supports "payout must never exceed bufferBalanceStable".
    /// The ledger buffer is monotonically non-increasing under settlement (it is never credited
    /// on this path).
    function invariant_BufferNeverGrowsUnderSettlement() public view {
        (uint256 buffer,) = _poolState();
        assertLe(buffer, handler.INITIAL_BUFFER(), "buffer grew under settlement");
    }

    /// invariant-mapping.md (Settlement): ties the notional buffer ledger to real custody —
    /// the LP's actual stable balance equals the cumulative ledger payouts, and the hook's
    /// remaining stable balance equals the initial backing minus everything paid out. Proves
    /// the CEI transfer and the buffer/paidOut bookkeeping never diverge.
    function invariant_RealCustodyMatchesLedgerPayouts() public view {
        (, uint256 paidOut) = _poolState();
        MockERC20 stable = handler.stable();
        RangeGuardHookHarness h = handler.harness();
        assertEq(stable.balanceOf(handler.LP()), paidOut, "LP balance != cumulative payouts");
        assertEq(stable.balanceOf(address(h)), handler.INITIAL_MINT() - paidOut, "hook custody != backing - paidOut");
    }
}
