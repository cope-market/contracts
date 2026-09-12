// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultLiabilityTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    bytes32 constant EUR = keccak256("FX.EUR/USD");
    bytes32 constant XAU = keccak256("Metal.XAU/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        _configure(EUR);
        _configure(XAU);
        _price(EUR, 1e18);
        _price(XAU, 1e18);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(lp), 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _configure(bytes32 feed) internal {
        vault.setAssetConfig(
            feed,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: 3600,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: 0,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );
    }

    function _price(bytes32 feed, uint256 p) internal {
        skip(1);
        oracle.push(feed, p, 0, uint64(block.timestamp));
    }

    function _open(bytes32 feed, bool isLong, uint128 collateral) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(feed, isLong, collateral, 0, new bytes[](0));
    }

    function test_ZeroWhenNoPositions() public view {
        assertEq(vault.liability(EUR), int256(0));
        assertEq(vault.totalLiability(), int256(0));
    }

    function test_PositiveWhenLongsAreWinning() public {
        _open(EUR, true, 1_000e6);
        _price(EUR, 1.2e18);
        assertEq(vault.liability(EUR), int256(200e18), "vault owes traders 200 USD");
    }

    function test_NegativeWhenLongsAreLosing() public {
        _open(EUR, true, 1_000e6);
        _price(EUR, 0.8e18);
        assertEq(vault.liability(EUR), -int256(200e18), "traders owe the pool 200 USD");
    }

    function test_PositiveWhenShortsAreWinning() public {
        _open(EUR, false, 1_000e6);
        _price(EUR, 0.8e18);
        assertEq(vault.liability(EUR), int256(200e18));
    }

    /// @dev A balanced book costs the pool nothing however far the price moves. This is the whole
    ///      reason to track both sides rather than net exposure only.
    function test_LongsAndShortsNetAgainstEachOther() public {
        _open(EUR, true, 1_000e6);
        _open(EUR, false, 1_000e6);
        _price(EUR, 1.5e18);
        assertEq(vault.liability(EUR), int256(0));
    }

    function test_TotalLiabilitySumsAcrossFeeds() public {
        _open(EUR, true, 1_000e6);
        _open(XAU, true, 1_000e6);
        _price(EUR, 1.2e18);
        _price(XAU, 0.9e18);
        assertEq(vault.totalLiability(), int256(200e18) - int256(100e18));
    }

    /// @dev NAV must always be computable. FX and equity feeds go stale every weekend by design, so
    ///      if liability reverted on staleness the ERC-4626 vault would brick outside market hours.
    ///      Trading is gated on freshness; valuation is not.
    function test_DoesNotRevertOnStalePrice() public {
        _open(EUR, true, 1_000e6);
        _price(EUR, 1.2e18);
        skip(30 days);
        assertEq(vault.liability(EUR), int256(200e18));
    }

    function test_EnabledFeedsListsConfiguredFeeds() public view {
        bytes32[] memory feeds = vault.enabledFeeds();
        assertEq(feeds.length, 2);
        assertEq(feeds[0], EUR);
        assertEq(feeds[1], XAU);
    }
}
