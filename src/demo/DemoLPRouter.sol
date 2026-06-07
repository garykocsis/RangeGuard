// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @title DemoLPRouter
/// @notice Minimal standalone Uniswap v4 liquidity router for the RangeGuard LIVE demo scripts only.
/// @dev    It calls `PoolManager.modifyLiquidity` DIRECTLY (it is its own `unlockCallback`), so the
///         hook sees `sender == address(this)`: the RangeGuard position is keyed to this router and
///         any IL-coverage payout (which the hook transfers to the position owner) lands here. After
///         the removal delta is settled, the router auto-forwards everything it holds — withdrawn
///         principal AND the IL payout — to the deployer EOA in the SAME unlock execution, so funds
///         never linger between the removal and the forward. Used by LiveEndToEnd / LiveWithdraw
///         only; fork tests and RangeGuardDemo use the stock PoolModifyLiquidityTest (Option 1).
contract DemoLPRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    /// @notice Recipient of all swept funds (withdrawn principal + IL payout). The deployer EOA.
    address public immutable owner;

    error OnlyManager();
    error EthSweepFailed();

    constructor(IPoolManager _manager, address _owner) {
        manager = _manager;
        owner = _owner;
    }

    /// @dev Receives native ETH taken from the pool (removal) and any ETH refunds.
    receive() external payable {}

    /// @notice Add or remove liquidity; the position is owned by this router. For native-ETH adds,
    ///         send the required ETH as msg.value (and pre-fund this router with token1 for the add).
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(key, params)), (BalanceDelta));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));

        // Direct call -> this router is the position owner (msg.sender to the manager).
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // Negative = owed to the pool (settle); positive = owed to us (take to this router).
        if (a0 < 0) _settle(key.currency0, uint256(uint128(-a0)));
        if (a1 < 0) _settle(key.currency1, uint256(uint128(-a1)));
        if (a0 > 0) manager.take(key.currency0, address(this), uint256(uint128(a0)));
        if (a1 > 0) manager.take(key.currency1, address(this), uint256(uint128(a1)));

        // Auto-forward to the deployer EOA in this same unlock execution. By now the hook has already
        // transferred any IL payout (token1) to this router during modifyLiquidity above, and the
        // withdrawn principal has been taken here — so this forwards both atomically.
        _sweep(key.currency0);
        _sweep(key.currency1);

        return abi.encode(delta);
    }

    /// @dev Pays an owed amount to the PoolManager (native via value; ERC20 via sync+transfer+settle).
    function _settle(Currency currency, uint256 amount) private {
        if (Currency.unwrap(currency) == address(0)) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            manager.settle();
        }
    }

    /// @dev Forwards the router's entire balance of `currency` to the owner (no-op if zero).
    function _sweep(Currency currency) private {
        if (Currency.unwrap(currency) == address(0)) {
            uint256 bal = address(this).balance;
            if (bal > 0) {
                (bool ok,) = owner.call{value: bal}("");
                if (!ok) revert EthSweepFailed();
            }
        } else {
            IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency));
            uint256 bal = token.balanceOf(address(this));
            if (bal > 0) token.transfer(owner, bal);
        }
    }
}
