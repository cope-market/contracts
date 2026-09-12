// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice The only price surface the vault knows about.
///
/// Deliberately not `IPyth`. Pyth's pull path does not work on Arc testnet (see SPIKE.md), and
/// Chainlink is the confirmed mainnet fallback, so the vault must not be coupled to either.
interface IPriceOracle {
    struct Price {
        uint256 price; // 1e18, USD
        uint256 conf; // 1e18, confidence interval (half-width)
        uint64 publishTime;
    }

    error PriceUnavailable(bytes32 feedId);
    error StalePrice(bytes32 feedId, uint256 age, uint256 maxAge);
    error InvalidPrice(bytes32 feedId);

    /// @notice Latest price, reverting unless it is at most `maxAge` seconds old.
    function getPrice(bytes32 feedId, uint256 maxAge) external view returns (Price memory);

    /// @notice Native-token fee that `updatePrices` requires for this payload. Zero for push oracles.
    function updateFee(bytes[] calldata updateData) external view returns (uint256);

    /// @notice Posts price data. A no-op for push oracles, which are updated out of band.
    function updatePrices(bytes[] calldata updateData) external payable;
}
