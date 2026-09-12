// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultAggregatesTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    bytes32 constant EUR = keccak256("FX.EUR/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        _setCap(type(uint128).max);
        _price(1e18);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setCap(uint128 maxOiUsd) internal {
        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: 3600,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: 0,
                maxOiUsd: maxOiUsd,
                maxPositionUsd: type(uint128).max
            })
        );
    }

    function _price(uint256 p) internal {
        skip(1);
        oracle.push(EUR, p, 0, uint64(block.timestamp));
    }

    function _open(bool isLong, uint128 collateral) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, isLong, collateral, 0, new bytes[](0));
    }

    function test_FirstOpenSetsUnitsAndAverageEntry() public {
        _open(true, 1_000e6);
        (uint256 longUnits,,,) = vault.assetState(EUR);
        assertEq(longUnits, 1_000e18, "1000 USD at a price of 1.0 is 1000 units");
        assertEq(vault.avgEntry(EUR, true), 1e18);
    }

    /// @dev 1000 USD at 1.0 gives 1000 units; 1000 USD at 2.0 gives 500 units. 2000 USD of notional
    ///      across 1500 units is an average entry of 4/3. Chosen so the expected value is checkable
    ///      by hand rather than by restating the implementation.
    function test_SecondOpenProducesNotionalWeightedAverage() public {
        _open(true, 1_000e6);
        _price(2e18);
        _open(true, 1_000e6);

        (uint256 longUnits,,,) = vault.assetState(EUR);
        assertEq(longUnits, 1_500e18);
        assertEq(vault.avgEntry(EUR, true), uint256(2_000e18) * 1e18 / 1_500e18);
        assertEq(vault.avgEntry(EUR, true), 1_333_333_333_333_333_333);
    }

    function test_LongsAndShortsTrackedSeparately() public {
        _open(true, 1_000e6);
        _price(2e18);
        _open(false, 1_000e6);

        (uint256 longUnits,, uint256 shortUnits,) = vault.assetState(EUR);
        assertEq(longUnits, 1_000e18);
        assertEq(vault.avgEntry(EUR, true), 1e18);
        assertEq(shortUnits, 500e18);
        assertEq(vault.avgEntry(EUR, false), 2e18);
    }

    function test_OpenInterestIsMeasuredAtEntryValue() public {
        _open(true, 1_000e6);
        _price(5e18); // price moves; entry-value OI must not
        assertEq(vault.openInterest(EUR, true), 1_000e18);
        assertEq(vault.openInterest(EUR, false), 0);
    }

    function test_RevertsWhenOpenInterestCapExceeded() public {
        _setCap(1_500e18);
        _open(true, 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                SyntheticVault.OpenInterestCapExceeded.selector, EUR, true, 1_600e18, 1_500e18
            )
        );
        _open(true, 600e6);
    }

    function test_OpenInterestExactlyAtCapIsAccepted() public {
        _setCap(1_500e18);
        _open(true, 1_000e6);
        assertEq(_open(true, 500e6), 2);
        assertEq(vault.openInterest(EUR, true), 1_500e18);
    }

    /// @dev Caps are per side. A large long must not consume the short side's capacity.
    function test_CapsAreEnforcedPerSide() public {
        _setCap(1_000e18);
        _open(true, 1_000e6);
        assertEq(_open(false, 1_000e6), 2, "short side has its own capacity");
    }
}
