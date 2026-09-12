// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal Chainlink aggregator surface. Declared locally rather than pulling in the whole
///         Chainlink package for two functions.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
