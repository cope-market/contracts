// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {Wad} from "../src/libraries/Wad.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultGuardsTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    bytes32 constant EUR = keccak256("FX.EUR/USD");
    bytes32 constant UNKNOWN = keccak256("FX.GBP/USD");

    uint256 constant PRICE = 1.16e18;
    uint32 constant MAX_CONF_BPS = 100; // 1%
    uint128 constant MAX_POSITION_USD = 10_000e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        _configure(true);
        oracle.push(EUR, PRICE, 0.0004e18, uint64(block.timestamp));

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _configure(bool enabled) internal {
        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: enabled,
                maxAgeSec: 60,
                maxConfBps: MAX_CONF_BPS,
                openFeeBps: 0, // zero so cap assertions are exact
                closeFeeBps: 0,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: MAX_POSITION_USD
            })
        );
    }

    function _open(uint128 collateral) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, true, collateral, 0, new bytes[](0));
    }

    function test_RevertsWhenAssetDisabled() public {
        _configure(false);
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.AssetDisabled.selector, EUR));
        _open(100e6);
    }

    /// @dev A feed that was never configured must be refused, not treated as a default-zero config.
    function test_RevertsForNeverConfiguredFeed() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.AssetDisabled.selector, UNKNOWN));
        vm.prank(alice);
        vault.open(UNKNOWN, true, 100e6, 0, new bytes[](0));
    }

    /// @dev Staleness is enforced in the contract, not the UI. Without it, a trader could open
    ///      against a Friday close on a Sunday, which is free money.
    function test_RevertsWhenPriceIsStale() public {
        skip(61);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.StalePrice.selector, EUR, 61, 60));
        _open(100e6);
    }

    function test_RevertsWhenConfidenceTooWide() public {
        uint256 wide = PRICE * (MAX_CONF_BPS + 1) / 1e4;
        skip(1);
        oracle.push(EUR, PRICE, wide, uint64(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(
                SyntheticVault.ConfidenceTooWide.selector, EUR, MAX_CONF_BPS + 1, MAX_CONF_BPS
            )
        );
        _open(100e6);
    }

    function test_ConfidenceExactlyAtLimitIsAccepted() public {
        skip(1);
        oracle.push(EUR, PRICE, PRICE * MAX_CONF_BPS / 1e4, uint64(block.timestamp));
        assertEq(_open(100e6), 1);
    }

    function test_RevertsWhenPositionExceedsCap() public {
        uint128 tooBig = uint128(Wad.fromWad(MAX_POSITION_USD)) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SyntheticVault.PositionTooLarge.selector, EUR, Wad.toWad(tooBig), MAX_POSITION_USD
            )
        );
        _open(tooBig);
    }

    function test_PositionExactlyAtCapIsAccepted() public {
        assertEq(_open(uint128(Wad.fromWad(MAX_POSITION_USD))), 1);
    }

    function test_RevertsOnZeroCollateral() public {
        vm.expectRevert(SyntheticVault.ZeroCollateral.selector);
        _open(0);
    }
}
