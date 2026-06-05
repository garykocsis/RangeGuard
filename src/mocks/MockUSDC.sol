// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Minimal 6-decimal ERC20 standing in for USDC on testnets only.
/// @dev    TESTNET ONLY. `mint` is intentionally permissionless (no access control) so the
///         demo deployer/admin and any LP can self-fund without a faucet. This contract must
///         NEVER be deployed to mainnet — anyone can mint unlimited supply.
contract MockUSDC is ERC20 {
    /// @dev USDC uses 6 decimals; the ERC20 base defaults to 18, so override.
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("Mock USD Coin", "USDC") {}

    /// @notice Returns the token's decimals (6, matching USDC).
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mint `amount` (6-decimal base units) of MockUSDC to `to`.
    /// @dev    No access control — testnet faucet semantics. e.g. 10_000 USDC = 10_000e6.
    /// @param  to      Recipient of the minted tokens.
    /// @param  amount  Amount in 6-decimal base units.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
