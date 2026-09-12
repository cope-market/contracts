// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../../src/SyntheticVault.sol";
import {LiquidityVault} from "../../src/LiquidityVault.sol";
import {PushOracle} from "../../src/oracle/PushOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice The invariants from ARCHITECTURE.md section 2.6, asserted against randomised sequences
///         of opens, copies, closes, liquidations, price moves and LP flows.
contract VaultInvariantsTest is Test {
    SyntheticVault vault;
    LiquidityVault lv;
    PushOracle oracle;
    MockUSDC usdc;
    VaultHandler handler;

    bytes32 constant EUR = keccak256("FX.EUR/USD");
    bytes32 constant XAU = keccak256("Metal.XAU/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);

        lv = new LiquidityVault(usdc, address(this));
        vault = new SyntheticVault(usdc, oracle, lv, address(this));
        lv.setVault(address(vault));
        lv.setExitFeeBps(10);
        vault.setAuthorFeeBps(1000);

        bytes32[] memory feeds = new bytes32[](2);
        feeds[0] = EUR;
        feeds[1] = XAU;

        for (uint256 i; i < feeds.length; ++i) {
            vault.setAssetConfig(
                feeds[i],
                SyntheticVault.AssetConfig({
                    enabled: true,
                    maxAgeSec: type(uint32).max, // staleness is not what these invariants probe
                    maxConfBps: 100,
                    openFeeBps: 10,
                    closeFeeBps: 10,
                    maxOiUsd: type(uint128).max,
                    maxPositionUsd: type(uint128).max
                })
            );
            oracle.push(feeds[i], 1e18, 0, uint64(block.timestamp));
        }

        // Deep enough that the pool can usually pay, but not so deep that it is never stressed.
        usdc.mint(address(this), 5_000_000e6);
        usdc.approve(address(lv), type(uint256).max);
        lv.deposit(2_000_000e6, address(this));

        handler = new VaultHandler(vault, lv, oracle, usdc, feeds);
        oracle.setPusher(address(handler), true);
        targetContract(address(handler));
    }

    /// @dev Invariant 1. The trading vault holds exactly the collateral of open positions. Any
    ///      drift means a settlement path moved USDC it should not have, in either direction.
    function invariant_VaultHoldsExactlyOpenCollateral() public view {
        uint256 expected;
        uint256 n = handler.openIdCount();
        for (uint256 i; i < n; ++i) {
            try vault.positions(handler.openIds(i)) returns (SyntheticVault.Position memory p) {
                expected += p.collateral;
            } catch {}
        }
        assertEq(usdc.balanceOf(address(vault)), expected, "vault balance must equal open collateral");
    }

    /// @dev Invariant 2. Per-asset aggregates are what the LP vault marks its book against, so if
    ///      they drift from the sum of live positions, NAV is wrong and every LP is mispriced.
    function invariant_AggregatesMatchOpenPositions() public view {
        bytes32[] memory feeds = vault.enabledFeeds();

        for (uint256 f; f < feeds.length; ++f) {
            uint256 longUnits;
            uint256 shortUnits;
            uint256 longNotional;
            uint256 shortNotional;
            uint256 n = handler.openIdCount();

            for (uint256 i; i < n; ++i) {
                try vault.positions(handler.openIds(i)) returns (SyntheticVault.Position memory p) {
                    if (p.feedId != feeds[f]) continue;
                    uint256 notional = p.units * p.entryPrice / 1e18;
                    if (p.isLong) {
                        longUnits += p.units;
                        longNotional += notional;
                    } else {
                        shortUnits += p.units;
                        shortNotional += notional;
                    }
                } catch {}
            }

            (uint256 aggLong, uint256 aggLongNotional, uint256 aggShort, uint256 aggShortNotional) =
                vault.assetState(feeds[f]);
            assertEq(aggLong, longUnits, "long units drifted");
            assertEq(aggShort, shortUnits, "short units drifted");
            // Cost basis, not just quantity. The units-only version of this invariant passed while
            // the aggregate average entry was silently wrong after a selective close.
            assertEq(aggLongNotional, longNotional, "long cost basis drifted");
            assertEq(aggShortNotional, shortNotional, "short cost basis drifted");
        }
    }

    /// @dev Invariant 4. A trader can be wiped out but the protocol must never owe them a negative
    ///      amount, and must never mint a position out of nothing.
    function invariant_EveryOpenPositionIsWellFormed() public view {
        uint256 n = handler.openIdCount();
        for (uint256 i; i < n; ++i) {
            try vault.positions(handler.openIds(i)) returns (SyntheticVault.Position memory p) {
                assertGt(p.entryPrice, 0, "entry price must be set");
                assertGt(p.units, 0, "units must be positive");
                assertNotEq(p.author, address(0), "author must be recorded");
            } catch {}
        }
    }

    /// @dev The LP vault must never report more assets than it holds. Over-reporting would let the
    ///      last LP out redeem value that is not there.
    function invariant_LiquidityVaultNeverOverstatesAssets() public view {
        assertLe(lv.totalAssets(), usdc.balanceOf(address(lv)) + _pendingLosses(), "NAV overstated");
    }

    function _pendingLosses() internal view returns (uint256) {
        int256 owed = vault.totalLiability();
        return owed < 0 ? uint256(-owed) / 1e12 : 0;
    }
}
