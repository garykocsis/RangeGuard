// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Integration tests for the three-phase pool setup through the REAL PoolManager.
// Unlike the unit suite (which calls beforeInitialize directly on the harness), these
// drive PoolManager.initialize() against the canonically-deployed hook to prove the
// Phase-2 commit fires via the live callback and that a reverting commit creates no pool.
// Naming per testing-strategy.md: test_Integration_WhenScenario_ExpectedOutcome().

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";

contract PoolSetupIntegration is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // `manager` and `SQRT_PRICE_1_1` are inherited from Deployers (via BaseRangeGuardTest).
    address internal ownerAddr;
    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);

    function setUp() public override {
        super.setUp();
        manager = rangeGuardHook.i_manager();
        ownerAddr = rangeGuardHook.owner();
    }

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
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

    /// @dev Distinct dynamic-fee key per `salt` so each test uses an independent pool.
    function _key(uint256 salt) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(uint160(0x1000 + salt))),
            currency1: Currency.wrap(address(uint160(0x9000 + salt))),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(rangeGuardHook))
        });
    }

    /// Why: the full happy path — owner stages, authorized initializer initializes through
    /// the real PoolManager, the hook commits, and the config is live and immutable.
    function test_Integration_WhenFullSetupSequence_PoolOperational() public {
        PoolKey memory key = _key(1);
        PoolId poolId = key.toId();

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_1_1);

        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_1_1);

        // Config committed and readable post-init.
        (uint24 baseLpFeeBps,,,,,,,,,, address admin) = rangeGuardHook.poolConfig(poolId);
        assertEq(baseLpFeeBps, 3000, "config committed via live callback");
        assertEq(admin, ADMIN, "admin committed");

        // Reactive not yet registered (Phase 3 deferred).
        assertEq(rangeGuardHook.reactiveContract(poolId), address(0), "reactive zero post-init");

        // Pool now immutable: re-staging reverts.
        vm.prank(ownerAddr);
        vm.expectRevert(RangeGuardHook.PoolAlreadyInitialized.selector);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_1_1);

        // Phase 3 completes the lifecycle.
        vm.prank(ownerAddr);
        rangeGuardHook.setReactiveContract(key, address(0xBEEF));
        assertEq(rangeGuardHook.reactiveContract(poolId), address(0xBEEF), "reactive registered");
    }

    /// Why: an unauthorized initializer makes the Phase-2 commit revert, which reverts
    /// PoolManager.initialize() in full — the pool is never created (no partial state).
    /// Proven by a subsequent authorized initialize succeeding on the same staged pool.
    function test_Integration_WhenUnauthorizedInitializer_PoolNotCreated() public {
        PoolKey memory key = _key(2);

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_1_1);

        // Wrong caller -> hook reverts UnauthorizedInitializer (PoolManager wraps it) ->
        // initialize reverts wholesale. The specific inner cause is pinned by the unit
        // suite; here we assert the whole call reverts so no pool can be created.
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Pool was never created: the staged config survives and a correct init succeeds.
        vm.prank(INITIALIZER);
        manager.initialize(key, SQRT_PRICE_1_1);

        (uint24 baseLpFeeBps,,,,,,,,,,) = rangeGuardHook.poolConfig(key.toId());
        assertEq(baseLpFeeBps, 3000, "pool initializes after the failed attempt");
    }

    /// Why: a wrong init price makes the commit revert (exact-match, no tolerance), so the
    /// pool is never created at a manipulated price.
    function test_Integration_WhenWrongSqrtPrice_PoolNotCreated() public {
        PoolKey memory key = _key(3);

        vm.prank(ownerAddr);
        rangeGuardHook.stagePoolConfig(key, _config(), INITIALIZER, SQRT_PRICE_1_1);

        // Wrong price -> hook reverts UnexpectedSqrtPrice (wrapped by PoolManager) ->
        // initialize reverts wholesale; pool never created at a manipulated price.
        vm.prank(INITIALIZER);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1 + 1);
    }

    /// Why: initializing a pool that was never staged reverts PoolNotStaged through the
    /// real callback — no pool can exist without a committed config.
    function test_Integration_WhenNotStaged_Reverts() public {
        PoolKey memory key = _key(4); // never staged

        // Unstaged pool -> hook reverts PoolNotStaged (wrapped) -> initialize reverts.
        vm.prank(INITIALIZER);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}
