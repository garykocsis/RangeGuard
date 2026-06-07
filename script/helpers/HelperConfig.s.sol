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
    // Canonical Uniswap v4 test routers on Sepolia, used to drive the live demo pool.
    address internal constant LP_ROUTER_SEPOLIA = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A; // PoolModifyLiquidityTest
    address internal constant SWAP_ROUTER_SEPOLIA = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe; // PoolSwapTest

    // token1 (stable numeraire) for the Sepolia demo pool — the deployed MockUSDC (6 decimals).
    // Persisted here right after DeployMockUSDC.s.sol broadcasts so getStableToken() never
    // silently falls back to address(0) in a future session with no MOCK_USDC_ADDRESS env var.
    address internal constant MOCK_USDC_SEPOLIA = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;

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

    /// @notice Single source of truth for the pool's token1 (stable) address.
    /// @dev    Reads the MOCK_USDC_ADDRESS env var first (runtime override used between the
    ///         MockUSDC deploy and the stage/init/seed run), falling back to the persisted
    ///         per-chain constant. Every consumer (PoolKey construction, seedBuffer) MUST read
    ///         token1 from here and never inline an address, so the configured token1 and the
    ///         PoolKey token1 can never diverge.
    function getStableToken() public view returns (address) {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            return vm.envOr("MOCK_USDC_ADDRESS", MOCK_USDC_SEPOLIA);
        }
        // Other chains (mainnet/anvil) supply token1 explicitly via the env var.
        return vm.envOr("MOCK_USDC_ADDRESS", address(0));
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
