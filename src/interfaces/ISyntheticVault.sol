// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The trading side of the protocol, as the liquidity vault sees it.
interface ISyntheticVault {
    /// @notice Net USD the vault owes open positions on one feed, in wad. Negative means traders
    ///         are underwater and the amount is owed to LPs instead.
    function liability(bytes32 feedId) external view returns (int256);

    /// @notice Net USD owed across every enabled feed, in wad.
    function totalLiability() external view returns (int256);

    /// @notice Feeds with a config that has been enabled at least once.
    function enabledFeeds() external view returns (bytes32[] memory);
}
