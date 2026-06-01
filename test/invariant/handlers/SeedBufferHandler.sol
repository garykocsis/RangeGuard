// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title SeedBufferHandler
/// @notice Invariant-test handler that repeatedly funds a pool's buffer via `seedBuffer()`. The
///         handler is the configured admin and mints itself exactly the amount it seeds each round,
///         so the pull never reverts and the hook's real token1 custody tracks the seeds precisely.
/// @dev    Tracks the running sum of seeds as a ghost; no swaps or settlements run here, so the
///         buffer ledger and the real custody must both equal that sum.
contract SeedBufferHandler is Test {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness public immutable harness;
    MockERC20 public immutable token1;
    PoolKey internal poolKey;
    PoolId public poolId;

    uint256 public ghost_totalSeeded;
    uint256 public ghost_seeds;

    constructor(IPoolManager _manager) {
        harness = new RangeGuardHookHarness(_manager, address(this));
        token1 = new MockERC20("USD Coin", "USDC", 6);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();

        // The handler is both owner (stages/commits) and admin (seeds).
        harness.stagePoolConfig(poolKey, _config(), address(0x1117), 79228162514264337593543950336);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(address(0x1117), poolKey, 79228162514264337593543950336);

        token1.approve(address(harness), type(uint256).max);
    }

    function _config() internal view returns (RangeGuardHook.PoolConfig memory cfg) {
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
        cfg.admin = address(this); // handler seeds as admin
    }

    /// @notice The single fuzzed action: mint exactly `amount` and seed the buffer with it.
    function seed(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        token1.mint(address(this), amount); // guarantee the pull succeeds
        harness.seedBuffer(poolKey, amount);
        ghost_totalSeeded += amount;
        ghost_seeds++;
    }
}
