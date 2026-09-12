// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultCloseTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 constant EUR = keccak256("FX.EUR/USD");

    uint128 constant COLLATERAL = 1_000e6;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        _configure(0);
        _price(1e18);

        usdc.mint(alice, 100_000e6);
        usdc.mint(address(lp), 100_000e6); // LPs underwrite trader profits
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _configure(uint32 closeFeeBps) internal {
        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: 3600,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: closeFeeBps,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );
    }

    function _price(uint256 p) internal {
        skip(1);
        oracle.push(EUR, p, 0, uint64(block.timestamp));
    }

    function _open(bool isLong) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, isLong, COLLATERAL, 0, new bytes[](0));
    }

    function _close(address who, uint256 id) internal {
        vm.prank(who);
        vault.close(id, new bytes[](0));
    }

    // 1000 USD at a price of 1.0 is 1000 units. Every expected payout below follows from that.

    function test_LongInProfitPaysCollateralPlusGain() public {
        uint256 id = _open(true);
        _price(1.2e18);
        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        assertEq(usdc.balanceOf(alice) - before, 1_200e6, "1000 units x +0.20 is +200 USDC");
    }

    function test_LongAtLossReturnsCollateralMinusLoss() public {
        uint256 id = _open(true);
        _price(0.8e18);
        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        assertEq(usdc.balanceOf(alice) - before, 800e6);
    }

    function test_ShortInProfitPaysCollateralPlusGain() public {
        uint256 id = _open(false);
        _price(0.8e18);
        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        assertEq(usdc.balanceOf(alice) - before, 1_200e6);
    }

    function test_ShortAtLossReturnsCollateralMinusLoss() public {
        uint256 id = _open(false);
        _price(1.2e18);
        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        assertEq(usdc.balanceOf(alice) - before, 800e6);
    }

    /// @dev A short's loss is unbounded but the payout is not. The trader can lose their collateral
    ///      and no more; the shortfall is the LPs' risk, which is why shorts need liquidation.
    function test_PayoutClampsAtZeroWhenLossExceedsCollateral() public {
        uint256 id = _open(false);
        _price(2.5e18); // -1500 USD against 1000 USD of collateral
        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        assertEq(usdc.balanceOf(alice) - before, 0, "never negative");
    }

    function test_ChargesCloseFeeOnExitNotional() public {
        _configure(50); // 0.50%
        uint256 id = _open(true);
        _price(1.2e18);

        uint256 before = usdc.balanceOf(alice);
        _close(alice, id);
        // Exit notional is 1200 USD, so the fee is 6 USDC.
        assertEq(usdc.balanceOf(alice) - before, 1_200e6 - 6e6);
    }

    function test_TraderLossAndFeesAccrueToLiquidityVault() public {
        uint256 id = _open(true);
        _price(0.8e18);
        uint256 before = usdc.balanceOf(address(lp));
        _close(alice, id);
        assertEq(usdc.balanceOf(address(lp)) - before, 200e6, "the 200 the trader lost");
    }

    function test_BurnsPositionNft() public {
        uint256 id = _open(true);
        _price(1.1e18);
        _close(alice, id);
        vm.expectRevert();
        vault.ownerOf(id);
    }

    function test_ReducesOpenInterest() public {
        uint256 id = _open(true);
        assertEq(vault.openInterest(EUR, true), 1_000e18);
        _price(1.1e18);
        _close(alice, id);
        assertEq(vault.openInterest(EUR, true), 0);
    }

    function test_OnlyOwnerOrApprovedCanClose() public {
        uint256 id = _open(true);
        _price(1.1e18);

        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.NotPositionOwner.selector, id, bob));
        _close(bob, id);

        vm.prank(alice);
        vault.approve(bob, id);
        _close(bob, id); // approved operator may close
    }

    /// @dev Payout follows the NFT. Whoever holds the position at close is the one who gets paid.
    function test_PayoutGoesToCurrentHolderAfterTransfer() public {
        uint256 id = _open(true);
        vm.prank(alice);
        vault.transferFrom(alice, bob, id);

        _price(1.2e18);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        _close(bob, id);

        assertEq(usdc.balanceOf(bob) - bobBefore, 1_200e6, "new holder is paid");
        assertEq(usdc.balanceOf(alice), aliceBefore, "original opener is not");
    }

    function test_CannotCloseTwice() public {
        uint256 id = _open(true);
        _price(1.1e18);
        _close(alice, id);
        vm.expectRevert();
        _close(alice, id);
    }
}
