// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

// Live run:  forge script script/DeployMockUSDC.s.sol:DeployMockUSDC --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --broadcast
// Test run:  forge script script/DeployMockUSDC.s.sol:DeployMockUSDC --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111

/// @notice Phase 1 of the Sepolia bring-up: deploy the testnet MockUSDC (token1) and mint the
///         initial 10,000 USDC seed to the deployer.
/// @dev    The mint recipient is the broadcasting signer (vm.addr(PRIVATE_KEY)). This is the
///         same address that later signs seedBuffer (which does transferFrom(msg.sender, ...))
///         and is set as config.admin — so the holder of the seed and the seedBuffer caller are
///         one address. After this runs, persist the printed address into
///         HelperConfig.MOCK_USDC_SEPOLIA and export MOCK_USDC_ADDRESS for the current session.
contract DeployMockUSDC is Script {
    // Well-known public Anvil dev account #0 — fallback so dry-runs work with zero setup.
    uint256 internal constant DEFAULT_ANVIL_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Initial seed: 10,000 USDC at 6 decimals.
    uint256 internal constant SEED_MINT_AMOUNT = 10_000e6;

    function run() external returns (MockUSDC mockUsdc) {
        uint256 pk = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_PK);
        address signer = vm.addr(pk);
        console.log("Deployer / mint recipient (seedBuffer signer):", signer);

        vm.startBroadcast(pk);
        mockUsdc = new MockUSDC();
        // Mint the seed to the signer — the address that will sign approve + seedBuffer.
        mockUsdc.mint(signer, SEED_MINT_AMOUNT);
        vm.stopBroadcast();

        console.log("MockUSDC deployed at:", address(mockUsdc));
        console.log("Minted (6-dec base units) to signer:", SEED_MINT_AMOUNT);
        console.log("Signer USDC balance:", mockUsdc.balanceOf(signer));
        console.log("NEXT: set HelperConfig.MOCK_USDC_SEPOLIA to the address above, and");
        console.log("      export MOCK_USDC_ADDRESS=<address above>");
    }
}
