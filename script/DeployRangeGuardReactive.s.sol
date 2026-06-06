// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RangeGuardReactive} from "../src/RangeGuardReactive.sol";

// RangeGuardReactive deploys to the REACTIVE NETWORK (ReactVM), NOT the host chain. It subscribes to
// the hook's events on the host chain (HOOK_CHAIN_ID) and routes callbacks back there via the
// reactive-lib-omni system contract (SYSTEM.requestCallbackV_1_0), but the contract itself runs on
// ReactVM, so this script broadcasts to the Reactive Network RPC.
//
// TARGET NETWORK — Reactive Lasna (Omni fork) testnet:
//   RPC URL:        https://lasna-omni-rpc.rnk.dev/
//   Chain ID:       5318007
//   Block explorer: https://lasna-omni.reactscan.net/
//   lREACT faucet:  cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
//                     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//                     "request(address)" $DEPLOYER --value 0.1ether
//
// HOST CHAIN — Ethereum Sepolia (where the live hook is deployed):
//   Hook:     0x50cd0E7e046022a9B359ca8725aCb75748FB67C0
//   PoolId:   0xe531d42027094e6563d0838d0fe1c8705172d4feed0e6a5f48a08ca97f2b81cb
//   Chain ID: 11155111
//   Cron10:   0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687
//
// Unlike the hook, the reactive contract has NO hook-flag address constraint, so there is no CREATE2 /
// HookMiner salt mining here — a plain `new` is correct. The payable constructor is funded with lREACT
// at deployment for the initial rGas balance.
//
// rGas budget (reactiveSpec §13.5): Cron10 @ 2-min gate fires ~30 cycles/hr, ≤20 callbacks/cycle,
// 300,000 gas each. Worst case (20 positions) ≈ 180M rGas/hr → ~8.64e9 rGas over 48h. The MVP demo
// runs ONE position, so realistic 48h cost ≈ 30 × 300,000 × 48 ≈ 432M rGas plus a few range
// transitions. The lREACT/rGas price on Lasna sets the exact `--value`; the default below funds 0.05
// lREACT (half a faucet drip), comfortable for the 1-position demo. Override RGAS_FUND_AMOUNT for a
// larger position set. CONFIRM the live rGas price on Lasna before a long unattended run.
//
// Env (all optional, with Lasna demo defaults):
//   HOOK_ADDRESS (default live Sepolia hook), CRON_TOPIC (default Cron10), HOOK_CHAIN_ID (11155111),
//   MIN_CHECKPOINT_INTERVAL (120), RGAS_FUND_AMOUNT (0.05 ether), PRIVATE_KEY (Anvil fallback).
//
// Dry run (no broadcast):
//   forge script script/DeployRangeGuardReactive.s.sol:DeployRangeGuardReactive \
//     --rpc-url https://lasna-omni-rpc.rnk.dev/ --sender $DEPLOYER -vvvv
// Live run:
//   forge script script/DeployRangeGuardReactive.s.sol:DeployRangeGuardReactive \
//     --rpc-url https://lasna-omni-rpc.rnk.dev/ --broadcast --private-key $PRIVATE_KEY -vvvv

contract DeployRangeGuardReactive is Script {
    // Well-known public Anvil dev account #0. Used only as a fallback so dry runs work with zero
    // setup; real deployments override via PRIVATE_KEY env. Same pattern as DeployRangeGuardHook.
    uint256 internal constant DEFAULT_ANVIL_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Live Sepolia hook to observe (Session 11 deployment).
    address internal constant DEFAULT_HOOK_ADDRESS = 0x50cd0E7e046022a9B359ca8725aCb75748FB67C0;

    // Cron10 system-event topic0 on Lasna (2-min demo heartbeat cadence).
    uint256 internal constant DEFAULT_CRON_TOPIC =
        0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    // Default host chain for the MVP demo (Sepolia). Override via HOOK_CHAIN_ID for other host chains.
    uint256 internal constant DEFAULT_HOOK_CHAIN_ID = 11155111;

    // Default heartbeat time gate (seconds) — 2 minutes, the demo value. Override via env.
    uint256 internal constant DEFAULT_MIN_CHECKPOINT_INTERVAL = 120;

    // Default initial rGas funding sent with the payable constructor. Override via RGAS_FUND_AMOUNT.
    uint256 internal constant DEFAULT_RGAS_FUND_AMOUNT = 0.05 ether;

    function run() external returns (RangeGuardReactive) {
        // envOr keeps dry runs usable without a secret while honoring a real PRIVATE_KEY when set.
        uint256 pk = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_PK);

        // Host-chain hook to observe and the Cron system-event topic to subscribe to. Defaults target
        // the live Sepolia demo; override either via env for a different host chain / cadence.
        address hookAddress = vm.envOr("HOOK_ADDRESS", DEFAULT_HOOK_ADDRESS);
        uint256 cronTopic = vm.envOr("CRON_TOPIC", DEFAULT_CRON_TOPIC);

        // Optional, with sensible defaults.
        uint256 hookChainId = vm.envOr("HOOK_CHAIN_ID", DEFAULT_HOOK_CHAIN_ID);
        uint256 minCheckpointInterval = vm.envOr("MIN_CHECKPOINT_INTERVAL", DEFAULT_MIN_CHECKPOINT_INTERVAL);
        uint256 rGasFundAmount = vm.envOr("RGAS_FUND_AMOUNT", DEFAULT_RGAS_FUND_AMOUNT);

        // Deploy to ReactVM, funding the initial rGas via the payable constructor's value.
        vm.startBroadcast(pk);
        RangeGuardReactive reactive =
            new RangeGuardReactive{value: rGasFundAmount}(hookAddress, hookChainId, cronTopic, minCheckpointInterval);
        vm.stopBroadcast();

        console.log("Reactive contract deployed at:", address(reactive));
        console.log("Hook address:                 ", hookAddress);
        console.log("Hook chain id:                ", hookChainId);
        console.log("Cron topic:                   ", cronTopic);
        console.log("Min checkpoint interval (s):  ", minCheckpointInterval);
        console.log("rGas funded (wei):            ", rGasFundAmount);

        return reactive;
    }
}
