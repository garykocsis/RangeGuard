// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {DeployRangeGuardHook} from "../../script/DeployRangeGuardHook.s.sol";

abstract contract BaseRangeGuardTest is Test, Deployers {
    RangeGuardHook internal rangeGuardHook;

    function setUp() public virtual {
        DeployRangeGuardHook deployer = new DeployRangeGuardHook();
        rangeGuardHook = deployer.run();
    }
}
