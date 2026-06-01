// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Fuzz coverage for `seedBuffer()`: the credit equals the pull exactly and only touches
///         `bufferBalanceStable` (never `totalSkimmedStable`/`totalPaidOutStable`).
contract SeedBufferFuzzTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;
    MockERC20 internal token1;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant INITIALIZER = address(0x1117);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        token1 = new MockERC20("USD Coin", "USDC", 6);
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();
        harness.stagePoolConfig(poolKey, _cfg(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);

        vm.prank(ADMIN);
        token1.approve(address(harness), type(uint256).max);
    }

    function _cfg() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000;
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = ADMIN;
    }

    /// @notice A single seed credits the buffer by exactly the pulled amount, moves the real custody
    ///         by the same amount, and leaves skim/paidOut accounting untouched.
    function testFuzz_SeedBuffer_CreditsExactly(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        token1.mint(ADMIN, amount);
        uint256 hookBefore = token1.balanceOf(address(harness));

        vm.prank(ADMIN);
        harness.seedBuffer(poolKey, amount);

        (uint256 bal, uint256 skimmed, uint256 paidOut) = harness.poolState(poolId);
        assertEq(bal, amount, "buffer credited by exactly the pull");
        assertEq(skimmed, 0, "skim accounting untouched");
        assertEq(paidOut, 0, "paidOut untouched");
        assertEq(token1.balanceOf(address(harness)), hookBefore + amount, "real custody matches credit");
    }

    /// @notice Two seeds accumulate additively in both the ledger and real custody.
    function testFuzz_SeedBuffer_Accumulates(uint128 a, uint128 b) public {
        uint256 amtA = bound(a, 1, 1e24);
        uint256 amtB = bound(b, 1, 1e24);
        token1.mint(ADMIN, amtA + amtB);

        vm.startPrank(ADMIN);
        harness.seedBuffer(poolKey, amtA);
        harness.seedBuffer(poolKey, amtB);
        vm.stopPrank();

        (uint256 bal,,) = harness.poolState(poolId);
        assertEq(bal, amtA + amtB, "buffer accumulates additively");
        assertEq(token1.balanceOf(address(harness)), amtA + amtB, "custody accumulates additively");
    }
}
