// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Wad} from "../libraries/Wad.sol";

/// @notice Pyth adapter. Normalises Pyth's (price, expo) pair to wad and translates Pyth's errors
///         into the common vocabulary, so callers see the same behaviour whichever oracle is live.
///
/// Pyth is a pull oracle: nothing is fresh until someone posts an update. The vault therefore calls
/// `updatePrices` with a signed blob inside the same transaction as every open and close. See
/// SPIKE.md for why that path does not work on Arc testnet today.
contract PythOracle is IPriceOracle {
    IPyth public immutable pyth;

    constructor(IPyth pyth_) {
        pyth = pyth_;
    }

    /// @inheritdoc IPriceOracle
    function getPrice(bytes32 feedId, uint256 maxAge) external view returns (Price memory) {
        PythStructs.Price memory p;

        // Staleness is checked here rather than via getPriceNoOlderThan so the revert carries our
        // own error and the measured age, which the API surfaces directly to users.
        try pyth.getPriceUnsafe(feedId) returns (PythStructs.Price memory raw) {
            p = raw;
        } catch {
            revert PriceUnavailable(feedId);
        }

        if (p.price <= 0) revert InvalidPrice(feedId);

        uint256 publishTime = uint256(uint64(p.publishTime));
        uint256 age = block.timestamp > publishTime ? block.timestamp - publishTime : 0;
        if (age > maxAge) revert StalePrice(feedId, age, maxAge);

        return Price({
            price: _toWad(uint256(uint64(p.price)), p.expo),
            conf: _toWad(uint256(p.conf), p.expo),
            publishTime: uint64(publishTime)
        });
    }

    /// @inheritdoc IPriceOracle
    function updateFee(bytes[] calldata updateData) external view returns (uint256) {
        return pyth.getUpdateFee(updateData);
    }

    /// @inheritdoc IPriceOracle
    function updatePrices(bytes[] calldata updateData) external payable {
        pyth.updatePriceFeeds{value: msg.value}(updateData);
    }

    /// @dev Pyth quotes `value * 10**expo`, with expo almost always negative: -5 for FX, -3 for
    ///      metals, -8 for crypto. Scaling to wad means multiplying by 10**(18 + expo), or dividing
    ///      when the feed is finer than 1e-18.
    function _toWad(uint256 value, int32 expo) internal pure returns (uint256) {
        int256 shift = int256(18) + int256(expo);
        if (shift >= 0) {
            return value * (10 ** uint256(shift));
        }
        return value / (10 ** uint256(-shift));
    }
}
