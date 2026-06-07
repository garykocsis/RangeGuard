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
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RangeGuardHook} from "../src/RangeGuardHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {DemoLPRouter} from "../src/demo/DemoLPRouter.sol";

// LIVE Option-B end-to-end driver for the Reactive round-trip on Sepolia <-> Reactive Lasna.
//
// Dry run:   forge script script/LiveEndToEnd.s.sol --fork-url $SEPOLIA_RPC_URL --sender $DEPLOYER_ADDRESS -vvvv
// Broadcast: forge script script/LiveEndToEnd.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY -vvvv
//
// CRITICAL PRE-FLIGHT (Omni callback delivery): the hook MUST hold a RESERVE on the Sepolia Callback
// Proxy or reactive callbacks dispatch on Lasna (lREACT spent) but NEVER land on Sepolia — silently
// (reserves(hook)=0, debt=0, no revert trace). The proxy uses a reserve/depositTo model, NOT the
// hook's raw ETH balance. Fund it once after any hook (re)deploy:  `make fund-hook-proxy`  (i.e.
//   cast send 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA "depositTo(address)" <hook> --value 0.05ether).
// Verify with `make reserves-hook` (cast call <proxy> "reserves(address)(uint256)" <hook>).
//
// Re-runnability: the pool, buffer, MockUSDC, and the persistent DemoLPRouter survive across runs.
// Each run opens a FRESH demo position (bump RUN_SALT for an overlapping one); the wide background
// position is added once and reused. After running, wait 5 minutes (minHoldSeconds=300) then run
// LiveWithdraw.s.sol. The demo position is owned by the DemoLPRouter so the IL payout routes back
// to the deployer EOA on withdrawal.
contract LiveEndToEnd is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant HOOK = 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0;
    address internal constant MOCK_USDC = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant LP_ROUTER = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A;
    address internal constant SWAP_ROUTER = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant REACTIVE = 0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1;
    address internal constant CALLBACK_PROXY = 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA;

    int24 internal constant TICK_LOWER = -201420; // ~$1,800
    int24 internal constant TICK_UPPER = -199320; // ~$2,200
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;

    RangeGuardHook internal hook = RangeGuardHook(payable(HOOK));
    IPoolManager internal manager = IPoolManager(POOL_MANAGER);
    MockUSDC internal usdc = MockUSDC(MOCK_USDC);
    PoolModifyLiquidityTest internal lpRouter = PoolModifyLiquidityTest(payable(LP_ROUTER));
    PoolSwapTest internal swapRouter = PoolSwapTest(payable(SWAP_ROUTER));
    PoolKey internal key;

    function run() external {
        _preflightReactiveNotPaused();

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bytes32 salt = bytes32(vm.envOr("RUN_SALT", uint256(0)));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(MOCK_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        uint128 bgLiq = uint128(vm.envOr("BG_LIQUIDITY", uint256(5e12)));

        _header();

        vm.startBroadcast(pk);

        // Persistent demo router (records the address on first run; reuse via DEMO_LP_ROUTER env).
        DemoLPRouter demoRouter = _resolveDemoRouter(deployer);
        bytes32 positionKey = keccak256(abi.encode(address(demoRouter), TICK_LOWER, TICK_UPPER, salt));

        // Mint + approve. The DemoLPRouter settles from its own balance, so fund it directly.
        usdc.mint(deployer, 5_000_000e6);
        usdc.mint(address(demoRouter), 2_000_000e6);
        usdc.approve(LP_ROUTER, type(uint256).max);
        usdc.approve(SWAP_ROUTER, type(uint256).max);
        console.log("MockUSDC minted and approved");

        // Background depth (added once; reused on re-runs) so the price can cross the demo boundary.
        _ensureBackground(bgLiq);

        _step1Deposit(demoRouter, salt, positionKey);
        _step2InRangeSwap();
        _step3OutOfRange();
        _step4BackInRange();
        _step5Checkpoint(positionKey);

        vm.stopBroadcast();

        _footer(address(demoRouter), positionKey);
    }

    /*//////////////////////////////////////////////////////////////
                                  STEPS
    //////////////////////////////////////////////////////////////*/

    function _step1Deposit(DemoLPRouter demoRouter, bytes32 salt, bytes32 positionKey) internal {
        uint128 demoLiq = uint128(vm.envOr("DEMO_LIQUIDITY", uint256(5e13)));
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(demoLiq)),
            salt: salt
        });
        // Over-send ETH; the router sweeps the unused remainder back to the deployer.
        demoRouter.modifyLiquidity{value: 0.5 ether}(key, p);

        (,,,,,,,, uint256 notional,,) = _pos(positionKey);
        console.log("[Step 1] LP deposit complete");
        console.log("  positionKey:");
        console.logBytes32(positionKey);
        console.log("  entryNotional (USDC 6dp):", notional);
        console.log(string.concat("  Range ticks: [", vm.toString(TICK_LOWER), ", ", vm.toString(TICK_UPPER), "]"));
        console.log("  >>> WATCH Lasna for PositionTracked: https://lasna-omni.reactscan.net/");
    }

    function _step2InRangeSwap() internal {
        uint256 ethIn = vm.envOr("IN_RANGE_SWAP_ETH", uint256(0.01 ether));
        _swap(true, int256(ethIn));
        (uint256 buf,,) = hook.poolState(_poolId());
        console.log("[Step 2] Swap ETH->USDC complete");
        console.log("  newTick:", vm.toString(_tick()));
        console.log("  buffer balance (USDC 6dp):", buf);
        console.log("  TickUpdated emitted -- Lasna evaluating range status");
    }

    function _step3OutOfRange() internal {
        uint256 ethIn = vm.envOr("OUT_SWAP_ETH", uint256(0.08 ether));
        _swap(true, int256(ethIn));
        console.log("[Step 3] Large swap -- tick crossed tickLower (out of range)");
        console.log("  newTick:", vm.toString(_tick()));
        console.log("  tickLower:", vm.toString(TICK_LOWER));
        require(_tick() < TICK_LOWER, "out-of-range push did not cross tickLower (raise OUT_SWAP_ETH)");
        console.log("  >>> WATCH Lasna for RangeTransitionDetected (inRange=false)");
        console.log("  >>> WATCH Sepolia for PositionOutOfRange from Callback Proxy 0xc9f36411...7bDA");
        console.log("      Allow ~2 minutes for Cron + callback delivery");
    }

    function _step4BackInRange() internal {
        uint256 usdcIn = vm.envOr("BACK_SWAP_USDC", uint256(150e6));
        _swap(false, int256(usdcIn));
        console.log("[Step 4] Swap back -- tick crossed tickLower (back in range)");
        console.log("  newTick:", vm.toString(_tick()));
        require(
            _tick() >= TICK_LOWER && _tick() < TICK_UPPER, "back-in swap did not land in range (tune BACK_SWAP_USDC)"
        );
        console.log("  >>> WATCH Lasna for RangeTransitionDetected (inRange=true)");
        console.log("  >>> WATCH Sepolia for PositionBackInRange from Callback Proxy");
    }

    function _step5Checkpoint(bytes32 positionKey) internal {
        // checkpoint() is rate-limited to minCheckpointInterval (120s) since the last accrual. Within
        // this single broadcast bundle barely any time has elapsed since the deposit, so a direct call
        // would revert CheckpointTooSoon. Only call it when genuinely eligible; otherwise note that the
        // Reactive Cron heartbeat (checkpointCallback) is the autonomous accrual driver.
        (,,,,,, uint32 lastAccrual,,,,) = _pos(positionKey);
        if (block.timestamp - lastAccrual >= 120) {
            hook.checkpoint(_poolId(), positionKey);
            (,,,,,,,,, uint256 earned,) = _pos(positionKey);
            console.log("[Step 5] Checkpoint called; earned coverage (USDC 6dp):", earned);
        } else {
            console.log("[Step 5] Checkpoint skipped in-bundle (minCheckpointInterval=120s not elapsed).");
            console.log("         The Cron heartbeat checkpoints autonomously; or run manually later:");
            console.log("         cast send <hook> 'checkpoint(bytes32,bytes32)' <poolId> <positionKey>");
        }
        console.log("[Step 6] Cron heartbeat (~2 min): WATCH Lasna HeartbeatCheckpointFired ->");
        console.log("         Sepolia Checkpointed tx; confirm msg.sender == Callback Proxy 0xc9f36411...7bDA");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _resolveDemoRouter(address deployer) internal returns (DemoLPRouter demoRouter) {
        address existing = vm.envOr("DEMO_LP_ROUTER", address(0));
        if (existing != address(0)) {
            demoRouter = DemoLPRouter(payable(existing));
            console.log("Reusing DemoLPRouter:", existing);
        } else {
            demoRouter = new DemoLPRouter(manager, deployer);
            console.log("Deployed DemoLPRouter:", address(demoRouter));
            console.log("  >>> RECORD in project-status.md and export DEMO_LP_ROUTER for re-runs/withdraw");
        }
    }

    function _ensureBackground(uint128 bgLiq) internal {
        bytes32 bgKey = keccak256(abi.encode(LP_ROUTER, WIDE_LOWER, WIDE_UPPER, bytes32(0)));
        (,,,,,,, bool active,,,) = hook.positions(_poolId(), bgKey);
        if (active) {
            console.log("Background depth already present; reusing.");
            return;
        }
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: WIDE_LOWER,
            tickUpper: WIDE_UPPER,
            liquidityDelta: int256(uint256(bgLiq)),
            salt: bytes32(0)
        });
        lpRouter.modifyLiquidity{value: 0.3 ether}(key, p, "");
        console.log("Background depth added (wide range).");
    }

    function _swap(bool zeroForOne, int256 amountIn) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        if (zeroForOne) {
            swapRouter.swap{value: uint256(amountIn)}(key, params, s, "");
        } else {
            swapRouter.swap(key, params, s, "");
        }
    }

    function _pos(bytes32 positionKey)
        internal
        view
        returns (uint128, uint128, int24, int24, int24, uint32, uint32, bool, uint256, uint256, uint128)
    {
        return hook.positions(_poolId(), positionKey);
    }

    function _poolId() internal view returns (PoolId) {
        return key.toId();
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(_poolId());
    }

    /// @dev Reads the RangeGuardReactive pause byte from Lasna slot 0 (offset 21 from LSB = index 10
    ///      from MSB; matches `cast storage <addr> 0 | cut -c23-24`). Reverts if paused. Skippable via
    ///      CHECK_REACTIVE_PAUSE=false (e.g. when the Lasna RPC is unreachable from the runner).
    function _preflightReactiveNotPaused() internal {
        if (!vm.envOr("CHECK_REACTIVE_PAUSE", true)) {
            console.log("[preflight] reactive pause check skipped (CHECK_REACTIVE_PAUSE=false)");
            return;
        }
        string memory lasna = vm.envOr("LASNA_RPC_URL", string("https://lasna-omni-rpc.rnk.dev/"));
        string memory params = string(abi.encodePacked('["', vm.toString(REACTIVE), '","0x0","latest"]'));
        bytes memory res = vm.rpc(lasna, "eth_getStorageAt", params);
        bytes32 slot0 = bytes32(res);
        bool paused = uint8(slot0[10]) == 0x01;
        require(!paused, "ERROR: RangeGuardReactive is paused -- run resume() on Lasna before proceeding");
        console.log("[preflight] RangeGuardReactive active (not paused)");
    }

    function _header() internal pure {
        console.log("============================================================");
        console.log(" RangeGuard -- LIVE end-to-end (Sepolia <-> Reactive Lasna)");
        console.log("============================================================");
    }

    function _footer(address demoRouter, bytes32 positionKey) internal view {
        (uint256 buf, uint256 skimmed, uint256 paidOut) = hook.poolState(_poolId());
        console.log("------------------------------------------------------------");
        console.log("[Buffer] balance:", buf);
        console.log("         skimmed:", skimmed);
        console.log("         paidOut:", paidOut);
        console.log("");
        console.log("=== WAIT 5 MINUTES (minHoldSeconds=300) before LiveWithdraw.s.sol ===");
        console.log("Export before withdraw:");
        console.log("  export DEMO_LP_ROUTER=", demoRouter);
        console.log("  export POSITION_KEY=", vm.toString(positionKey));
        console.log("  export RUN_SALT=<same salt used here>");
        console.log("poolId:");
        console.logBytes32(PoolId.unwrap(_poolId()));
    }
}
