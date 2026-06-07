// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {RangeGuardHook} from "../src/RangeGuardHook.sol";
import {DemoLPRouter} from "../src/demo/DemoLPRouter.sol";

// LIVE withdrawal + settlement for the Option-B demo. Closes the demo position opened by
// LiveEndToEnd.s.sol; the DemoLPRouter forwards the withdrawn principal + IL payout to the deployer.
//
// Requires (export from LiveEndToEnd output):
//   export DEMO_LP_ROUTER=0x...   (the router that owns the position)
//   export RUN_SALT=<same salt>   (defaults to 0)
//   export POSITION_KEY=0x...     (optional; derived from the router + demo ticks + salt if unset)
//
// Dry run:   forge script script/LiveWithdraw.s.sol --fork-url $SEPOLIA_RPC_URL --sender $DEPLOYER_ADDRESS -vvvv
// Broadcast: forge script script/LiveWithdraw.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY -vvvv
contract LiveWithdraw is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant HOOK = 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0;
    address internal constant MOCK_USDC = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;

    int24 internal constant TICK_LOWER = -201420;
    int24 internal constant TICK_UPPER = -199320;

    RangeGuardHook internal hook = RangeGuardHook(payable(HOOK));
    PoolKey internal key;

    function run() external {
        address router = vm.envAddress("DEMO_LP_ROUTER");
        require(router != address(0), "ERROR: set DEMO_LP_ROUTER (the DemoLPRouter from LiveEndToEnd)");
        bytes32 salt = bytes32(vm.envOr("RUN_SALT", uint256(0)));
        bytes32 positionKey = keccak256(abi.encode(router, TICK_LOWER, TICK_UPPER, salt));
        // Optional sanity cross-check against an explicitly exported key.
        bytes32 envKey = vm.envOr("POSITION_KEY", bytes32(0));
        require(envKey == bytes32(0) || envKey == positionKey, "ERROR: POSITION_KEY does not match router+salt");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(MOCK_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        PoolId poolId = key.toId();

        // Read the live liquidity to remove (full withdrawal).
        (,,,,,,,, uint256 entryNotional,, uint128 liquidity) = hook.positions(poolId, positionKey);
        require(liquidity > 0, "ERROR: position not active (already withdrawn, or wrong router/salt)");

        vm.startBroadcast(pk);
        vm.recordLogs();
        ModifyLiquidityParams memory rm = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: -int256(uint256(liquidity)),
            salt: salt
        });
        DemoLPRouter(payable(router)).modifyLiquidity(key, rm);
        vm.stopBroadcast();

        _report(poolId, positionKey, entryNotional);
        _bufferHealth(poolId);
        _pauseReminder();
    }

    function _report(PoolId poolId, bytes32 positionKey, uint256 entryNotional) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 csSig = keccak256("ClaimSettled(bytes32,bytes32,address,int24,int24,uint256,uint256,uint256,uint8)");
        bytes32 ppSig = keccak256("PartialPayout(bytes32,bytes32,address,int24,int24,uint256,uint256,uint8)");
        bytes32 ncSig = keccak256("NoClaim(bytes32,bytes32,address,int24,int24,uint256,uint256)");
        bytes32 icSig = keccak256("IneligibleClaim(bytes32,bytes32,address,int24,int24,bytes32)");

        console.log("[Settlement] Withdrawal complete");
        console.log("  entryNotional (USDC 6dp):", entryNotional);

        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != HOOK || l.topics.length < 3 || l.topics[1] != PoolId.unwrap(poolId)) continue;
            if (l.topics[2] != positionKey) continue;
            if (l.topics[0] == csSig) {
                (,, uint256 ilRaw,, uint256 payout, uint8 factor) =
                    abi.decode(l.data, (int24, int24, uint256, uint256, uint256, uint8));
                console.log("  ClaimSettled  IL_raw:", ilRaw);
                console.log("                payout:", payout);
                console.log("                limitingFactor (1=IL,2=COVERAGE,3=BUFFER):", uint256(factor));
            } else if (l.topics[0] == ppSig) {
                (,, uint256 requested, uint256 actual, uint8 factor) =
                    abi.decode(l.data, (int24, int24, uint256, uint256, uint8));
                console.log("  PartialPayout requested:", requested);
                console.log("                actual:", actual);
                console.log("                limitingFactor (1=IL,2=COVERAGE,3=BUFFER):", uint256(factor));
            } else if (l.topics[0] == ncSig) {
                console.log("  NoClaim (IL_raw == 0): no payout owed");
            } else if (l.topics[0] == icSig) {
                console.log("  IneligibleClaim: MIN_HOLD_NOT_MET (held < 300s) -- wait longer and retry");
            }
        }
    }

    function _bufferHealth(PoolId poolId) internal view {
        // The hook has no getBufferHealth view (spec 11, unimplemented); derive from poolState.
        (uint256 buffer, uint256 skimmed, uint256 paidOut) = hook.poolState(poolId);
        (,,,,,,,, uint256 targetBufferSize,,) = hook.poolConfig(poolId);
        uint256 healthPct = targetBufferSize == 0 ? 0 : (buffer * 100) / targetBufferSize;
        console.log("[Buffer] balance:", buffer);
        console.log("         skimmed:", skimmed);
        console.log("         paidOut:", paidOut);
        console.log("         health (pct of target):", healthPct);
    }

    function _pauseReminder() internal pure {
        console.log("");
        console.log("=== Position closed. Pause Cron10 to conserve lREACT: ===");
        console.log(
            "cast send 0x5eb9c8c021fb3474aa1f2d9ee5f53f6dba5ffee1 \"pause()\" --rpc-url https://lasna-omni-rpc.rnk.dev/ --private-key $PRIVATE_KEY"
        );
    }
}
