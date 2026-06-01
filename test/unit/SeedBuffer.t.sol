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

/// @notice Unit coverage for `seedBuffer()` — admin-only real token1 custody for the IL buffer.
contract SeedBufferTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    event BufferSeeded(PoolId indexed poolId, uint256 amount, uint256 newBufferBalance);

    RangeGuardHookHarness internal harness;
    MockERC20 internal token1;

    address internal constant ADMIN = address(0xA11CE); // must match _cfg().admin
    address internal constant NOT_ADMIN = address(0xBAD);
    address internal constant INITIALIZER = address(0x1117);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1

    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 internal constant SEED = 10_000e6;

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

        // Real stage + commit so the hook-side _poolInitialized flag is set.
        harness.stagePoolConfig(poolKey, _cfg(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);

        // Fund the admin and approve the hook to pull.
        token1.mint(ADMIN, 1_000_000e6);
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

    function _buffer() internal view returns (uint256 bal, uint256 skimmed, uint256 paidOut) {
        (bal, skimmed, paidOut) = harness.poolState(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                                 REVERTS
    //////////////////////////////////////////////////////////////*/

    /// Why: the initialized check runs first, so even the admin cannot seed an uninitialized pool
    /// (and the failure is PoolNotInitialized, not the misleading CallerNotAdmin from a zero admin).
    function test_SeedBuffer_WhenPoolNotInitialized_Reverts() public {
        PoolKey memory altKey = poolKey;
        altKey.currency0 = Currency.wrap(address(0x9999)); // distinct, uninitialized poolId
        vm.prank(ADMIN);
        vm.expectRevert(RangeGuardHook.PoolNotInitialized.selector);
        harness.seedBuffer(altKey, SEED);
    }

    function test_SeedBuffer_WhenCallerNotAdmin_Reverts() public {
        vm.prank(NOT_ADMIN);
        vm.expectRevert(RangeGuardHook.CallerNotAdmin.selector);
        harness.seedBuffer(poolKey, SEED);
    }

    function test_SeedBuffer_WhenZeroAmount_RevertsZeroAmount() public {
        vm.prank(ADMIN);
        vm.expectRevert(RangeGuardHook.ZeroAmount.selector);
        harness.seedBuffer(poolKey, 0);
    }

    /// Why: with no allowance the ERC20 transferFrom reverts; the buffer must not be credited.
    function test_SeedBuffer_WhenNoAllowance_Reverts() public {
        address admin2 = address(0xA11CE2);
        // Re-point config admin to a funded-but-unapproved account.
        RangeGuardHook.PoolConfig memory cfg = _cfg();
        cfg.admin = admin2;
        harness.seedConfig(poolId, cfg);
        token1.mint(admin2, SEED);

        vm.prank(admin2);
        vm.expectRevert();
        harness.seedBuffer(poolKey, SEED);

        (uint256 bal,,) = _buffer();
        assertEq(bal, 0, "buffer untouched on failed pull");
    }

    /*//////////////////////////////////////////////////////////////
                                 SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_SeedBuffer_WhenValid_PullsTokenAndIncrementsBuffer() public {
        uint256 hookBefore = token1.balanceOf(address(harness));
        uint256 adminBefore = token1.balanceOf(ADMIN);

        vm.prank(ADMIN);
        harness.seedBuffer(poolKey, SEED);

        assertEq(token1.balanceOf(address(harness)), hookBefore + SEED, "hook received token1");
        assertEq(token1.balanceOf(ADMIN), adminBefore - SEED, "admin debited");

        (uint256 bal, uint256 skimmed, uint256 paidOut) = _buffer();
        assertEq(bal, SEED, "bufferBalanceStable credited");
        assertEq(skimmed, 0, "totalSkimmedStable untouched (fee accounting only)");
        assertEq(paidOut, 0, "totalPaidOutStable untouched");
    }

    function test_SeedBuffer_WhenSeededTwice_Accumulates() public {
        vm.startPrank(ADMIN);
        harness.seedBuffer(poolKey, SEED);
        harness.seedBuffer(poolKey, 5_000e6);
        vm.stopPrank();

        (uint256 bal, uint256 skimmed,) = _buffer();
        assertEq(bal, SEED + 5_000e6, "buffer accumulates across seeds");
        assertEq(skimmed, 0, "still no skim from seeding");
        assertEq(token1.balanceOf(address(harness)), SEED + 5_000e6, "real custody accumulates");
    }

    function test_SeedBuffer_WhenValid_EmitsBufferSeeded() public {
        vm.expectEmit(true, false, false, true, address(harness));
        emit BufferSeeded(poolId, SEED, SEED);
        vm.prank(ADMIN);
        harness.seedBuffer(poolKey, SEED);
    }

    /// Why: the seed credit reads against the live buffer, so the event balance reflects prior seeds.
    function test_SeedBuffer_WhenPreSeeded_EventCarriesRunningBalance() public {
        vm.prank(ADMIN);
        harness.seedBuffer(poolKey, SEED);

        vm.expectEmit(true, false, false, true, address(harness));
        emit BufferSeeded(poolId, 5_000e6, SEED + 5_000e6);
        vm.prank(ADMIN);
        harness.seedBuffer(poolKey, 5_000e6);
    }
}
