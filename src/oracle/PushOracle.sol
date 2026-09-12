// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice A price oracle updated out of band by a trusted pusher.
///
/// This exists because Pyth's pull path does not work on Arc testnet: update blobs from Hermes are
/// rejected by the Wormhole receiver Arc points at (SPIKE.md). Until that is fixed, testnet needs a
/// price source that actually functions.
///
/// It is centralised by construction. The pusher can set any price, and the vault prices every
/// position against whatever it says. That is acceptable for testnet and for a disclosed hackathon
/// demo; it is not acceptable for mainnet with real value at risk, where `PythOracle` or
/// `ChainlinkOracle` is used instead.
contract PushOracle is IPriceOracle, Ownable {
    mapping(address pusher => bool allowed) public isPusher;
    mapping(bytes32 feedId => Price) private _prices;

    event PusherSet(address indexed pusher, bool allowed);
    event PricePushed(bytes32 indexed feedId, uint256 price, uint256 conf, uint64 publishTime);

    error NotPusher(address caller);
    error UnexpectedValue(uint256 value);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setPusher(address pusher, bool allowed) external onlyOwner {
        isPusher[pusher] = allowed;
        emit PusherSet(pusher, allowed);
    }

    /// @notice Records a price. Rejects zero prices, future timestamps and out-of-order updates.
    /// @dev Monotonic publish times matter: without the check a pusher could replay an older price
    ///      to rewind the market, which is a free option against the vault.
    function push(bytes32 feedId, uint256 price, uint256 conf, uint64 publishTime) external {
        if (!isPusher[msg.sender]) revert NotPusher(msg.sender);
        if (price == 0) revert InvalidPrice(feedId);
        if (publishTime > block.timestamp) revert InvalidPrice(feedId);
        if (publishTime <= _prices[feedId].publishTime) revert InvalidPrice(feedId);

        _prices[feedId] = Price({price: price, conf: conf, publishTime: publishTime});
        emit PricePushed(feedId, price, conf, publishTime);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(bytes32 feedId, uint256 maxAge) external view returns (Price memory) {
        Price memory p = _prices[feedId];
        if (p.publishTime == 0) revert PriceUnavailable(feedId);

        uint256 age = block.timestamp - p.publishTime;
        if (age > maxAge) revert StalePrice(feedId, age, maxAge);

        return p;
    }

    /// @inheritdoc IPriceOracle
    function updateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IPriceOracle
    function updatePrices(bytes[] calldata) external payable {
        // Push oracles are updated out of band; there is nothing to post. The interface is payable
        // because pull oracles charge a fee, so reject value rather than stranding it here.
        if (msg.value != 0) revert UnexpectedValue(msg.value);
    }
}
