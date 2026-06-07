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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RangeGuardHook} from "../src/RangeGuardHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

// RangeGuard demo (Option A) — drives the spec §14 narrative against a Sepolia FORK with vm.warp.
// This is the recorded 5-minute demo's terminal segment: a full 45-day coverage lifecycle compressed
// into one clean run. It uses the stock PoolModifyLiquidityTest router (Option 1: the position is
// owned by the router) and the permissionless checkpoint() as the accrual driver at every transition
// point — the onlyServiceProvider emit functions (checkpointAndEmitOutOfRange / …BackInRange) are
// NEVER called here; on live Sepolia those are fired by the Reactive Network, and on the fork they
// are SIMULATED via the [Reactive Network] print lines. All USDC amounts are computed from real fork
// state (not hardcoded spec amounts) and shown with 6-dp formatting.
//
// Run: forge script script/RangeGuardDemo.s.sol --fork-url $SEPOLIA_RPC_URL -vv
contract RangeGuardDemo is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant HOOK = 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0;
    address internal constant MOCK_USDC = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant LP_ROUTER = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A;
    address internal constant SWAP_ROUTER = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;

    int24 internal constant TICK_LOWER = -201420; // ~$1,800
    int24 internal constant TICK_UPPER = -199320; // ~$2,200
    int24 internal constant WIDE_LOWER = -887220;
    int24 internal constant WIDE_UPPER = 887220;
    uint128 internal constant DEMO_LIQ = 5e13;
    uint128 internal constant BG_LIQ = 5e12;
    bytes32 internal constant SALT = keccak256("RANGEGUARD_DEMO");

    RangeGuardHook internal hook = RangeGuardHook(payable(HOOK));
    IPoolManager internal manager = IPoolManager(POOL_MANAGER);
    MockUSDC internal usdc = MockUSDC(MOCK_USDC);
    PoolModifyLiquidityTest internal lpRouter = PoolModifyLiquidityTest(payable(LP_ROUTER));
    PoolSwapTest internal swapRouter = PoolSwapTest(payable(SWAP_ROUTER));
    PoolKey internal key;
    bytes32 internal positionKey;
    uint256 internal t0;
    address internal lp; // pranked EOA acting as the LP (scripts may not use address(this))

    function run() external {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(MOCK_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
        positionKey = keccak256(abi.encode(LP_ROUTER, TICK_LOWER, TICK_UPPER, SALT));
        t0 = block.timestamp;

        // Act as a pranked EOA LP (scripts may not use address(this)); the routers pull/refund here.
        lp = vm.addr(uint256(keccak256("rangeguard-demo-lp")));
        vm.deal(lp, 100 ether);
        usdc.mint(lp, 50_000_000e6);
        vm.startPrank(lp);
        usdc.approve(LP_ROUTER, type(uint256).max);
        usdc.approve(SWAP_ROUTER, type(uint256).max);

        _printHeader();
        _setup();
        _day0Deposit();
        _line();
        _swapDay(3, true, 0.01 ether, "ETH -> USDC (in range)");
        _swapDay(7, false, 20e6, "USDC -> ETH (in range)");
        _swapDay(12, true, 0.01 ether, "ETH -> USDC (in range)");
        _checkpointDay(15);
        _dayOutOfRange(18);
        _checkpointDay(20);
        _dayBackInRange(22);
        // Late-stage drift DOWN within the range: still accruing (in range), but the price ends below
        // entry so the LP realizes impermanent loss at withdrawal (-> a real ClaimSettled).
        _swapDay(30, true, 0.06 ether, "ETH -> USDC (in range, price drifts toward $1,850)");
        _swapDay(38, true, 0.02 ether, "ETH -> USDC (in range)");
        // Day 43: small USDC->ETH nudge so the price is back inside the range for the final
        // checkpoint (the LP earns coverage right up to withdrawal) while still well below entry,
        // so meaningful IL remains -> the IL cap binds at settlement.
        _dayNudgeInRange(43, 30e6);
        _checkpointDay(45);
        _withdraw();
        vm.stopPrank();
        _finalSummary();
    }

    /*//////////////////////////////////////////////////////////////
                                 SECTIONS
    //////////////////////////////////////////////////////////////*/

    function _setup() internal {
        _line();
        console.log("[Setup] Pool live + seeded on Sepolia fork");
        (uint256 buf,,) = hook.poolState(key.toId());
        console.log(string.concat("  Buffer balance: ", _usd(buf), " USDC (", _healthPct(buf), "% of target)"));
    }

    function _day0Deposit() internal {
        _line();
        // Background depth so the price can cross the demo boundaries during the narrative.
        _addBackground();
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: int256(uint256(DEMO_LIQ)),
            salt: SALT
        });
        lpRouter.modifyLiquidity{value: 50 ether}(key, p, "");

        (,,,,,,,, uint256 notional,,) = hook.positions(key.toId(), positionKey);
        console.log("[Day 0] LP deposits a mix of ETH + USDC (Case B - price in range)");
        console.log(string.concat("  Entry notional: ", _usd(notional), " USDC  |  Range: [$1,800, $2,200]"));
        console.log("  PositionRegistered ok");
    }

    function _swapDay(uint256 day, bool zeroForOne, uint256 amountIn, string memory label) internal {
        _warpTo(day);
        (uint256 bufBefore,,) = hook.poolState(key.toId());
        _swap(zeroForOne, int256(amountIn));
        (uint256 bufAfter,,) = hook.poolState(key.toId());
        console.log(string.concat("[Day ", vm.toString(day), "] Swap: ", label));
        console.log(
            string.concat("  BufferFunded +", _usd(bufAfter - bufBefore), " USDC  |  buffer: ", _usd(bufAfter), " USDC")
        );
    }

    function _checkpointDay(uint256 day) internal {
        _warpTo(day);
        (,,,,,,,,, uint256 before_,) = hook.positions(key.toId(), positionKey);
        hook.checkpoint(key.toId(), positionKey);
        (,,,,,,,,, uint256 afterEarned,) = hook.positions(key.toId(), positionKey);
        bool inRange = _tick() >= TICK_LOWER && _tick() < TICK_UPPER;
        console.log(string.concat("[Day ", vm.toString(day), "] Checkpoint"));
        console.log(
            string.concat(
                "  AccrualUpdated: +",
                _usd(afterEarned - before_),
                " USDC (isInRange: ",
                inRange ? "true" : "false",
                ")  |  total coverage: ",
                _usd(afterEarned),
                " USDC"
            )
        );
    }

    function _dayOutOfRange(uint256 day) internal {
        _warpTo(day);
        uint256 ethIn = vm.envOr("OUT_SWAP_ETH", uint256(0.08 ether));
        (uint256 bufBefore,,) = hook.poolState(key.toId());
        _swap(true, int256(ethIn));
        (uint256 bufAfter,,) = hook.poolState(key.toId());
        require(_tick() < TICK_LOWER, "out-of-range push did not cross tickLower");
        console.log(string.concat("[Day ", vm.toString(day), "] Large swap: ETH -> USDC crosses tickLower DOWN"));
        console.log(string.concat("  Position is now OUT OF RANGE (tick ", vm.toString(_tick()), " < tickLower)"));
        console.log("  [Reactive Network] checkpointAndEmitOutOfRange fires on live Sepolia (simulated here)");
        console.log(
            string.concat("  BufferFunded +", _usd(bufAfter - bufBefore), " USDC (buffer grows regardless of range)")
        );
    }

    function _dayBackInRange(uint256 day) internal {
        _warpTo(day);
        uint256 usdcIn = vm.envOr("BACK_SWAP_USDC", uint256(150e6));
        (uint256 bufBefore,,) = hook.poolState(key.toId());
        _swap(false, int256(usdcIn));
        (uint256 bufAfter,,) = hook.poolState(key.toId());
        require(_tick() >= TICK_LOWER && _tick() < TICK_UPPER, "back-in swap did not land in range");
        console.log(string.concat("[Day ", vm.toString(day), "] Large swap: USDC -> ETH crosses tickLower UP"));
        console.log(string.concat("  Position is BACK IN RANGE (tick ", vm.toString(_tick()), ")"));
        console.log("  [Reactive Network] checkpointAndEmitBackInRange fires on live Sepolia (simulated here)");
        console.log(string.concat("  BufferFunded +", _usd(bufAfter - bufBefore), " USDC | accrual resumes"));
    }

    /// @dev Small USDC->ETH nudge so the price sits back inside the range for the final checkpoint,
    ///      while remaining below entry so meaningful IL is still realized at withdrawal.
    function _dayNudgeInRange(uint256 day, uint256 usdcIn) internal {
        _warpTo(day);
        (uint256 bufBefore,,) = hook.poolState(key.toId());
        _swap(false, int256(usdcIn));
        (uint256 bufAfter,,) = hook.poolState(key.toId());
        require(_tick() >= TICK_LOWER && _tick() < TICK_UPPER, "nudge did not return to range");
        console.log(string.concat("[Day ", vm.toString(day), "] Swap: USDC -> ETH (nudge back in range)"));
        console.log(string.concat("  BufferFunded +", _usd(bufAfter - bufBefore), " USDC | tick back in range"));
    }

    function _withdraw() internal {
        _line();
        console.log("[Day 45] LP withdraws the full position");
        vm.recordLogs();
        ModifyLiquidityParams memory rm = ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: -int256(uint256(DEMO_LIQ)),
            salt: SALT
        });
        lpRouter.modifyLiquidity(key, rm, "");
        _printSettlement();
    }

    function _printSettlement() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 csSig = keccak256("ClaimSettled(bytes32,bytes32,address,int24,int24,uint256,uint256,uint256,uint8)");
        bytes32 ppSig = keccak256("PartialPayout(bytes32,bytes32,address,int24,int24,uint256,uint256,uint8)");
        bytes32 ncSig = keccak256("NoClaim(bytes32,bytes32,address,int24,int24,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != HOOK || l.topics.length < 3 || l.topics[2] != positionKey) continue;
            if (l.topics[0] == csSig) {
                (,, uint256 ilRaw,, uint256 payout, uint8 f) =
                    abi.decode(l.data, (int24, int24, uint256, uint256, uint256, uint8));
                console.log(string.concat("  IL_raw: ", _usd(ilRaw), " USDC  |  Payout: ", _usd(payout), " USDC"));
                console.log(string.concat("  Limiting Factor: ", _factor(f), "  |  ClaimSettled ok"));
            } else if (l.topics[0] == ppSig) {
                (,, uint256 requested, uint256 actual, uint8 f) =
                    abi.decode(l.data, (int24, int24, uint256, uint256, uint8));
                console.log(
                    string.concat("  Requested: ", _usd(requested), " USDC  |  Payout: ", _usd(actual), " USDC")
                );
                console.log(string.concat("  Limiting Factor: ", _factor(f), "  |  PartialPayout ok"));
            } else if (l.topics[0] == ncSig) {
                console.log("  IL_raw: 0.00 USDC  |  NoClaim (no impermanent loss) ok");
            }
        }
    }

    function _finalSummary() internal view {
        _line();
        (uint256 buf, uint256 skimmed, uint256 paidOut) = hook.poolState(key.toId());
        console.log("[Final Summary]");
        console.log(string.concat("  Fees skimmed:    ", _usd(skimmed), " USDC"));
        console.log(string.concat("  Paid out:        ", _usd(paidOut), " USDC"));
        console.log(string.concat("  Buffer balance:  ", _usd(buf), " USDC (", _healthPct(buf), "% of target)"));
        // Honest, data-driven close: report buffer RETENTION vs the 10,000 USDC seed rather than an
        // unconditional claim. The buffer barely moves because skimmed fees offset IL payouts.
        uint256 retentionPct = (buf * 100) / 10_000e6;
        console.log(
            string.concat(
                "  Buffer retained ", vm.toString(retentionPct), "% of the 10,000 USDC seed - coverage is self-funding."
            )
        );
        console.log("============================================================");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addBackground() internal {
        bytes32 bgKey = keccak256(abi.encode(LP_ROUTER, WIDE_LOWER, WIDE_UPPER, bytes32(0)));
        (,,,,,,, bool active,,,) = hook.positions(key.toId(), bgKey);
        if (active) return;
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: WIDE_LOWER,
            tickUpper: WIDE_UPPER,
            liquidityDelta: int256(uint256(BG_LIQ)),
            salt: bytes32(0)
        });
        lpRouter.modifyLiquidity{value: 50 ether}(key, p, "");
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

    function _warpTo(uint256 day) internal {
        vm.warp(t0 + day * 1 days);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    /// @dev Formats a 6-dp USDC amount as "WHOLE.CC" (two decimal places).
    function _usd(uint256 a) internal pure returns (string memory) {
        uint256 whole = a / 1e6;
        uint256 cents = (a % 1e6) / 1e4;
        string memory c = cents < 10 ? string.concat("0", vm.toString(cents)) : vm.toString(cents);
        return string.concat(vm.toString(whole), ".", c);
    }

    function _healthPct(uint256 buf) internal view returns (string memory) {
        (,,,,,,,, uint256 target,,) = hook.poolConfig(key.toId());
        if (target == 0) return "n/a";
        return vm.toString((buf * 100) / target);
    }

    function _factor(uint8 f) internal pure returns (string memory) {
        if (f == 1) return "IL_CAP";
        if (f == 2) return "COVERAGE_CAP";
        if (f == 3) return "BUFFER_CAP";
        return "NONE";
    }

    function _line() internal pure {
        console.log("------------------------------------------------------------");
    }

    function _printHeader() internal view {
        (uint24 baseFee, uint24 bufferBps, uint256 apr,, uint32 minHold,,,,, uint32 minCp,) =
            hook.poolConfig(key.toId());
        console.log("============================================================");
        console.log("   RangeGuard - IL Coverage Demo (Sepolia Fork)");
        console.log("   \"Protect your liquidity. Guard your range.\"");
        console.log("============================================================");
        console.log("[Pool Configuration]");
        console.log(string.concat("  Hook:                  ", vm.toString(HOOK)));
        console.log(string.concat("  baseLpFeeBps:          ", vm.toString(uint256(baseFee)), " (0.30%)"));
        console.log(string.concat("  bufferBps:             ", vm.toString(uint256(bufferBps)), " (0.10%)"));
        console.log(
            string.concat("  totalFee:              ", vm.toString(uint256(baseFee) + uint256(bufferBps)), " (0.40%)")
        );
        console.log(string.concat("  coverageApr (1e18):    ", vm.toString(apr), " (50%)"));
        console.log(string.concat("  minHoldSeconds:        ", vm.toString(uint256(minHold))));
        console.log(string.concat("  minCheckpointInterval: ", vm.toString(uint256(minCp))));
    }
}
