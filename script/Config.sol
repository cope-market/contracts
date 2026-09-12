// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SyntheticVault} from "../src/SyntheticVault.sol";

/// @notice Launch asset list and their risk parameters.
///
/// Feed ids are Pyth's real ids. The set is deliberately limited to feeds our Hermes key is
/// entitled to: AAPL, SPY and NVDA return 403 and would show as permanently broken markets.
/// See SPIKE.md.
library Config {
    bytes32 internal constant FX_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 internal constant METAL_XAU_USD =
        0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;
    bytes32 internal constant CRYPTO_BTC_USD =
        0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant EQUITY_TSLA_USD =
        0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;

    function feeds() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](4);
        ids[0] = FX_EUR_USD;
        ids[1] = METAL_XAU_USD;
        ids[2] = CRYPTO_BTC_USD;
        ids[3] = EQUITY_TSLA_USD;
    }

    /// @notice Staleness bound a live oracle can sustain: FX and crypto publish near-continuously,
    ///         metals and equities trade in sessions.
    /// @dev Only appropriate when prices arrive with every trade, as they do with Pyth's pull model.
    function defaultMaxAge(bytes32 feedId) internal pure returns (uint32) {
        bool continuous = feedId == FX_EUR_USD || feedId == CRYPTO_BTC_USD;
        return continuous ? 60 : 300;
    }

    /// @notice Staleness bound for a deployment fed by an external price pusher.
    ///
    /// @dev The bound has to exceed the pusher's cycle time or trades start reverting between
    ///      cycles. Ten minutes leaves comfortable headroom for a one-minute cron and tolerates a
    ///      missed run. Tightened later with `SetMaxAge` once the cadence is proven.
    uint32 internal constant PUSHED_MAX_AGE_SEC = 600;

    /// @dev Caps start small on purpose. They are the difference between a bad day and an insolvent
    ///      pool, and they are trivially raised later by the owner.
    function configFor(bytes32 feedId, uint32 maxAgeSec)
        internal
        pure
        returns (SyntheticVault.AssetConfig memory)
    {
        return SyntheticVault.AssetConfig({
            enabled: true,
            maxAgeSec: maxAgeSec,
            maxConfBps: 100, // 1%
            openFeeBps: 10, // 0.10%
            closeFeeBps: 10, // 0.10%
            maxOiUsd: 250_000e18,
            maxPositionUsd: 25_000e18
        });
    }
}
