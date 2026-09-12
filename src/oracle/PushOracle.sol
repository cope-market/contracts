// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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
    error LengthMismatch();

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
        _push(feedId, price, conf, publishTime);
    }

    /// @notice Records several prices in one transaction.
    ///
    /// @dev The price pusher writes every configured feed each cycle. One call per feed multiplies
    ///      both the gas and the number of ways a cycle can half-succeed.
    ///
    ///      All-or-nothing on purpose: a batch that silently skipped bad entries would leave the
    ///      pusher believing it had refreshed a feed it had not, and the vault would keep trading
    ///      against a stale price. Callers filter before submitting, using `lastPublishTime`.
    function pushMany(
        bytes32[] calldata feedIds,
        uint256[] calldata prices,
        uint256[] calldata confs,
        uint64[] calldata publishTimes
    ) external {
        if (!isPusher[msg.sender]) revert NotPusher(msg.sender);

        uint256 n = feedIds.length;
        if (prices.length != n || confs.length != n || publishTimes.length != n) revert LengthMismatch();

        for (uint256 i; i < n; ++i) {
            _push(feedIds[i], prices[i], confs[i], publishTimes[i]);
        }
    }

    /// @notice Publish time currently stored for a feed, or zero if it has never been written.
    /// @dev Lets the pusher skip feeds with no newer data. Hermes keeps returning the same publish
    ///      time while a market is closed, and re-posting it would revert the whole batch.
    function lastPublishTime(bytes32 feedId) external view returns (uint64) {
        return _prices[feedId].publishTime;
    }

    function _push(bytes32 feedId, uint256 price, uint256 conf, uint64 publishTime) internal {
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
