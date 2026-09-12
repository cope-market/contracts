// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultCopyTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address author = makeAddr("author");
    address copier = makeAddr("copier");
    address buyer = makeAddr("buyer");

    bytes32 constant EUR = keccak256("FX.EUR/USD");
    uint128 constant COLLATERAL = 1_000e6;
    uint16 constant AUTHOR_FEE_BPS = 1000; // 10% of profit

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));
        vault.setAuthorFeeBps(AUTHOR_FEE_BPS);

        vault.setAssetConfig(
            EUR,
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
        _price(1e18);

        usdc.mint(address(lp), 1_000_000e6);
        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? author : (i == 1 ? copier : buyer);
            usdc.mint(who, 100_000e6);
            vm.prank(who);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function _price(uint256 p) internal {
        skip(1);
        oracle.push(EUR, p, 0, uint64(block.timestamp));
    }

    function _open(address who, uint256 copyOf) internal returns (uint256 id) {
        vm.prank(who);
        return vault.open(EUR, true, COLLATERAL, copyOf, new bytes[](0));
    }

    function _close(address who, uint256 id) internal {
        vm.prank(who);
        vault.close(id, new bytes[](0));
    }

    function test_OriginalPositionRecordsItsOpenerAsAuthor() public {
        uint256 id = _open(author, 0);
        SyntheticVault.Position memory p = vault.positions(id);
        assertEq(p.author, author);
        assertEq(p.copyAuthor, address(0), "an original owes nobody a fee");
        assertEq(p.authorFeeBps, 0);
    }

    function test_CopySnapshotsOriginAuthorAndFeeRate() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);

        SyntheticVault.Position memory p = vault.positions(copy);
        assertEq(p.copiedFromId, origin);
        assertEq(p.copyAuthor, author);
        assertEq(p.authorFeeBps, AUTHOR_FEE_BPS);
    }

    function test_ProfitableCopyPaysAuthorAShareOfProfit() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);

        _price(1.2e18); // +200 USD of profit on the copy

        uint256 authorBefore = usdc.balanceOf(author);
        uint256 copierBefore = usdc.balanceOf(copier);
        _close(copier, copy);

        assertEq(usdc.balanceOf(author) - authorBefore, 20e6, "10% of 200 USD profit");
        assertEq(usdc.balanceOf(copier) - copierBefore, 1_180e6, "copier keeps the rest");
    }

    function test_LosingCopyPaysNoAuthorFee() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);

        _price(0.8e18);

        uint256 authorBefore = usdc.balanceOf(author);
        _close(copier, copy);
        assertEq(usdc.balanceOf(author), authorBefore, "no fee on a loss");
    }

    function test_OriginalPositionPaysNoAuthorFee() public {
        uint256 id = _open(author, 0);
        _price(1.2e18);
        uint256 before = usdc.balanceOf(author);
        _close(author, id);
        assertEq(usdc.balanceOf(author) - before, 1_200e6, "full payout, nothing withheld");
    }

    /// @dev Invariant 7, half one. Selling the copy must not redirect the author's fee to the new
    ///      holder. Payout follows the NFT; the fee follows the snapshot.
    function test_TransferringTheCopyDoesNotRedirectTheAuthorFee() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);

        vm.prank(copier);
        vault.transferFrom(copier, buyer, copy);

        _price(1.2e18);
        uint256 authorBefore = usdc.balanceOf(author);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _close(buyer, copy);

        assertEq(usdc.balanceOf(author) - authorBefore, 20e6, "author still paid");
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 1_180e6, "new holder takes the payout");
    }

    /// @dev Invariant 7, half two. Selling the ORIGIN must not move the fee either: it is owed to
    ///      whoever wrote the thesis, not to whoever happens to hold their position now.
    function test_TransferringTheOriginDoesNotRedirectTheAuthorFee() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);

        vm.prank(author);
        vault.transferFrom(author, buyer, origin);

        _price(1.2e18);
        uint256 authorBefore = usdc.balanceOf(author);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _close(copier, copy);

        assertEq(usdc.balanceOf(author) - authorBefore, 20e6, "original opener is still the author");
        assertEq(usdc.balanceOf(buyer), buyerBefore, "the origin's new holder gets nothing");
    }

    /// @dev A copy of a copy attributes to the person who opened the position that was copied, not
    ///      to the root of the chain.
    function test_CopyOfACopyAttributesToTheImmediateAuthor() public {
        uint256 origin = _open(author, 0);
        uint256 copy = _open(copier, origin);
        uint256 second = _open(buyer, copy);

        assertEq(vault.positions(second).copyAuthor, copier);
    }

    function test_CopyingAClosedPositionReverts() public {
        uint256 origin = _open(author, 0);
        _price(1.1e18);
        _close(author, origin);

        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.UnknownPosition.selector, origin));
        _open(copier, origin);
    }

    function test_AuthorFeeIsCapped() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.AuthorFeeTooHigh.selector, 5001, 5000));
        vault.setAuthorFeeBps(5001);
    }

    function test_OnlyOwnerCanSetAuthorFee() public {
        vm.prank(copier);
        vm.expectRevert();
        vault.setAuthorFeeBps(500);
    }
}
