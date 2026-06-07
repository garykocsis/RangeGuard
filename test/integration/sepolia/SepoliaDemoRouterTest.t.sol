// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia fork: validates the standalone DemoLPRouter used by the LIVE scripts before any broadcast.
// Proves the position is keyed to the router (v4 sender == router) AND that on withdrawal the IL
// payout (transferred by the hook to the position owner = router) plus the withdrawn principal are
// auto-forwarded to the deployer EOA in the same unlock — leaving the router empty.

import {Vm} from "forge-std/Vm.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SepoliaBaseTest} from "./SepoliaBaseTest.t.sol";
import {DemoLPRouter} from "../../../src/demo/DemoLPRouter.sol";

contract SepoliaDemoRouterTest is SepoliaBaseTest {
    DemoLPRouter internal demoRouter;
    uint8 internal constant LF_IL_CAP = 1;

    function _addViaDemoRouter(int24 tickLower, int24 tickUpper, uint128 liquidity) internal returns (bytes32) {
        // The router settles from its OWN balances, so pre-fund it with token1 + ETH; it sweeps the
        // unused remainder back to the owner (this test) inside the same unlock.
        usdc.mint(address(demoRouter), 1_000_000e6);
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        demoRouter.modifyLiquidity{value: 50 ether}(key, p);
        return _derivePositionKey(address(demoRouter), tickLower, tickUpper);
    }

    function test_Sepolia_DemoRouter_ForwardsPayoutAndPrincipalToDeployer() public {
        demoRouter = new DemoLPRouter(manager, address(this));

        int24 tickLower = _getTickLower();
        int24 tickUpper = _getTickUpper();
        bytes32 positionKey = _addViaDemoRouter(tickLower, tickUpper, DEFAULT_LIQUIDITY);
        _addBackgroundLiquidity(1e14); // depth via the stock router (different owner/key)

        // Position is keyed to the DemoLPRouter (it was the v4 sender).
        assertTrue(_posActive(positionKey), "position keyed to DemoLPRouter is active");

        // Create IL (in range) and hold long enough that the IL cap binds (ClaimSettled, payout > 0).
        // Swap UP (USDC->ETH): the live tick sits near tickLower, so up has room and stays in range.
        _swap(false, 150e6);
        assertTrue(_currentTick() >= tickLower && _currentTick() < tickUpper, "stay in range");
        vm.warp(block.timestamp + 60 days);

        uint256 deployerUsdcBefore = usdc.balanceOf(address(this));

        vm.recordLogs();
        ModifyLiquidityParams memory rm = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(DEFAULT_LIQUIDITY)),
            salt: bytes32(0)
        });
        demoRouter.modifyLiquidity(key, rm);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // ClaimSettled fired for the router-owned position with a positive payout (IL cap binding).
        (bool settled, Vm.Log memory cs) = _findLog(logs, SIG_CLAIM_SETTLED, _poolIdB(), positionKey);
        assertTrue(settled, "ClaimSettled not emitted");
        (,,,, uint256 payout, uint8 factor) = abi.decode(cs.data, (int24, int24, uint256, uint256, uint256, uint8));
        assertEq(factor, LF_IL_CAP, "IL_CAP binds after long hold");
        assertGt(payout, 0, "positive coverage payout");

        // The router auto-forwarded everything: it holds no USDC and no ETH afterwards.
        assertEq(usdc.balanceOf(address(demoRouter)), 0, "router swept all USDC");
        assertEq(address(demoRouter).balance, 0, "router swept all ETH");

        // The deployer EOA received at least the IL payout (principal + payout were forwarded).
        assertGe(usdc.balanceOf(address(this)) - deployerUsdcBefore, payout, "deployer received >= the payout");
        assertFalse(_posActive(positionKey), "position cleared");
    }
}
