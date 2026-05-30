// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// NOTE: This file serves as the canonical test pattern for RangeGuard.
// All new test suites should follow this structure:
// - inherit BaseRangeGuardTest
// - override setUp() with super.setUp()
// - one test file per function/component per testing-strategy.md
//
// Hook-level coverage: getHookPermissions + the three-phase pool setup
// (stagePoolConfig / _beforeInitialize commit / setReactiveContract). The setup
// functions are exercised through RangeGuardHookHarness so the test contract is the
// protocol `owner` (harness constructor receives address(this)) and internal/private
// setup state can be asserted via the harness getters.

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract RangeGuardHookTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // Mirrors of the production events for vm.expectEmit.
    event PoolConfigStaged(
        PoolId indexed poolId,
        RangeGuardHook.PoolConfig config,
        address authorizedInitializer,
        uint160 expectedSqrtPriceX96
    );
    event PoolConfigInitialized(PoolId indexed poolId, RangeGuardHook.PoolConfig config);
    event ReactiveContractSet(PoolId indexed poolId, address reactive);

    RangeGuardHookHarness internal harness;

    // Actors.
    address internal constant INITIALIZER = address(0x1117);
    address internal constant REACTIVE = address(0xBEEF);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xBAD);

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint160 internal constant WRONG_SQRT_PRICE = 87150978765690771352898345369; // ~5:4

    function setUp() public override {
        super.setUp();
        // Harness shares the canonically-deployed PoolManager; owner = this test contract
        // so it may call the onlyOwner setup functions directly.
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _validConfig() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000; // A/365F
        cfg.minHoldSeconds = 5 minutes;
        cfg.maxPayoutPctOfIl = 5000;
        cfg.maxPayoutPctOfBuffer = 1000;
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = ADMIN;
    }

    /// @dev Dynamic-fee key bound to the harness; currencies are sorted dummies.
    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
    }

    function _stageValid() internal returns (PoolKey memory key, PoolId poolId) {
        key = _key();
        poolId = key.toId();
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /// @dev Commit a staged pool via the PoolManager-gated callback, pranked as the manager.
    function _commit(PoolKey memory key) internal {
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                             HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                       stagePoolConfig — ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_StagePoolConfig_WhenNotOwner_Reverts() public {
        PoolKey memory key = _key();
        vm.prank(NOT_OWNER);
        vm.expectRevert(RangeGuardHook.NotOwner.selector);
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenAlreadyInitialized_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        _commit(key);

        vm.expectRevert(RangeGuardHook.PoolAlreadyInitialized.selector);
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                       stagePoolConfig — ZERO REJECTIONS
    //////////////////////////////////////////////////////////////*/

    function test_StagePoolConfig_WhenZeroAdmin_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.admin = address(0);
        vm.expectRevert(RangeGuardHook.ZeroAdmin.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenZeroInitializer_Reverts() public {
        vm.expectRevert(RangeGuardHook.ZeroInitializer.selector);
        harness.stagePoolConfig(_key(), _validConfig(), address(0), EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenZeroSqrtPrice_Reverts() public {
        vm.expectRevert(RangeGuardHook.ZeroSqrtPrice.selector);
        harness.stagePoolConfig(_key(), _validConfig(), INITIALIZER, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       stagePoolConfig — BOUND VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_StagePoolConfig_WhenNotDynamicFee_Reverts() public {
        PoolKey memory key = _key();
        key.fee = 3000; // static fee
        vm.expectRevert(RangeGuardHook.NotDynamicFee.selector);
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenBaseFeeTooHigh_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.baseLpFeeBps = 10_001; // > MAX_BASE_FEE_BPS
        vm.expectRevert(RangeGuardHook.InvalidFeeConfig.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenBufferFeeTooHigh_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.bufferBps = 5001; // > MAX_BUFFER_BPS
        vm.expectRevert(RangeGuardHook.InvalidFeeConfig.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenAprZero_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.coverageApr = 0;
        vm.expectRevert(RangeGuardHook.InvalidApr.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenAprTooHigh_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.coverageApr = 0.5e18 + 1; // > MAX_COVERAGE_APR
        vm.expectRevert(RangeGuardHook.InvalidApr.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenMaxPayoutPctOfIlExceeds_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.maxPayoutPctOfIl = 10_001; // > MAX_PAYOUT_PCT
        vm.expectRevert(RangeGuardHook.InvalidPayoutCaps.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /// Why: this bound protects the buffer-payout settlement invariant
    /// (payout <= bufferBalanceStable). Critical per testing-strategy.md.
    function test_StagePoolConfig_WhenMaxPayoutPctOfBufferExceedsDenom_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.maxPayoutPctOfBuffer = 10_001; // > BPS_DENOM
        vm.expectRevert(RangeGuardHook.InvalidPayoutCaps.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    function test_StagePoolConfig_WhenUnsupportedDayCount_Reverts() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.secondsPerYear = 31_536_001; // neither A/365F nor A/360
        vm.expectRevert(RangeGuardHook.UnsupportedDayCount.selector);
        harness.stagePoolConfig(_key(), cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                       stagePoolConfig — BOUNDARIES (ACCEPTED)
    //////////////////////////////////////////////////////////////*/

    /// Why: bounds are strict `>` — exact maximums must be accepted, not rejected.
    function test_StagePoolConfig_WhenBoundaryValues_Succeeds() public {
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.baseLpFeeBps = 10_000; // == MAX_BASE_FEE_BPS
        cfg.bufferBps = 5000; // == MAX_BUFFER_BPS
        cfg.coverageApr = 0.5e18; // == MAX_COVERAGE_APR
        cfg.maxPayoutPctOfIl = 10_000; // == MAX_PAYOUT_PCT
        cfg.maxPayoutPctOfBuffer = 10_000; // == BPS_DENOM
        cfg.secondsPerYear = 31_104_000; // A/360 (the other accepted value)
        cfg.maxAccruedCoverageMultiple = 0; // ceiling disabled — valid

        PoolKey memory key = _key();
        harness.stagePoolConfig(key, cfg, INITIALIZER, EXPECTED_SQRT_PRICE);
        assertTrue(harness.exposed_pendingSetup(key.toId()).exists, "boundary config must stage");
    }

    /*//////////////////////////////////////////////////////////////
                       stagePoolConfig — SUCCESS / RE-STAGE
    //////////////////////////////////////////////////////////////*/

    function test_StagePoolConfig_WhenValid_StoresPendingSetup() public {
        (, PoolId poolId) = _stageValid();

        RangeGuardHook.PendingPoolSetup memory pending = harness.exposed_pendingSetup(poolId);
        assertTrue(pending.exists, "pending must exist");
        assertEq(pending.authorizedInitializer, INITIALIZER, "initializer stored");
        assertEq(pending.expectedSqrtPriceX96, EXPECTED_SQRT_PRICE, "price stored");
        assertEq(pending.config.admin, ADMIN, "config admin stored");
        assertEq(pending.config.coverageApr, 0.5e18, "config apr stored");
        assertEq(harness.exposed_poolInitialized(poolId), false, "not initialized yet");
    }

    function test_StagePoolConfig_WhenValid_EmitsPoolConfigStaged() public {
        PoolKey memory key = _key();
        vm.expectEmit(true, false, false, true, address(harness));
        emit PoolConfigStaged(key.toId(), _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /// Why: re-staging before init must overwrite the prior pending setup completely.
    function test_StagePoolConfig_WhenReStagedBeforeInit_Overwrites() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();

        address newInitializer = address(0x2222);
        RangeGuardHook.PoolConfig memory cfg = _validConfig();
        cfg.coverageApr = 0.25e18;
        harness.stagePoolConfig(key, cfg, newInitializer, WRONG_SQRT_PRICE);

        RangeGuardHook.PendingPoolSetup memory pending = harness.exposed_pendingSetup(poolId);
        assertEq(pending.authorizedInitializer, newInitializer, "initializer overwritten");
        assertEq(pending.expectedSqrtPriceX96, WRONG_SQRT_PRICE, "price overwritten");
        assertEq(pending.config.coverageApr, 0.25e18, "config overwritten");
    }

    function test_StagePoolConfig_WhenReStagedAfterInit_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        _commit(key);

        vm.expectRevert(RangeGuardHook.PoolAlreadyInitialized.selector);
        harness.stagePoolConfig(key, _validConfig(), INITIALIZER, EXPECTED_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                       _beforeInitialize — GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_BeforeInitialize_WhenNotPoolManager_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        // Called by a non-PoolManager address -> BaseHook onlyPoolManager guard.
        vm.expectRevert();
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    function test_BeforeInitialize_WhenNotDynamicFee_Reverts() public {
        PoolKey memory key = _key();
        key.fee = 3000;
        vm.prank(address(harness.i_manager()));
        vm.expectRevert(RangeGuardHook.NotDynamicFee.selector);
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    function test_BeforeInitialize_WhenPoolNotStaged_Reverts() public {
        PoolKey memory key = _key(); // never staged
        vm.prank(address(harness.i_manager()));
        vm.expectRevert(RangeGuardHook.PoolNotStaged.selector);
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    function test_BeforeInitialize_WhenUnauthorizedInitializer_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        vm.prank(address(harness.i_manager()));
        vm.expectRevert(RangeGuardHook.UnauthorizedInitializer.selector);
        harness.beforeInitialize(address(0xDEAD), key, EXPECTED_SQRT_PRICE);
    }

    function test_BeforeInitialize_WhenWrongSqrtPrice_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        vm.prank(address(harness.i_manager()));
        vm.expectRevert(RangeGuardHook.UnexpectedSqrtPrice.selector);
        harness.beforeInitialize(INITIALIZER, key, WRONG_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                       _beforeInitialize — COMMIT
    //////////////////////////////////////////////////////////////*/

    function test_BeforeInitialize_WhenValid_CommitsConfig() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();

        vm.prank(address(harness.i_manager()));
        bytes4 selector = harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);

        assertEq(selector, harness.beforeInitialize.selector, "returns beforeInitialize selector");
        assertEq(harness.exposed_poolInitialized(poolId), true, "pool initialized");
        assertEq(harness.exposed_pendingSetup(poolId).exists, false, "pending deleted on commit");

        (uint24 baseLpFeeBps,,,,,,,,,, address admin) = harness.poolConfig(poolId);
        assertEq(baseLpFeeBps, 3000, "committed config readable");
        assertEq(admin, ADMIN, "committed admin readable");
    }

    function test_BeforeInitialize_WhenValid_EmitsPoolConfigInitialized() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();

        vm.expectEmit(true, false, false, true, address(harness));
        emit PoolConfigInitialized(poolId, _validConfig());

        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    /// Why: reactive registration is Phase 3 — after commit, reactiveContract is still zero.
    function test_BeforeInitialize_WhenCommitted_ReactiveStillZero() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();
        _commit(key);

        assertEq(harness.reactiveContract(poolId), address(0), "reactive not set at init");
        assertEq(harness.exposed_reactiveSet(poolId), false, "reactive guard false at init");
    }

    /*//////////////////////////////////////////////////////////////
                       setReactiveContract
    //////////////////////////////////////////////////////////////*/

    function test_SetReactiveContract_WhenNotOwner_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        _commit(key);

        vm.prank(NOT_OWNER);
        vm.expectRevert(RangeGuardHook.NotOwner.selector);
        harness.setReactiveContract(key, REACTIVE);
    }

    function test_SetReactiveContract_WhenPoolNotInitialized_Reverts() public {
        (PoolKey memory key,) = _stageValid(); // staged but not committed
        vm.expectRevert(RangeGuardHook.PoolNotInitialized.selector);
        harness.setReactiveContract(key, REACTIVE);
    }

    function test_SetReactiveContract_WhenZeroReactive_Reverts() public {
        (PoolKey memory key,) = _stageValid();
        _commit(key);

        vm.expectRevert(RangeGuardHook.ZeroReactive.selector);
        harness.setReactiveContract(key, address(0));
    }

    function test_SetReactiveContract_WhenValid_SetsAddress() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();
        _commit(key);

        harness.setReactiveContract(key, REACTIVE);

        assertEq(harness.reactiveContract(poolId), REACTIVE, "reactive address set");
        assertEq(harness.exposed_reactiveSet(poolId), true, "reactive guard locked");
    }

    function test_SetReactiveContract_WhenValid_EmitsReactiveContractSet() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();
        _commit(key);

        vm.expectEmit(true, false, false, true, address(harness));
        emit ReactiveContractSet(poolId, REACTIVE);
        harness.setReactiveContract(key, REACTIVE);
    }

    /// Why: one-time guard — a second call (by the owner) must revert ReactiveAlreadySet,
    /// and the originally-registered address must be unchanged.
    function test_SetReactiveContract_WhenAlreadySet_Reverts() public {
        (PoolKey memory key, PoolId poolId) = _stageValid();
        _commit(key);
        harness.setReactiveContract(key, REACTIVE);

        vm.expectRevert(RangeGuardHook.ReactiveAlreadySet.selector);
        harness.setReactiveContract(key, address(0x9999));

        assertEq(harness.reactiveContract(poolId), REACTIVE, "address unchanged after revert");
    }
}
