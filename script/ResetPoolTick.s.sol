// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {MockUSDC} from "../src/mocks/MockUSDC.sol";

// Demo-recording utility: nudge the live Sepolia pool's tick back toward ~$2,000 (the centre of the
// demo range [-201420, -199320]) so RangeGuardDemo.s.sol opens its position with headroom in BOTH
// directions. Repeated live swaps during testing leave the tick near a boundary; run this before
// recording so the narrative's in-range swaps and the out-of-range crossing behave as scripted.
//
// Mechanism: a SINGLE swap whose `sqrtPriceLimitX96` is the centre tick's sqrt price — the swap moves
// the price toward the centre and STOPS exactly there (unused input is refunded). Up-nudges use
// USDC->ETH (USDC is freely minted; the ETH received is returned to the deployer); down-nudges use
// ETH->USDC with the limit capping how much ETH is spent.
//
// Check first:
//   cast call 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 "getSlot0(...)" <poolId>   (via StateLibrary)
// Run: forge script script/ResetPoolTick.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY -vv
//      (or: make reset-pool-tick).  Dry run: drop --broadcast, add --sender $DEPLOYER_ADDRESS.
contract ResetPoolTick is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant MOCK_USDC = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant SWAP_ROUTER = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant HOOK = 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0;

    int24 internal constant TICK_LOWER = -201420; // ~$1,800
    int24 internal constant TICK_UPPER = -199320; // ~$2,200
    int24 internal constant TARGET_TICK = -200340; // ~$2,000, centre of the demo range
    int24 internal constant TOLERANCE = 120; // already-centred band: TARGET +/- 2 tickSpacings

    IPoolManager internal manager = IPoolManager(POOL_MANAGER);
    MockUSDC internal usdc = MockUSDC(MOCK_USDC);
    PoolSwapTest internal swapRouter = PoolSwapTest(payable(SWAP_ROUTER));
    PoolKey internal key;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(MOCK_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = key.toId();

        (, int24 tickBefore,,) = manager.getSlot0(poolId);
        console.log("tick before:    ", vm.toString(tickBefore));
        console.log("target (centre):", vm.toString(TARGET_TICK));

        int24 diff = tickBefore > TARGET_TICK ? tickBefore - TARGET_TICK : TARGET_TICK - tickBefore;
        if (diff <= TOLERANCE) {
            console.log("Already centred (within tolerance). Nothing to do.");
            _assertInRange(tickBefore);
            return;
        }

        uint160 limit = TickMath.getSqrtPriceAtTick(TARGET_TICK);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startBroadcast(pk);
        if (tickBefore < TARGET_TICK) {
            // Price must rise -> USDC->ETH (oneForZero). Generous exact-input USDC; the limit stops it
            // at the centre and the router refunds the unused USDC + sends the received ETH back.
            usdc.mint(deployer, 5_000_000e6);
            usdc.approve(SWAP_ROUTER, type(uint256).max);
            SwapParams memory p =
                SwapParams({zeroForOne: false, amountSpecified: -int256(5_000_000e6), sqrtPriceLimitX96: limit});
            swapRouter.swap(key, p, settings, "");
        } else {
            // Price must fall -> ETH->USDC (zeroForOne). The limit caps how much ETH is actually spent;
            // unused value is refunded.
            SwapParams memory p =
                SwapParams({zeroForOne: true, amountSpecified: -int256(50 ether), sqrtPriceLimitX96: limit});
            swapRouter.swap{value: 50 ether}(key, p, settings, "");
        }
        vm.stopBroadcast();

        (, int24 tickAfter,,) = manager.getSlot0(poolId);
        console.log("tick after:     ", vm.toString(tickAfter));
        _assertInRange(tickAfter);
        console.log("Pool tick reset toward centre. Ready to record RangeGuardDemo.s.sol.");
    }

    function _assertInRange(int24 tick) internal pure {
        require(tick >= TICK_LOWER && tick < TICK_UPPER, "tick not in demo range after reset");
    }
}
