// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The LP-capital side of the protocol, as the synthetic vault sees it.
/// @dev Losses and fees are settled by transferring USDC to the liquidity vault directly - its
///      balance is its capital - so only the outbound direction needs a call.
interface ILiquidityVault {
    error NotVault(address caller);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @notice Funds a winning close. Callable only by the synthetic vault.
    function payout(address to, uint256 amount) external;
}
