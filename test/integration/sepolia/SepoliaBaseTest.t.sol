// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Sepolia-fork integration base. Unlike every other suite in this repo, the Sepolia fork tests do
// NOT inherit BaseRangeGuardTest: that base deploys a FRESH hook via the canonical deploy flow,
// whereas these tests must bind to the ALREADY-DEPLOYED, verified live hook on Sepolia and its
// committed (immutable) PoolConfig. They prove the on-chain bytecode + live token wiring behave
// per spec — something a locally-deployed harness hook cannot attest to. This is a deliberate,
// documented deviation from the "all suites inherit BaseRangeGuardTest" rule for fork tests.
//
// IMPORTANT ownership model (v4): the hook receives `sender` = the address that called
// PoolManager.modifyLiquidity, which for the stock PoolModifyLiquidityTest router is the ROUTER
// itself. So the position is keyed to the router address and any IL payout is transferred to the
// router (Option 1). All positionKeys here therefore use the LP router as owner, and payout/balance
// assertions target the router — matching the canonical RemoveLiquidity.t.sol pattern.
//
// The hook has no getCurrentFee/getBufferHealth/getEstimatedPayout views (spec §11, unimplemented),
// so all reads go through the public poolConfig/poolState/positions getters and limitingFactor is
// parsed from the ClaimSettled/PartialPayout event logs.
//
// Run: forge test --match-path "test/integration/sepolia/*" --fork-url $SEPOLIA_RPC_URL -vvvv

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {RangeGuardHook} from "../../../src/RangeGuardHook.sol";
import {MockUSDC} from "../../../src/mocks/MockUSDC.sol";

abstract contract SepoliaBaseTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                          LIVE SEPOLIA ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address internal constant HOOK = 0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0;
    bytes32 internal constant POOL_ID_REF = 0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a;
    address internal constant MOCK_USDC = 0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA;
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant LP_ROUTER = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A; // PoolModifyLiquidityTest
    address internal constant SWAP_ROUTER = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe; // PoolSwapTest
    address internal constant DEPLOYER = 0x193D1F3E085efc80e1027891FaA770E81ECC4A1d;
    address internal constant CALLBACK_PROXY = 0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA;

    /*//////////////////////////////////////////////////////////////
                          DEMO RANGE / CONSTANTS
    //////////////////////////////////////////////////////////////*/

    int24 internal constant TICK_SPACING = 60;
    // Demo range [$1,800, $2,200] for the ETH/USDC pool (token1 = USDC 6-dec, token0 = ETH 18-dec).
    // tickLower = nearest multiple of 60 BELOW the $1,800 price tick (-201365) = -201420.
    // tickUpper = nearest multiple of 60 ABOVE the $2,200 price tick (-199359) = -199320.
    // Current pool tick at ~$2,000 is ~-200312, comfortably inside this range (Case B deposit).
    int24 internal constant DEMO_TICK_LOWER = -201420;
    int24 internal constant DEMO_TICK_UPPER = -199320;

    // Wide background range (aligned to 60, inside TickMath bounds) used to give the pool depth
    // BELOW the demo tickLower so an ETH->USDC swap can actually push the price out of the demo
    // range. On a fresh fork the demo position would otherwise be the pool's only liquidity, and
    // the price could never rest below its own tickLower (no liquidity there to cross into).
    int24 internal constant WIDE_TICK_LOWER = -887220;
    int24 internal constant WIDE_TICK_UPPER = 887220;

    uint256 internal constant FEE_DENOM = 1_000_000;
    uint256 internal constant BPS_DENOM = 10_000;
    // Committed config (immutable on the live hook); mirrored here for assertions.
    uint256 internal constant CFG_BASE_FEE = 3000;
    uint256 internal constant CFG_BUFFER_BPS = 1000;
    uint256 internal constant CFG_MIN_HOLD = 300;
    uint256 internal constant CFG_MIN_CHECKPOINT = 120;

    // A liquidity amount that requires a tractable amount of ETH+USDC in the demo range and gives
    // swaps enough depth to be meaningful without exhausting it on the first trade.
    uint128 internal constant DEFAULT_LIQUIDITY = 5e13;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    RangeGuardHook internal hook;
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    MockUSDC internal usdc;
    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Decoded mirror of the hook's PositionState public getter (field order matters).
    struct Position {
        uint128 entryAmt0;
        uint128 entryAmt1;
        int24 entryTick;
        int24 tickLower;
        int24 tickUpper;
        uint32 depositTime;
        uint32 lastAccrualTime;
        bool active;
        uint256 entryNotionalStable;
        uint256 earnedCoverageStable;
        uint128 liquidity;
    }

    /// @dev The LP/swap routers refund leftover native ETH to msg.sender (this contract); accept it.
    receive() external payable {}

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        hook = RangeGuardHook(payable(HOOK));
        manager = IPoolManager(POOL_MANAGER);
        lpRouter = PoolModifyLiquidityTest(payable(LP_ROUTER));
        swapRouter = PoolSwapTest(payable(SWAP_ROUTER));
        usdc = MockUSDC(MOCK_USDC);

        key = PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH
            currency1: Currency.wrap(MOCK_USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        poolId = key.toId();

        // Sanity: this fork is bound to the real deployed pool.
        require(PoolId.unwrap(poolId) == POOL_ID_REF, "poolId mismatch: pool key does not match live deployment");

        // Fund this test contract richly with ETH + USDC; the routers pull/refund as needed.
        vm.deal(address(this), 100 ether);
        usdc.mint(address(this), 50_000_000e6);
        usdc.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds liquidity over [tickLower, tickUpper] through the stock LP router.
    /// @dev Sends a generous ETH value (excess auto-refunded by the router) and relies on the
    ///      max USDC approval from setUp. The position is owned by the router (v4 `sender`).
    /// @return positionKey The hook-side key: keccak256(abi.encode(LP_ROUTER, tickLower, tickUpper, 0)).
    function _addLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (bytes32 positionKey)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        // 50 ETH covers any in-range add at this liquidity; the router refunds the remainder.
        lpRouter.modifyLiquidity{value: 50 ether}(key, params, "");
        positionKey = _derivePositionKey(LP_ROUTER, tickLower, tickUpper);
    }

    /// @notice Adds a wide-range background position to give the pool depth beyond the demo range so
    ///         swaps can cross the demo boundaries. Uses a UNIQUE salt so it never collides with a
    ///         wide position the live pool may already hold at salt 0 (the live LiveEndToEnd run
    ///         registers one via this same stock router) — otherwise afterAddLiquidity would revert
    ///         PositionAlreadyRegistered against the forked live state.
    function _addBackgroundLiquidity(uint128 liquidity) internal returns (bytes32 positionKey) {
        bytes32 bgSalt = keccak256("RG_FORK_BACKGROUND");
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: WIDE_TICK_LOWER,
            tickUpper: WIDE_TICK_UPPER,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bgSalt
        });
        lpRouter.modifyLiquidity{value: 50 ether}(key, params, "");
        positionKey = keccak256(abi.encode(LP_ROUTER, WIDE_TICK_LOWER, WIDE_TICK_UPPER, bgSalt));
    }

    /// @notice Full withdrawal of a position previously added via `_addLiquidity`.
    function _removeLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidity) internal returns (BalanceDelta) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        return lpRouter.modifyLiquidity(key, params, "");
    }

    /// @notice Exact-input swap. zeroForOne = ETH->USDC (send ETH value); else USDC->ETH (USDC pulled).
    /// @param amountSpecified Exact input as a POSITIVE amount (converted to negative exact-input).
    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 amtIn = uint256(amountSpecified);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountSpecified, // exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        if (zeroForOne) {
            return swapRouter.swap{value: amtIn}(key, params, settings, "");
        }
        return swapRouter.swap(key, params, settings, "");
    }

    /// @notice keccak256(abi.encode(owner, tickLower, tickUpper, bytes32(0))) — matches the hook.
    function _derivePositionKey(address owner_, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner_, tickLower, tickUpper, bytes32(0)));
    }

    function _getTickLower() internal pure returns (int24) {
        return DEMO_TICK_LOWER;
    }

    function _getTickUpper() internal pure returns (int24) {
        return DEMO_TICK_UPPER;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE READ HELPERS
    //////////////////////////////////////////////////////////////*/

    function _poolBuffer() internal view returns (uint256 buffer, uint256 skimmed, uint256 paidOut) {
        (buffer, skimmed, paidOut) = hook.poolState(poolId);
    }

    /// @notice Derived dynamic fee (baseLpFeeBps + bufferBps); the hook has no getCurrentFee view.
    function _derivedFee() internal view returns (uint256) {
        (uint24 baseLpFeeBps, uint24 bufferBps,,,,,,,,,) = hook.poolConfig(poolId);
        return uint256(baseLpFeeBps) + uint256(bufferBps);
    }

    /// @dev Builds the Position view via single-field accessors. Reading all 11 fields in one tuple
    ///      destructuring hits "stack too deep" without via-IR, so each field is read individually
    ///      (gas is irrelevant in a fork test). Only the fields the suites assert on are populated.
    function _getPosition(bytes32 positionKey) internal view returns (Position memory p) {
        p.active = _posActive(positionKey);
        p.earnedCoverageStable = _posEarned(positionKey);
        p.entryNotionalStable = _posEntryNotional(positionKey);
        p.liquidity = _posLiquidity(positionKey);
        (p.tickLower, p.tickUpper) = _posTicks(positionKey);
        p.depositTime = _posDepositTime(positionKey);
        p.lastAccrualTime = _posLastAccrual(positionKey);
    }

    function _posActive(bytes32 k) internal view returns (bool active) {
        (,,,,,,, active,,,) = hook.positions(poolId, k);
    }

    function _posEarned(bytes32 k) internal view returns (uint256 earned) {
        (,,,,,,,,, earned,) = hook.positions(poolId, k);
    }

    function _posEntryNotional(bytes32 k) internal view returns (uint256 notional) {
        (,,,,,,,, notional,,) = hook.positions(poolId, k);
    }

    function _posLiquidity(bytes32 k) internal view returns (uint128 liquidity) {
        (,,,,,,,,,, liquidity) = hook.positions(poolId, k);
    }

    function _posTicks(bytes32 k) internal view returns (int24 tickLower, int24 tickUpper) {
        (,,, tickLower, tickUpper,,,,,,) = hook.positions(poolId, k);
    }

    function _posDepositTime(bytes32 k) internal view returns (uint32 depositTime) {
        (,,,,, depositTime,,,,,) = hook.positions(poolId, k);
    }

    function _posLastAccrual(bytes32 k) internal view returns (uint32 lastAccrualTime) {
        (,,,,,, lastAccrualTime,,,,) = hook.positions(poolId, k);
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    /// @notice The pool id as bytes32 (matches the indexed topic emitted by the hook).
    function _poolIdB() internal view returns (bytes32) {
        return PoolId.unwrap(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                      EVENT SIGNATURES (topic0)
    //////////////////////////////////////////////////////////////*/

    bytes32 internal constant SIG_POSITION_REGISTERED = keccak256(
        "PositionRegistered(bytes32,bytes32,address,int24,int24,uint128,uint128,uint256,int24,uint32,uint256,uint256)"
    );
    bytes32 internal constant SIG_ACCRUAL_UPDATED =
        keccak256("AccrualUpdated(bytes32,bytes32,uint256,uint256,uint256,bool,uint256)");
    bytes32 internal constant SIG_BUFFER_FUNDED = keccak256("BufferFunded(bytes32,uint256,uint256)");
    bytes32 internal constant SIG_TICK_UPDATED = keccak256("TickUpdated(bytes32,int24,uint256)");
    bytes32 internal constant SIG_CHECKPOINTED = keccak256("Checkpointed(bytes32,bytes32,uint256)");
    bytes32 internal constant SIG_CLAIM_SETTLED =
        keccak256("ClaimSettled(bytes32,bytes32,address,int24,int24,uint256,uint256,uint256,uint8)");
    bytes32 internal constant SIG_PARTIAL_PAYOUT =
        keccak256("PartialPayout(bytes32,bytes32,address,int24,int24,uint256,uint256,uint8)");
    bytes32 internal constant SIG_NO_CLAIM = keccak256("NoClaim(bytes32,bytes32,address,int24,int24,uint256,uint256)");
    bytes32 internal constant SIG_INELIGIBLE_CLAIM =
        keccak256("IneligibleClaim(bytes32,bytes32,address,int24,int24,bytes32)");
    bytes32 internal constant SIG_POSITION_CLOSED = keccak256("PositionClosed(bytes32,bytes32,address)");

    /*//////////////////////////////////////////////////////////////
                            LOG SCAN HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Finds the first hook-emitted log matching sig + indexed poolId/positionKey. `found` is
    ///      false if none. Caller captures logs once (getRecordedLogs clears them) and scans many.
    function _findLog(Vm.Log[] memory logs, bytes32 sig, bytes32 t1, bytes32 t2)
        internal
        pure
        returns (bool found, Vm.Log memory hit)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != HOOK) continue;
            if (l.topics.length < 3) continue;
            if (l.topics[0] != sig) continue;
            if (l.topics[1] != t1) continue;
            if (l.topics[2] != t2) continue;
            return (true, l);
        }
    }

    /// @dev True if any hook log with the given topic0 + indexed poolId/positionKey exists.
    function _sawLog(Vm.Log[] memory logs, bytes32 sig, bytes32 t1, bytes32 t2) internal pure returns (bool found) {
        (found,) = _findLog(logs, sig, t1, t2);
    }

    /// @dev Finds the first hook log matching sig + indexed poolId only (for BufferFunded / TickUpdated,
    ///      which index just poolId). Returns the LAST match's via `found`; here returns the first.
    function _findLogPool(Vm.Log[] memory logs, bytes32 sig, bytes32 poolTopic)
        internal
        pure
        returns (bool found, Vm.Log memory hit)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != HOOK) continue;
            if (l.topics.length < 2) continue;
            if (l.topics[0] != sig) continue;
            if (l.topics[1] != poolTopic) continue;
            return (true, l);
        }
    }

    function _sawLogPool(Vm.Log[] memory logs, bytes32 sig, bytes32 poolTopic) internal pure returns (bool found) {
        (found,) = _findLogPool(logs, sig, poolTopic);
    }

    /// @dev True if the 4-byte selector appears anywhere in `data`. Used to assert the inner hook
    ///      error inside a v4 WrappedError (PoolManager wraps hook reverts, embedding the original
    ///      revert reason in its bytes — so vm.expectRevert(selector) would not match directly).
    function _revertDataContains(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    /// @dev Buffer conservation invariant value: bufferBalance + totalPaidOut - totalSkimmed. This
    ///      equals the seeded amount and is constant under swaps (skim) and payouts. Captured before
    ///      and after a settling flow; the two must be equal (see _assertSeedConserved). Returned as
    ///      int256 because totalSkimmed can exceed the buffer once payouts have occurred.
    function _seedConstant() internal view returns (int256) {
        (uint256 buffer, uint256 skimmed, uint256 paidOut) = _poolBuffer();
        return int256(buffer) + int256(paidOut) - int256(skimmed);
    }

    /// @notice The bufferBalanceStable storage slot for this pool, located (not guessed) and verified
    ///         against the public getter by the caller before any vm.store. poolState is the 4th
    ///         declared mapping (slot 3); bufferBalanceStable is field 0 of the PoolState struct.
    function _bufferSlot() internal view returns (bytes32) {
        return keccak256(abi.encode(_poolIdB(), uint256(3)));
    }
}
