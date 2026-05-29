// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

// IMPORT THE OFFICIAL TESTING ROUTERS
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract HelperConfig is Script {
    // Canonical deployment addresses on Sepolia
    address internal constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant LP_ROUTER_SEPOLIA = 0xB66e5338d66336Ec1fBfe60C282dF5846B6bCee2; // Example public periphery address
    address internal constant SWAP_ROUTER_SEPOLIA = 0xc7b0E7da93e076c32a2656D787FFB0E055B8E9cc;

    // Canonical deployment addresses on Mainnet
    address internal constant POOL_MANAGER_MAINNET = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant LP_ROUTER_MAINNET = 0x0000000000000000000000000000000000000000; // Complete with production addresses
    address internal constant SWAP_ROUTER_MAINNET = 0x0000000000000000000000000000000000000000;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant MAINNET_CHAIN_ID = 1;

    // EXTENDED STRUCT TO HOLD THE ROUTERS
    struct NetworkConfig {
        address poolManager;
        address lpRouter;
        address swapRouter;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaConfig();
        } else if (block.chainid == MAINNET_CHAIN_ID) {
            activeNetworkConfig = getMainnetConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: POOL_MANAGER_SEPOLIA,
            lpRouter: LP_ROUTER_SEPOLIA,
            swapRouter: SWAP_ROUTER_SEPOLIA
        });
    }

    function getMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            poolManager: POOL_MANAGER_MAINNET,
            lpRouter: LP_ROUTER_MAINNET,
            swapRouter: SWAP_ROUTER_MAINNET
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.poolManager != address(0)) {
            return activeNetworkConfig;
        }

        console.log("Deploying actual Uniswap v4 architecture to local Anvil network...");

        vm.startBroadcast();

        // 1. Deploy the real Pool Manager
        PoolManager realPoolManager = new PoolManager(address(this));

        // 2. Deploy the real test routers, passing the newly created PoolManager address
        PoolModifyLiquidityTest realLpRouter = new PoolModifyLiquidityTest(realPoolManager);
        PoolSwapTest realSwapRouter = new PoolSwapTest(realPoolManager);

        vm.stopBroadcast();

        NetworkConfig memory anvilConfig = NetworkConfig({
            poolManager: address(realPoolManager),
            lpRouter: address(realLpRouter),
            swapRouter: address(realSwapRouter)
        });

        console.log("Anvil PoolManager deployed to:", anvilConfig.poolManager);
        console.log("Anvil LP Router deployed to:", anvilConfig.lpRouter);
        console.log("Anvil Swap Router deployed to:", anvilConfig.swapRouter);

        return anvilConfig;
    }
}
