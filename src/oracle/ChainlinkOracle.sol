// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {Wad} from "../libraries/Wad.sol";

/// @notice Chainlink adapter, kept as the mainnet fallback.
///
/// Chainlink has 30 feeds published for Arc mainnet - including EUR/USD, gold and the crypto
/// majors - but none for Arc testnet and none for equities anywhere on Arc. Pyth is the reverse.
/// Both sit behind IPriceOracle so the choice is a deployment argument, not a rewrite.
contract ChainlinkOracle is IPriceOracle, Ownable {
    uint16 public constant MAX_CONF_BPS = 1000; // 10%
    uint256 internal constant BPS = 1e4;

    mapping(bytes32 feedId => IAggregatorV3) public feeds;

    /// @notice Spread applied as a stand-in for a confidence interval.
    uint16 public syntheticConfBps;

    event FeedSet(bytes32 indexed feedId, address aggregator);
    event SyntheticConfSet(uint16 bps);

    error ConfidenceTooHigh(uint16 requested, uint16 max);
    error UnexpectedValue(uint256 value);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setFeed(bytes32 feedId, address aggregator) external onlyOwner {
        feeds[feedId] = IAggregatorV3(aggregator);
        emit FeedSet(feedId, aggregator);
    }

    /// @dev Chainlink publishes no confidence interval, but the vault skews every trade by conf.
    ///      Without a synthetic spread that protection silently disappears the moment Chainlink
    ///      becomes the live oracle.
    function setSyntheticConfBps(uint16 bps) external onlyOwner {
        if (bps > MAX_CONF_BPS) revert ConfidenceTooHigh(bps, MAX_CONF_BPS);
        syntheticConfBps = bps;
        emit SyntheticConfSet(bps);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(bytes32 feedId, uint256 maxAge) external view returns (Price memory) {
        IAggregatorV3 feed = feeds[feedId];
        if (address(feed) == address(0)) revert PriceUnavailable(feedId);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(feedId);
        // updatedAt of zero means the round never completed. Treating it as a timestamp would make
        // the price look maximally stale rather than invalid, which is a different failure.
        if (updatedAt == 0) revert InvalidPrice(feedId);

        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > maxAge) revert StalePrice(feedId, age, maxAge);

        uint256 price = uint256(answer) * Wad.ONE / (10 ** feed.decimals());

        return Price({price: price, conf: price * syntheticConfBps / BPS, publishTime: uint64(updatedAt)});
    }

    /// @inheritdoc IPriceOracle
    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IPriceOracle
    function updatePrices(bytes[] calldata) external payable {
        // Chainlink is a push oracle; there is nothing to post. Reject value rather than strand it.
        if (msg.value != 0) revert UnexpectedValue(msg.value);
    }
}
