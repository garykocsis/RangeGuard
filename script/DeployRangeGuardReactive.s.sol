// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {RangeGuardReactive} from "../src/RangeGuardReactive.sol";

// RangeGuardReactive deploys to the REACTIVE NETWORK (ReactVM), NOT the host chain. It subscribes to
// the hook's events on the host chain (HOOK_CHAIN_ID) and routes callbacks back there, but the
// contract itself runs on ReactVM, so this script broadcasts to $REACTIVE_RPC_URL.
//
// Unlike the hook, the reactive contract has NO hook-flag address constraint, so there is no CREATE2 /
// HookMiner salt mining here — a plain `new` is correct. The payable constructor is funded with ETH at
// deployment for the initial rGas balance.
//
// Required env: HOOK_ADDRESS, CRON_TOPIC.
// Optional env: HOOK_CHAIN_ID (default 11155111 Sepolia), MIN_CHECKPOINT_INTERVAL (default 120),
//               RGAS_FUND_AMOUNT (default 0.01 ether), PRIVATE_KEY (default Anvil key).
//
// Live run (Reactive Network):
//   HOOK_ADDRESS=0x... CRON_TOPIC=<cron10_topic> \
//   forge script script/DeployRangeGuardReactive.s.sol:DeployRangeGuardReactive \
//     --rpc-url $REACTIVE_RPC_URL --broadcast
// Test run (no broadcast):
//   HOOK_ADDRESS=0x... CRON_TOPIC=<cron10_topic> \
//   forge script script/DeployRangeGuardReactive.s.sol:DeployRangeGuardReactive --rpc-url $REACTIVE_RPC_URL

contract DeployRangeGuardReactive is Script {
    // Well-known public Anvil dev account #0. Used only as a fallback so dry runs work with zero
    // setup; real deployments override via PRIVATE_KEY env. Same pattern as DeployRangeGuardHook.
    uint256 internal constant DEFAULT_ANVIL_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Default host chain for the MVP demo (Sepolia). Override via HOOK_CHAIN_ID for other host chains.
    uint256 internal constant DEFAULT_HOOK_CHAIN_ID = 11155111;

    // Default heartbeat time gate (seconds) — 2 minutes, the demo value. Override via env.
    uint256 internal constant DEFAULT_MIN_CHECKPOINT_INTERVAL = 120;

    // Default initial rGas funding sent with the payable constructor. Override via RGAS_FUND_AMOUNT.
    uint256 internal constant DEFAULT_RGAS_FUND_AMOUNT = 0.01 ether;

    function run() external returns (RangeGuardReactive) {
        // envOr keeps dry runs usable without a secret while honoring a real PRIVATE_KEY when set.
        uint256 pk = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_PK);

        // Required: the host-chain hook to observe and the Cron system-event topic to subscribe to.
        // CRON_TOPIC must be sourced from official Reactive Network docs (Cron10 demo / Cron1000 mainnet).
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        uint256 cronTopic = vm.envUint("CRON_TOPIC");

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
