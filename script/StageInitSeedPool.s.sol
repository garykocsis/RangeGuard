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
import {HelperConfig} from "./helpers/HelperConfig.s.sol";
import {RangeGuardHook} from "../src/RangeGuardHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

// Live run: HOOK_ADDRESS=0x.. MOCK_USDC_ADDRESS=0x.. \
//   forge script script/StageInitSeedPool.s.sol:StageInitSeedPool --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --broadcast
// Dry run: drop --broadcast (run AFTER the hook is live so the fork reads it).

/// @notice Phase 3 of the Sepolia bring-up: stage the pool config, initialize the pool, approve,
///         and seed the buffer — in one broadcast, against an already-deployed hook + MockUSDC.
/// @dev    The PoolKey is built ONCE and reused in-memory for staging, initialization, and
///         seeding, so token1 cannot diverge "by one character". token1 is read only from
///         HelperConfig.getStableToken(). A single SQRT_PRICE_X96 constant feeds both
///         stagePoolConfig and initialize, so the _beforeInitialize UnexpectedSqrtPrice guard
///         cannot trip on a mismatch. The signer is owner + authorizedInitializer + admin +
///         seed holder (one address), satisfying onlyOwner / UnauthorizedInitializer /
///         CallerNotAdmin / transferFrom in a single-key MVP flow.
contract StageInitSeedPool is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant DEFAULT_ANVIL_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // sqrtPriceX96 for $2,000/ETH with token0 = ETH (18 dec), token1 = USDC (6 dec).
    // Identical value MUST be used for stagePoolConfig and initialize (UnexpectedSqrtPrice guard).
    uint160 internal constant SQRT_PRICE_X96 = 3543191142285914205922034;

    int24 internal constant TICK_SPACING = 60;

    // Initial buffer seed: 10,000 USDC at 6 decimals (matches the DeployMockUSDC mint).
    uint256 internal constant SEED_AMOUNT = 10_000e6;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", DEFAULT_ANVIL_PK);
        address signer = vm.addr(pk);

        HelperConfig helperConfig = new HelperConfig();
        (address poolManager,,) = helperConfig.activeNetworkConfig();
        address stable = helperConfig.getStableToken(); // ONLY token1 read point
        address hookAddr = vm.envAddress("HOOK_ADDRESS");

        require(stable != address(0), "token1 (MockUSDC) unset: set MOCK_USDC_ADDRESS / MOCK_USDC_SEPOLIA");
        require(hookAddr != address(0), "HOOK_ADDRESS unset");

        console.log("Signer (owner/initializer/admin):", signer);
        console.log("PoolManager:", poolManager);
        console.log("Hook:", hookAddr);
        console.log("token1 (MockUSDC):", stable);

        RangeGuardHook hook = RangeGuardHook(payable(hookAddr));

        // Build the PoolKey ONCE — reused for stage, init, and seed.
        // currency0 = native ETH (address(0) < any token), currency1 = MockUSDC.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(stable),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        PoolId poolId = key.toId();
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));

        // Demo PoolConfig (spec section 14). admin = signer (binds to the seedBuffer caller).
        RangeGuardHook.PoolConfig memory cfg = RangeGuardHook.PoolConfig({
            baseLpFeeBps: 3000, // 0.30%
            bufferBps: 1000, // 0.10%
            coverageApr: 0.5e18, // 50% APR
            secondsPerYear: 31_536_000, // A/365F
            minHoldSeconds: 300, // 5 min
            maxPayoutPctOfIl: 5000, // 50%
            maxPayoutPctOfBuffer: 1000, // 10%
            maxAccruedCoverageMultiple: 3e18, // 3x notional ceiling
            targetBufferSize: 100_000e6, // informational
            minCheckpointInterval: 120, // 2 min
            admin: signer
        });

        vm.startBroadcast(pk);

        // 1. Stage the immutable config (onlyOwner = signer).
        hook.stagePoolConfig(key, cfg, signer, SQRT_PRICE_X96);

        // 2. Initialize the pool at the SAME sqrtPriceX96 (direct EOA->PoolManager call so
        //    _beforeInitialize.sender == signer == authorizedInitializer).
        IPoolManager(poolManager).initialize(key, SQRT_PRICE_X96);

        // 3. CONSTRAINT 2: approve BEFORE seedBuffer. seedBuffer does transferFrom(signer, hook).
        MockUSDC(stable).approve(hookAddr, SEED_AMOUNT);

        // 4. Seed the buffer with real token1 custody (admin = signer).
        hook.seedBuffer(key, SEED_AMOUNT);

        vm.stopBroadcast();

        console.log("Staged + initialized + approved + seeded. Seed amount:", SEED_AMOUNT);
    }
}
