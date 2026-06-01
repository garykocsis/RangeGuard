// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Unit tests for RangeGuardHook._afterRemoveLiquidity() — the v4-native settlement point.
// All settlement logic lives here (eligibility, final accrual, IL, three-cap payout, transfer)
// because the withdrawn amounts only exist in the removal BalanceDelta. The callback is driven
// directly via RangeGuardHookHarness; the underlying PoolManager pool is never initialized so
// getSlot0 returns tick 0 (P_exit == 1e18), making V_HODL / V_actual map 1:1 from raw amounts.
//
// The stable leg (token1) is a real MockERC20 minted to the harness so the payout transfer
// executes (the buffer ledger is notional; real backing simulates seedBuffer()). Positions used
// for pure cap tests are seeded OUT of range so the final _accrue() adds nothing and `earned`
// is exactly the seeded value; an in-range position with elapsed time exercises final accrual.
// Naming per testing-strategy.md: test_Function_WhenCondition_ExpectedBehavior().

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AfterRemoveLiquidityTest is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    // Event mirrors for vm.expectEmit.
    event ClaimSettled(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 ilRaw,
        uint256 earnedCoverage,
        uint256 payout,
        RangeGuardHook.LimitingFactor limitingFactor
    );
    event PartialPayout(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 requested,
        uint256 actual,
        RangeGuardHook.LimitingFactor limitingFactor
    );
    event NoClaim(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 vHodl,
        uint256 vActual
    );
    event IneligibleClaim(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 reason
    );

    RangeGuardHookHarness internal harness;
    MockERC20 internal stable; // token1 (numeraire) — real ERC20 so payouts can transfer

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant LP = address(0x11FE);
    bytes32 internal constant SALT = bytes32(uint256(7));

    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336; // ~1:1
    uint256 internal constant START_TIME = 1_000_000;
    uint32 internal constant MIN_HOLD = 5 minutes;

    // In-range at tick 0; out-of-range at tick 0 (tick 0 sits below [100, 200)).
    int24 internal constant IR_LOWER = -100;
    int24 internal constant IR_UPPER = 100;
    int24 internal constant OOR_LOWER = 100;
    int24 internal constant OOR_UPPER = 200;

    uint128 internal constant LIQUIDITY = 1e18;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
        vm.warp(START_TIME);

        stable = new MockERC20("USDC", "USDC", 6);
        stable.mint(address(harness), 1e30); // real backing for payouts (simulated seedBuffer)

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(stable)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
        poolId = poolKey.toId();
        harness.stagePoolConfig(poolKey, _config(), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, poolKey, EXPECTED_SQRT_PRICE);
    }

    /*//////////////////////////////////////////////////////////////
                                 FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _config() internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = 1000;
        cfg.coverageApr = 0.5e18;
        cfg.secondsPerYear = 31_536_000;
        cfg.minHoldSeconds = MIN_HOLD;
        cfg.maxPayoutPctOfIl = 5000; // 50%
        cfg.maxPayoutPctOfBuffer = 1000; // 10%
        cfg.maxAccruedCoverageMultiple = 3e18;
        cfg.targetBufferSize = 100_000e6;
        cfg.minCheckpointInterval = 2 minutes;
        cfg.admin = ADMIN;
    }

    /// @dev Seeds an active position. `lastAccrualTime == depositTime == START_TIME`; callers
    ///      that warp forward give an in-range position a non-zero accrual window.
    function _seed(int24 lower, int24 upper, uint128 entry0, uint128 entry1, uint256 earned, uint256 notional)
        internal
        returns (bytes32 posKey)
    {
        posKey = harness.exposed_positionKey(LP, lower, upper, SALT);
        RangeGuardHook.PositionState memory pos;
        pos.entryAmt0 = entry0;
        pos.entryAmt1 = entry1;
        pos.tickLower = lower;
        pos.tickUpper = upper;
        pos.depositTime = uint32(START_TIME);
        pos.lastAccrualTime = uint32(START_TIME);
        pos.active = true;
        pos.entryNotionalStable = notional;
        pos.earnedCoverageStable = earned;
        pos.liquidity = LIQUIDITY;
        harness.seedPosition(poolId, posKey, pos);
    }

    function _seedBuffer(uint256 buffer) internal {
        RangeGuardHook.PoolState memory state;
        state.bufferBalanceStable = buffer;
        state.totalSkimmedStable = buffer; // assume buffer arose from skims
        harness.seedPoolState(poolId, state);
    }

    function _params(int24 lower, int24 upper) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: lower,
            tickUpper: upper,
            liquidityDelta: -int256(uint256(LIQUIDITY)),
            salt: SALT
        });
    }

    /// @dev Removal makes the caller delta POSITIVE (the pool owes the LP the withdrawn amounts).
    function _outDelta(uint128 out0, uint128 out1) internal pure returns (BalanceDelta) {
        return toBalanceDelta(int128(out0), int128(out1));
    }

    function _remove(int24 lower, int24 upper, BalanceDelta delta) internal returns (bytes4, BalanceDelta) {
        return harness.exposed_afterRemoveLiquidity(LP, poolKey, _params(lower, upper), delta, toBalanceDelta(0, 0), "");
    }

    function _buffer() internal view returns (uint256 bal, uint256 skim, uint256 paid) {
        return harness.poolState(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                          INELIGIBLE (MIN HOLD)
    //////////////////////////////////////////////////////////////*/

    /// Why: below minHoldSeconds -> hard gate. Emit IneligibleClaim, clear, no accrual/IL/payout,
    /// no transfer, no buffer change. (Withdrawal itself already completed; only the claim is denied.)
    function test_AfterRemoveLiquidity_WhenMinHoldNotMet_EmitsIneligibleAndClears() public {
        bytes32 posKey = _seed(IR_LOWER, IR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        // Only a few seconds elapse — below the 5-minute hold.
        vm.warp(START_TIME + 10);

        vm.expectEmit(true, true, true, true, address(harness));
        emit IneligibleClaim(poolId, posKey, LP, IR_LOWER, IR_UPPER, bytes32("MIN_HOLD_NOT_MET"));
        _remove(IR_LOWER, IR_UPPER, _outDelta(0.5e18, 1e18)); // would be IL if eligible

        assertFalse(harness.getPosition(poolId, posKey).active, "position cleared");
        assertEq(stable.balanceOf(LP), 0, "no payout transferred");
        (uint256 bal,, uint256 paid) = _buffer();
        assertEq(bal, 10e18, "buffer unchanged");
        assertEq(paid, 0, "no payout recorded");
    }

    /*//////////////////////////////////////////////////////////////
                               NO CLAIM (IL == 0)
    //////////////////////////////////////////////////////////////*/

    /// Why: V_actual >= V_HODL -> IL_raw == 0 -> NoClaim with the two valuations, clear, no transfer.
    function test_AfterRemoveLiquidity_WhenNoIL_EmitsNoClaimAndClears() public {
        bytes32 posKey = _seed(IR_LOWER, IR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days); // eligible

        // out == entry -> vHodl == vActual == 2e18 (tick 0, P_exit == 1e18).
        vm.expectEmit(true, true, true, true, address(harness));
        emit NoClaim(poolId, posKey, LP, IR_LOWER, IR_UPPER, 2e18, 2e18);
        _remove(IR_LOWER, IR_UPPER, _outDelta(1e18, 1e18));

        assertFalse(harness.getPosition(poolId, posKey).active, "position cleared");
        assertEq(stable.balanceOf(LP), 0, "no payout on zero IL");
        (uint256 bal,,) = _buffer();
        assertEq(bal, 10e18, "buffer unchanged on no claim");
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM SETTLED (IL CAP BINDS)
    //////////////////////////////////////////////////////////////*/

    /// Why: full eligible coverage paid (IL cap the only binding constraint). ClaimSettled fires,
    /// the LP is paid, the buffer is decremented, totalPaidOut incremented, and the slot cleared.
    function test_AfterRemoveLiquidity_WhenILCapBinds_EmitsClaimSettledAndPays() public {
        // Out of range so the final accrue adds nothing; earned is exactly the seeded 1e18.
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days); // eligible

        // IL_raw = 2e18 - 1.5e18 = 0.5e18; IL_covered = 0.5e18 * 50% = 0.25e18.
        // earned 1e18 and bufferCap (10e18 * 10% = 1e18) both exceed it -> IL cap binds.
        vm.expectEmit(true, true, true, true, address(harness));
        emit ClaimSettled(
            poolId, posKey, LP, OOR_LOWER, OOR_UPPER, 0.5e18, 1e18, 0.25e18, RangeGuardHook.LimitingFactor.IL_CAP
        );
        (bytes4 selector, BalanceDelta returned) = _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18));

        assertEq(selector, harness.afterRemoveLiquidity.selector, "returns afterRemoveLiquidity selector");
        assertTrue(returned == _outDelta(0.5e18, 1e18), "returns the unmodified caller delta");
        assertEq(stable.balanceOf(LP), 0.25e18, "LP paid the capped payout");

        (uint256 bal,, uint256 paid) = _buffer();
        assertEq(bal, 10e18 - 0.25e18, "buffer decremented by payout");
        assertEq(paid, 0.25e18, "totalPaidOut incremented");
        assertFalse(harness.getPosition(poolId, posKey).active, "position cleared after settlement");
        assertEq(harness.getPosition(poolId, posKey).earnedCoverageStable, 0, "earned coverage cleared");
    }

    /*//////////////////////////////////////////////////////////////
                       PARTIAL PAYOUT (COVERAGE / BUFFER)
    //////////////////////////////////////////////////////////////*/

    /// Why: earned coverage below IL_covered -> COVERAGE_CAP binds -> PartialPayout(requested, actual).
    function test_AfterRemoveLiquidity_WhenCoverageCapBinds_EmitsPartialPayout() public {
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 0.1e18, 2e18);
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days);

        // IL_covered = 0.25e18 but earned == 0.1e18 -> payout 0.1e18, coverage cap binds.
        vm.expectEmit(true, true, true, true, address(harness));
        emit PartialPayout(
            poolId, posKey, LP, OOR_LOWER, OOR_UPPER, 0.25e18, 0.1e18, RangeGuardHook.LimitingFactor.COVERAGE_CAP
        );
        _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18));

        assertEq(stable.balanceOf(LP), 0.1e18, "LP paid the coverage-capped amount");
        (uint256 bal,, uint256 paid) = _buffer();
        assertEq(bal, 10e18 - 0.1e18, "buffer decremented by payout");
        assertEq(paid, 0.1e18, "totalPaidOut incremented");
    }

    /// Why: small buffer -> BUFFER_CAP binds below IL_covered and earned -> PartialPayout.
    function test_AfterRemoveLiquidity_WhenBufferCapBinds_EmitsPartialPayout() public {
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 1e18, 2e18);
        _seedBuffer(1e18); // bufferCap = 1e18 * 10% = 0.1e18
        vm.warp(START_TIME + 1 days);

        vm.expectEmit(true, true, true, true, address(harness));
        emit PartialPayout(
            poolId, posKey, LP, OOR_LOWER, OOR_UPPER, 0.25e18, 0.1e18, RangeGuardHook.LimitingFactor.BUFFER_CAP
        );
        _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18));

        assertEq(stable.balanceOf(LP), 0.1e18, "LP paid the buffer-capped amount");
        (uint256 bal,, uint256 paid) = _buffer();
        assertEq(bal, 1e18 - 0.1e18, "buffer decremented by payout");
        assertEq(paid, 0.1e18, "totalPaidOut incremented");
    }

    /// Why: IL > 0 but payout caps to 0 (zero earned) -> PartialPayout(requested>0, actual=0),
    /// never NoClaim (which is strictly IL == 0). No transfer, buffer unchanged, slot cleared.
    function test_AfterRemoveLiquidity_WhenPayoutZeroWithIL_EmitsPartialPayoutZero() public {
        bytes32 posKey = _seed(OOR_LOWER, OOR_UPPER, 1e18, 1e18, 0, 2e18); // earned == 0
        _seedBuffer(10e18);
        vm.warp(START_TIME + 1 days);

        vm.expectEmit(true, true, true, true, address(harness));
        emit PartialPayout(
            poolId, posKey, LP, OOR_LOWER, OOR_UPPER, 0.25e18, 0, RangeGuardHook.LimitingFactor.COVERAGE_CAP
        );
        _remove(OOR_LOWER, OOR_UPPER, _outDelta(0.5e18, 1e18));

        assertEq(stable.balanceOf(LP), 0, "no transfer on zero payout");
        (uint256 bal,, uint256 paid) = _buffer();
        assertEq(bal, 10e18, "buffer unchanged on zero payout");
        assertEq(paid, 0, "no payout recorded");
        assertFalse(harness.getPosition(poolId, posKey).active, "position cleared");
    }

    /*//////////////////////////////////////////////////////////////
                          FINAL ACCRUAL BEFORE PAYOUT
    //////////////////////////////////////////////////////////////*/

    /// Why: settlement must run a final _accrue() before computing the payout. With earned seeded
    /// to 0 and the position in range for one year, the payout can only be non-zero if the final
    /// accrual ran first; here the coverage cap binds at exactly the freshly-accrued amount.
    function test_AfterRemoveLiquidity_WhenInRange_FinalAccrueFeedsPayout() public {
        // entryNotional 2e18, APR 50%, dt = 1 year -> accrued coverage = 1e18.
        bytes32 posKey = _seed(IR_LOWER, IR_UPPER, 2e18, 2e18, 0, 2e18);
        _seedBuffer(100e18); // large: buffer never binds
        vm.warp(START_TIME + 31_536_000); // exactly one year -> dt for accrual

        // IL_raw = 4e18 - 1e18 = 3e18; IL_covered = 1.5e18. Accrued earned = 1e18 < 1.5e18 ->
        // coverage cap binds at the accrued amount, proving the final accrue ran.
        vm.expectEmit(true, true, true, true, address(harness));
        emit PartialPayout(
            poolId, posKey, LP, IR_LOWER, IR_UPPER, 1.5e18, 1e18, RangeGuardHook.LimitingFactor.COVERAGE_CAP
        );
        _remove(IR_LOWER, IR_UPPER, _outDelta(0.5e18, 0.5e18));

        assertEq(stable.balanceOf(LP), 1e18, "payout equals the freshly accrued coverage");
    }

    /*//////////////////////////////////////////////////////////////
                          DEFENSIVE: INACTIVE POSITION
    //////////////////////////////////////////////////////////////*/

    /// Why: if somehow reached for an unregistered position, afterRemoveLiquidity is a no-op
    /// (returns the selector + unchanged delta), never reverting or transferring.
    function test_AfterRemoveLiquidity_WhenInactive_NoOps() public {
        _seedBuffer(10e18);
        BalanceDelta delta = _outDelta(0.5e18, 1e18);
        (bytes4 selector, BalanceDelta returned) = _remove(IR_LOWER, IR_UPPER, delta); // never seeded
        assertEq(selector, harness.afterRemoveLiquidity.selector, "returns selector");
        assertTrue(returned == delta, "returns unchanged delta");
        assertEq(stable.balanceOf(LP), 0, "no transfer for inactive position");
    }
}
