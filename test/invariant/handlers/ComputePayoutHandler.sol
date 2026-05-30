// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {RangeGuardHookHarness} from "../../harness/RangeGuardHookHarness.sol";

/// @title ComputePayoutHandler
/// @notice Invariant-test handler that drives RangeGuardHook._computePayoutAmount() with
///         randomized IL / earned / buffer / cap inputs.
/// @dev    Each call records the returned payout and factor plus independently-derived cap
///         values (IL_covered, bufferCap) into ghost variables so the invariant suite can
///         assert the cap bounds and the factor<->payout relation. The percentage caps are
///         bounded to [0, BPS_DENOM] — the valid-config domain enforced at pool init — on
///         which the `payout <= bufferBalance` invariant depends. The core is pure, so no
///         state is seeded and nothing can revert within the bounded domain.
contract ComputePayoutHandler is Test {
    RangeGuardHookHarness public immutable harness;

    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant MAX_AMT = 1e30;

    // Ghosts: last inputs/outputs and the independently-derived cap values.
    uint256 public ghost_lastILRaw;
    uint256 public ghost_lastEarned;
    uint256 public ghost_lastBuffer;
    uint256 public ghost_lastILCovered;
    uint256 public ghost_lastBufferCap;
    uint256 public ghost_lastPayout;
    RangeGuardHook.LimitingFactor public ghost_lastFactor;
    uint256 public ghost_calls;

    constructor(RangeGuardHookHarness _harness) {
        harness = _harness;
    }

    /// @notice Fuzzed action: compute a capped payout for randomized inputs.
    function computePayout(uint256 ilSeed, uint256 earnedSeed, uint256 bufSeed, uint256 pctIlSeed, uint256 pctBufSeed)
        external
    {
        uint256 ILRaw = bound(ilSeed, 0, MAX_AMT);
        uint256 earned = bound(earnedSeed, 0, MAX_AMT);
        uint256 buffer = bound(bufSeed, 0, MAX_AMT);
        uint16 pctIl = uint16(bound(pctIlSeed, 0, BPS_DENOM));
        uint16 pctBuffer = uint16(bound(pctBufSeed, 0, BPS_DENOM));

        (uint256 payout, RangeGuardHook.LimitingFactor factor) =
            harness.exposed_computePayoutAmount(ILRaw, earned, buffer, pctIl, pctBuffer);

        ghost_lastILRaw = ILRaw;
        ghost_lastEarned = earned;
        ghost_lastBuffer = buffer;
        ghost_lastILCovered = FullMath.mulDiv(ILRaw, pctIl, BPS_DENOM);
        ghost_lastBufferCap = FullMath.mulDiv(buffer, pctBuffer, BPS_DENOM);
        ghost_lastPayout = payout;
        ghost_lastFactor = factor;
        ghost_calls++;
    }
}
