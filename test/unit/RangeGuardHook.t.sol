// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// NOTE: This file serves as the canonical test pattern for RangeGuard.
// All new test suites should follow this structure:
// - inherit BaseRangeGuardTest
// - override setUp() with super.setUp()
// - one test file per function/component per testing-strategy.md

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";

contract RangeGuardHookTest is BaseRangeGuardTest {
    function setUp() public override {
        super.setUp();
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory permissions = rangeGuardHook.getHookPermissions();
        assertEq(permissions.afterAddLiquidity, true);
        assertEq(permissions.afterRemoveLiquidity, true);
        assertEq(permissions.afterSwap, true);
        assertEq(permissions.beforeInitialize, true);
        assertEq(permissions.beforeRemoveLiquidity, true);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterDonate, false);
        assertEq(permissions.afterSwapReturnDelta, false);
        assertEq(permissions.afterAddLiquidityReturnDelta, false);
    }
}
