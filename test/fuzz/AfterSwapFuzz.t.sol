// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fuzz tests for RangeGuardHook._afterSwap(). Naming per testing-strategy.md:
// testFuzz_Function_Property(). Properties:
//   - the buffer contribution always equals |stableLeg| * bufferBps / FEE_DENOM, for any
//     swap-delta sign/magnitude and any valid bufferBps;
//   - the buffer balance is monotonic non-decreasing across swaps (never reduced by a swap).

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BaseRangeGuardTest} from "../shared/BaseRangeGuardTest.t.sol";
import {RangeGuardHook} from "../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../harness/RangeGuardHookHarness.sol";

contract AfterSwapFuzz is BaseRangeGuardTest {
    using PoolIdLibrary for PoolKey;

    RangeGuardHookHarness internal harness;

    address internal constant INITIALIZER = address(0x1117);
    address internal constant ADMIN = address(0xA11CE);
    address internal constant SWAPPER = address(0x5AFE);
    uint160 internal constant EXPECTED_SQRT_PRICE = 79228162514264337593543950336;
    uint24 internal constant MAX_BUFFER_BPS = 5_000;
    uint256 internal constant FEE_DENOM = 1_000_000;

    function setUp() public override {
        super.setUp();
        harness = new RangeGuardHookHarness(rangeGuardHook.i_manager(), address(this));
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(harness))
        });
    }

    function _config(uint24 bufferFee) internal pure returns (RangeGuardHook.PoolConfig memory cfg) {
        cfg.baseLpFeeBps = 3000;
        cfg.bufferBps = bufferFee;
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

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    }

    function _init(uint24 bufferFee) internal returns (PoolKey memory key, PoolId poolId) {
        key = _key();
        poolId = key.toId();
        harness.stagePoolConfig(key, _config(bufferFee), INITIALIZER, EXPECTED_SQRT_PRICE);
        vm.prank(address(harness.i_manager()));
        harness.beforeInitialize(INITIALIZER, key, EXPECTED_SQRT_PRICE);
    }

    /// @dev Build a signed stable leg from a magnitude + sign without hitting type(int128).min.
    function _signedStable(uint128 mag, bool negative) internal pure returns (int128) {
        return negative ? -int128(mag) : int128(mag);
    }

    function testFuzz_AfterSwap_ContributionMatchesFormula(uint128 stableMag, bool negative, uint24 bufferFee) public {
        stableMag = uint128(bound(stableMag, 0, uint128(type(int128).max)));
        bufferFee = uint24(bound(bufferFee, 0, MAX_BUFFER_BPS));
        (PoolKey memory key, PoolId poolId) = _init(bufferFee);

        BalanceDelta delta = toBalanceDelta(int128(1e18), _signedStable(stableMag, negative));
        harness.exposed_afterSwap(SWAPPER, key, _swapParams(), delta, "");

        uint256 expected = uint256(stableMag) * bufferFee / FEE_DENOM;
        (uint256 buf, uint256 skimmed,) = harness.poolState(poolId);
        assertEq(buf, expected, "buffer == |stableLeg| * bufferBps / FEE_DENOM");
        assertEq(skimmed, expected, "skimmed == contribution");
    }

    /// Property: a swap can only ever grow (or leave unchanged) the buffer — never reduce it.
    function testFuzz_AfterSwap_BufferMonotonicNonDecreasing(
        uint128 magA,
        bool negA,
        uint128 magB,
        bool negB,
        uint24 bufferFee
    ) public {
        magA = uint128(bound(magA, 0, uint128(type(int128).max)));
        magB = uint128(bound(magB, 0, uint128(type(int128).max)));
        bufferFee = uint24(bound(bufferFee, 0, MAX_BUFFER_BPS));
        (PoolKey memory key, PoolId poolId) = _init(bufferFee);

        harness.exposed_afterSwap(
            SWAPPER, key, _swapParams(), toBalanceDelta(int128(1e18), _signedStable(magA, negA)), ""
        );
        (uint256 bufAfterFirst,,) = harness.poolState(poolId);

        harness.exposed_afterSwap(
            SWAPPER, key, _swapParams(), toBalanceDelta(int128(1e18), _signedStable(magB, negB)), ""
        );
        (uint256 bufAfterSecond,,) = harness.poolState(poolId);

        assertGe(bufAfterFirst, 0, "buffer never negative");
        assertGe(bufAfterSecond, bufAfterFirst, "second swap never reduces the buffer");
    }
}
