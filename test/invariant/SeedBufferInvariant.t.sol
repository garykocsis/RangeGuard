// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Invariant tests for seedBuffer() — real token1 custody backing the IL buffer. Protocol-domain
// naming per testing-strategy.md, invariant_PropertyName() citing invariant-mapping.md. Driven by
// SeedBufferHandler (admin seeds randomized amounts). Proves the seed credit equals the real custody
// and only touches bufferBalanceStable — the resolution of the notional-vs-real-custody carry-in.

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {SeedBufferHandler} from "./handlers/SeedBufferHandler.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract SeedBufferInvariant is BaseRangeGuardTest {
    SeedBufferHandler internal handler;
    RangeGuardHookHarness internal harness;
    MockERC20 internal token1;

    function setUp() public override {
        super.setUp();
        handler = new SeedBufferHandler(rangeGuardHook.i_manager());
        harness = handler.harness();
        token1 = handler.token1();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SeedBufferHandler.seed.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// invariant-mapping.md (Settlement / testing-strategy.md "real token custody matches ledger"):
    /// with only seeds occurring, the buffer ledger equals the running sum of seeds.
    function invariant_BufferEqualsSeeded() public view {
        (uint256 buf,,) = harness.poolState(handler.poolId());
        assertEq(buf, handler.ghost_totalSeeded(), "buffer == sum of seeds");
    }

    /// seedBuffer credits bufferBalanceStable only; fee-skim accounting is untouched by admin seeding.
    function invariant_SeedingNeverTouchesSkimOrPaidOut() public view {
        (, uint256 skimmed, uint256 paidOut) = harness.poolState(handler.poolId());
        assertEq(skimmed, 0, "totalSkimmedStable touched by seeding");
        assertEq(paidOut, 0, "totalPaidOutStable touched by seeding");
    }

    /// invariant-mapping.md (Settlement): real token custody must back the ledger. The hook's actual
    /// token1 balance equals the buffer balance, so every ledgered unit is really held.
    function invariant_RealCustodyBacksBuffer() public view {
        (uint256 buf,,) = harness.poolState(handler.poolId());
        assertEq(token1.balanceOf(address(harness)), buf, "real custody must equal the buffer ledger");
    }
}
