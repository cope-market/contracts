// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Fixed-point helpers for the boundary between USDC (6 decimals) and internal math (1e18).
///
/// Every quantity inside the protocol is a wad. USDC amounts are converted at the edge and nowhere
/// else, so a 6-decimal number and an 18-decimal number can never be added by accident.
library Wad {
    uint256 internal constant ONE = 1e18;

    /// @dev 1e18 / 1e6.
    uint256 internal constant USDC_SCALE = 1e12;

    /// @notice USDC amount to wad. Reverts on overflow.
    function toWad(uint256 amount6) internal pure returns (uint256) {
        return amount6 * USDC_SCALE;
    }

    /// @notice Wad to USDC amount, truncated.
    /// @dev Rounding down is a solvency property: the protocol must never pay a rounded-up amount.
    ///      Sub-micro-USDC dust is left in the contract rather than minted out of thin air.
    function fromWad(uint256 wad) internal pure returns (uint256) {
        return wad / USDC_SCALE;
    }
}
