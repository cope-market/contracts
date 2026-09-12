// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {Config} from "./Config.sol";

/// @notice Re-points the staleness bound on every configured asset, without touching anything else.
///
/// The bound has to stay above the price pusher's cycle time. Change the cadence and this has to
/// follow, so it is an ordinary operation rather than a redeploy.
///
///   VAULT=0x... MAX_AGE_SEC=300 forge script script/SetMaxAge.s.sol --rpc-url arc_testnet --broadcast
///
/// Owner-only, and deliberately narrow: it reads each asset's existing config and rewrites only
/// maxAgeSec, so caps and fees set by hand since deployment survive.
contract SetMaxAge is Script {
    function run() external {
        SyntheticVault vault = SyntheticVault(vm.envAddress("VAULT"));
        uint32 maxAgeSec = uint32(vm.envUint("MAX_AGE_SEC"));

        vm.startBroadcast();
        applyTo(vault, maxAgeSec);
        vm.stopBroadcast();
    }

    /// @dev Exposed so the test exercises the same rewrite the script performs, rather than a
    ///      parallel copy of it that could drift.
    function applyTo(SyntheticVault vault, uint32 maxAgeSec) public {
        require(maxAgeSec != 0, "maxAgeSec must be non-zero");

        bytes32[] memory feeds = vault.enabledFeeds();
        for (uint256 i; i < feeds.length; ++i) {
            (
                bool enabled,,
                uint32 maxConfBps,
                uint32 openFeeBps,
                uint32 closeFeeBps,
                uint128 maxOiUsd,
                uint128 maxPositionUsd
            ) = vault.assetConfig(feeds[i]);

            vault.setAssetConfig(
                feeds[i],
                SyntheticVault.AssetConfig({
                    enabled: enabled,
                    maxAgeSec: maxAgeSec,
                    maxConfBps: maxConfBps,
                    openFeeBps: openFeeBps,
                    closeFeeBps: closeFeeBps,
                    maxOiUsd: maxOiUsd,
                    maxPositionUsd: maxPositionUsd
                })
            );
            console.log("updated maxAgeSec for feed", i, "to", maxAgeSec);
        }
    }
}
