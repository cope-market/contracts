// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {Wad} from "../src/libraries/Wad.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultOpenTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    bytes32 constant EUR = keccak256("FX.EUR/USD");

    uint32 constant OPEN_FEE_BPS = 10; // 0.10%
    uint256 constant PRICE = 1.16e18;
    uint256 constant CONF = 0.0004e18;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);

        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: 60,
                maxConfBps: 100,
                openFeeBps: OPEN_FEE_BPS,
                closeFeeBps: 10,
                maxOiUsd: 1_000_000e18,
                maxPositionUsd: 100_000e18
            })
        );

        oracle.push(EUR, PRICE, CONF, uint64(block.timestamp));

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _open(bool isLong, uint128 collateral) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, isLong, collateral, 0, new bytes[](0));
    }

    function test_MintsPositionNftToCaller() public {
        uint256 id = _open(true, 1_000e6);
        assertEq(id, 1, "first token id is 1");
        assertEq(vault.ownerOf(id), alice);
        assertEq(vault.balanceOf(alice), 1);
    }

    function test_TokenIdsIncrement() public {
        assertEq(_open(true, 100e6), 1);
        assertEq(_open(false, 100e6), 2);
    }

    function test_PullsExactlyTheCollateralFromCaller() public {
        uint256 before = usdc.balanceOf(alice);
        _open(true, 1_000e6);
        assertEq(before - usdc.balanceOf(alice), 1_000e6, "caller pays the full collateral");
    }

    /// @dev The open fee leaves the trading vault immediately and becomes LP revenue. If it stayed
    ///      in the vault it would look like trader collateral and inflate what the vault thinks it
    ///      can pay out.
    function test_OpenFeeGoesToLiquidityVault() public {
        _open(true, 1_000e6);
        uint256 expectedFee = uint256(1_000e6) * OPEN_FEE_BPS / 1e4;
        assertEq(usdc.balanceOf(address(lp)), expectedFee, "fee credited to LPs");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6 - expectedFee, "vault holds net collateral");
    }

    /// @dev The position records NET collateral. Recording gross would silently refund the open fee
    ///      on a close at an unchanged price.
    function test_StoresNetCollateralNotGross() public {
        uint256 id = _open(true, 1_000e6);
        uint256 expectedFee = uint256(1_000e6) * OPEN_FEE_BPS / 1e4;
        assertEq(vault.positions(id).collateral, 1_000e6 - expectedFee);
    }

    /// @dev Confidence always moves the price against the trader, so a long enters above mid.
    function test_LongEntersAtPricePlusConfidence() public {
        uint256 id = _open(true, 1_000e6);
        assertEq(vault.positions(id).entryPrice, PRICE + CONF);
    }

    function test_ShortEntersAtPriceMinusConfidence() public {
        uint256 id = _open(false, 1_000e6);
        assertEq(vault.positions(id).entryPrice, PRICE - CONF);
    }

    function test_UnitsAreNetNotionalDividedByEntryPrice() public {
        uint128 collateral = 1_000e6;
        uint256 id = _open(true, collateral);

        uint256 fee = uint256(collateral) * OPEN_FEE_BPS / 1e4;
        uint256 expectedUnits = Wad.toWad(collateral - fee) * 1e18 / (PRICE + CONF);
        assertEq(vault.positions(id).units, expectedUnits);
    }

    function test_RecordsFeedSideAndTimestamp() public {
        uint256 id = _open(false, 500e6);
        SyntheticVault.Position memory p = vault.positions(id);
        assertEq(p.feedId, EUR);
        assertFalse(p.isLong);
        assertEq(p.openedAt, uint64(block.timestamp));
    }

    function test_EmitsPositionOpened() public {
        uint128 collateral = 1_000e6;
        uint256 fee = uint256(collateral) * OPEN_FEE_BPS / 1e4;
        uint256 entry = PRICE + CONF;
        uint256 units = Wad.toWad(collateral - fee) * 1e18 / entry;

        vm.expectEmit(true, true, true, true);
        emit SyntheticVault.PositionOpened(1, alice, EUR, true, uint128(collateral - fee), units, entry, 0);
        _open(true, collateral);
    }
}
