// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {HelperConfig} from "./helpers/HelperConfig.s.sol";
import {RangeGuardHook} from "../src/RangeGuardHook.sol";

// Live run: forge script script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook --rpc-url https://sepolia.base.org --chain-id 84532 --broadcast --verify
// Test run: forge script script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook --rpc-url https://sepolia.base.org --chain-id 84532
// Local run: forge script script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook --rpc-url http://localhost:8545 --chain-id 31337

contract DeployRangeGuardHook is Script {
    // https://getfoundry.sh/guides/deterministic-deployments-using-create2/#getting-started
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (RangeGuardHook) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // 1. Initialize the deployment config helper
        HelperConfig helperConfig = new HelperConfig();

        // 2. Destructure the pool manager out of the config struct
        (address poolManager, address lpRouter, address swapRouter) = helperConfig.activeNetworkConfig();

        console.log("PoolManager address:", poolManager);

        // Log out the local routers only if they were deployed (on Anvil)
        if (swapRouter != address(0)) {
            console.log("Local Anvil LP Router:", lpRouter);
            console.log("Local Anvil Swap Router:", swapRouter);
        }

        // Hook contracts must have specific flags encoded in the address
        uint160 permissions = Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_INITIALIZE_FLAG;

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)));
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(RangeGuardHook).creationCode, constructorArgs);

        console.log("Hook address:", predicted);
        console.log("Salt:");
        console.logBytes32(salt);

        // ✅ Deterministic CREATE2 deployment broadcast
        vm.startBroadcast(pk);
        RangeGuardHook rangeGuardHook = new RangeGuardHook{salt: salt}(IPoolManager(address(poolManager)));
        require(address(rangeGuardHook) == predicted, "CREATE2 mismatch");
        vm.stopBroadcast();

        return rangeGuardHook;
    }
}
