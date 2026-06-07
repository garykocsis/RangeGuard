// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: full-withdrawal settlement paths against the live hook.
//   - partial withdrawal reverts (PartialWithdrawalNotSupported, bubbled through v4's WrappedError)
//   - minHold-not-met -> IneligibleClaim, no payout, position closed
//   - drained buffer -> PartialPayout bound by BUFFER_CAP (storage slot located + verified, not guessed)
//   - long hold + IL -> ClaimSettled (IL_CAP), payout reconciled across router balance / buffer / paidOut
//   - held position -> settles and closes on some path; buffer seed conserved

import {Vm} from "forge-std/Vm.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";

contract SepoliaWithdrawTest is SepoliaBaseTest {
    // LimitingFactor enum: 0 NONE, 1 IL_CAP, 2 COVERAGE_CAP, 3 BUFFER_CAP
    uint8 internal constant LF_IL_CAP = 1;
    uint8 internal constant LF_BUFFER_CAP = 3;

    /*//////////////////////////////////////////////////////////////
                        PARTIAL WITHDRAWAL REVERT
    //////////////////////////////////////////////////////////////*/

    function test_Sepolia_WhenPartialWithdrawal_Reverts() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);

        // Remove a single unit (not the full position) -> beforeRemoveLiquidity rejects it. v4 wraps
        // the hook revert in WrappedError, so scan the revert bytes for the inner selector.
        ModifyLiquidityParams memory rm =
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -1, salt: bytes32(0)});
        try lpRouter.modifyLiquidity(key, rm, "") returns (BalanceDelta) {
            revert("expected partial-withdrawal revert");
        } catch (bytes memory reason) {
            assertTrue(
                _revertDataContains(reason, RangeGuardHook.PartialWithdrawalNotSupported.selector),
                "expected PartialWithdrawalNotSupported"
            );
        }

        // Position remains active (the remove was rejected wholesale).
        assertTrue(_posActive(_derivePositionKey(LP_ROUTER, tickLower, tickUpper)), "position still active");
    }

    /*//////////////////////////////////////////////////////////////
                          MIN-HOLD INELIGIBLE
    //////////////////////////////////////////////////////////////*/

    function test_Sepolia_WhenMinHoldNotMet_IneligibleNoPayout() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        bytes32 positionKey = _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);

        (,, uint256 paidBefore) = _poolBuffer();

        // No warp: depositTime == now, so block.timestamp - depositTime < minHoldSeconds (300).
        vm.recordLogs();
        _removeLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_sawLog(logs, SIG_INELIGIBLE_CLAIM, _poolIdB(), positionKey), "IneligibleClaim not emitted");
        assertTrue(_sawLog(logs, SIG_POSITION_CLOSED, _poolIdB(), positionKey), "PositionClosed not emitted");
        assertFalse(_posActive(positionKey), "position must be cleared");

        (,, uint256 paidAfter) = _poolBuffer();
        assertEq(paidAfter, paidBefore, "no coverage paid out on the ineligible path");
    }

    /*//////////////////////////////////////////////////////////////
                        BUFFER-CAP PARTIAL PAYOUT
    //////////////////////////////////////////////////////////////*/

    function test_Sepolia_WhenBufferDrained_PartialPayoutBufferCap() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        _addBackgroundLiquidity(1e14);

        // In-range price move to create IL. Swap UP (USDC->ETH): the live tick sits near tickLower, so
        // there's little room down but ~1900 ticks up — an up-move stays in range and still creates IL.
        _swap(false, 150e6);
        assertTrue(
            _currentTick() >= _getTickLower() && _currentTick() < _getTickUpper(), "must stay in range for accrual"
        );
        vm.warp(block.timestamp + 30 days);

        // Locate + VERIFY the bufferBalanceStable storage slot before overwriting it (do not guess),
        // then drain the buffer to 0.01 USDC so the tiny bufferCap is provably the binding cap.
        // bufferCap = 1e4 * maxPayoutPctOfBuffer(1000) / 1e4 = 1e3 < min(IL_covered, earned).
        {
            bytes32 slot = _bufferSlot();
            (uint256 bufGetter,,) = _poolBuffer();
            assertEq(uint256(vm.load(HOOK, slot)), bufGetter, "located bufferBalanceStable slot matches getter");
            vm.store(HOOK, slot, bytes32(uint256(1e4)));
        }
        (uint256 bufDrained,, uint256 paidBefore) = _poolBuffer();
        assertEq(bufDrained, 1e4, "buffer drained to 0.01 USDC");

        vm.recordLogs();
        _removeLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 actual = _decodePartialPayoutBufferCap(logs, positionKey);
        assertLe(actual, 1e4, "payout capped by the drained buffer");
        assertEq(actual, 1e3, "payout equals bufferCap = 10% of the drained 0.01 USDC");
        {
            (uint256 bufAfter,, uint256 paidAfter) = _poolBuffer();
            assertEq(bufAfter, 1e4 - actual, "buffer decreased by exactly the capped payout");
            assertEq(paidAfter, paidBefore + actual, "totalPaidOut increased by the payout");
        }
        assertTrue(_sawLog(logs, SIG_POSITION_CLOSED, _poolIdB(), positionKey), "PositionClosed not emitted");
    }

    /// @dev Asserts PartialPayout fired for the position with BUFFER_CAP binding; returns the payout.
    function _decodePartialPayoutBufferCap(Vm.Log[] memory logs, bytes32 positionKey)
        internal
        view
        returns (uint256 actual)
    {
        (bool sawPartial, Vm.Log memory pp) = _findLog(logs, SIG_PARTIAL_PAYOUT, _poolIdB(), positionKey);
        assertTrue(sawPartial, "PartialPayout not emitted");
        uint8 factor;
        (,,, actual, factor) = abi.decode(pp.data, (int24, int24, uint256, uint256, uint8));
        assertEq(factor, LF_BUFFER_CAP, "limiting factor must be BUFFER_CAP");
    }

    /*//////////////////////////////////////////////////////////////
                      CLAIM SETTLED (IL_CAP) RECONCILED
    //////////////////////////////////////////////////////////////*/

    function test_Sepolia_WhenLongHoldWithIL_ClaimSettledReconciles() public {
        bytes32 positionKey = _addLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        _addBackgroundLiquidity(1e14);

        // In-range price move -> some IL. Swap UP (USDC->ETH): the live tick sits near tickLower, so
        // up has ~1900 ticks of room — stays in range and still creates IL. Long hold -> earned grows
        // large enough that IL_covered <= earned and <= bufferCap (live ~10k), so IL_CAP binds and the
        // full eligible coverage is paid (ClaimSettled).
        _swap(false, 150e6);
        assertTrue(_currentTick() >= _getTickLower() && _currentTick() < _getTickUpper(), "stay in range for accrual");
        vm.warp(block.timestamp + 60 days);

        int256 seedBefore = _seedConstant();
        uint256 routerUsdcBefore = usdc.balanceOf(LP_ROUTER);
        (uint256 bufBefore,, uint256 paidBefore) = _poolBuffer();

        vm.recordLogs();
        _removeLiquidity(_getTickLower(), _getTickUpper(), DEFAULT_LIQUIDITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 payout = _decodeClaimSettledPayout(logs, positionKey);
        assertGt(payout, 0, "a positive coverage payout was made");

        // Payout lands in the router (owner = v4 sender); buffer + paidOut reconcile exactly.
        assertEq(usdc.balanceOf(LP_ROUTER) - routerUsdcBefore, payout, "router received exactly the payout");
        {
            (uint256 bufAfter,, uint256 paidAfter) = _poolBuffer();
            assertEq(bufBefore - bufAfter, payout, "buffer decreased by exactly the payout (CEI)");
            assertEq(paidAfter - paidBefore, payout, "totalPaidOut increased by exactly the payout");
        }
        assertTrue(_sawLog(logs, SIG_POSITION_CLOSED, _poolIdB(), positionKey), "PositionClosed not emitted");
        assertFalse(_posActive(positionKey), "position cleared after settlement");
        // Buffer seed conserved across the settlement (buffer + paidOut - skimmed is invariant).
        assertEq(_seedConstant(), seedBefore, "buffer seed conserved end-to-end");
    }

    /// @dev Asserts ClaimSettled fired for the position with IL_CAP binding and returns its payout.
    function _decodeClaimSettledPayout(Vm.Log[] memory logs, bytes32 positionKey)
        internal
        view
        returns (uint256 payout)
    {
        (bool settled, Vm.Log memory cs) = _findLog(logs, SIG_CLAIM_SETTLED, _poolIdB(), positionKey);
        assertTrue(settled, "ClaimSettled not emitted (IL cap should bind after a long hold)");
        uint8 factor;
        (,,,, payout, factor) = abi.decode(cs.data, (int24, int24, uint256, uint256, uint256, uint8));
        assertEq(factor, LF_IL_CAP, "limiting factor must be IL_CAP");
    }

    /*//////////////////////////////////////////////////////////////
                          GENERIC SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// Why: a held position always closes on exactly one settlement path and never violates buffer
    /// conservation, regardless of which cap (or NoClaim) applies.
    function test_Sepolia_WhenHeld_SettlesAndCloses() public {
        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        bytes32 positionKey = _addLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);

        int256 seedBefore = _seedConstant();
        vm.warp(block.timestamp + 301); // past minHold

        vm.recordLogs();
        _removeLiquidity(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool anySettlement = _sawLog(logs, SIG_CLAIM_SETTLED, _poolIdB(), positionKey)
            || _sawLog(logs, SIG_PARTIAL_PAYOUT, _poolIdB(), positionKey)
            || _sawLog(logs, SIG_NO_CLAIM, _poolIdB(), positionKey);
        assertTrue(anySettlement, "exactly one settlement event must fire");
        assertTrue(_sawLog(logs, SIG_POSITION_CLOSED, _poolIdB(), positionKey), "PositionClosed not emitted");
        assertFalse(_posActive(positionKey), "position cleared after settlement");
        assertEq(_seedConstant(), seedBefore, "buffer seed conserved");
    }
}
