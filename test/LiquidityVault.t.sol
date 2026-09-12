// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract LiquidityVaultTest is Test {
    LiquidityVault lv;
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;

    address lpA = makeAddr("lpA");
    address lpB = makeAddr("lpB");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    bytes32 constant EUR = keccak256("FX.EUR/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);

        lv = new LiquidityVault(usdc, address(this));
        vault = new SyntheticVault(usdc, oracle, lv, address(this));
        lv.setVault(address(vault));

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

        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? lpA : lpB;
            usdc.mint(who, 1_000_000e6);
            vm.prank(who);
            usdc.approve(address(lv), type(uint256).max);
        }
        usdc.mint(trader, 1_000_000e6);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _price(uint256 p) internal {
        skip(1);
        oracle.push(EUR, p, 0, uint64(block.timestamp));
    }

    function _deposit(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return lv.deposit(amount, who);
    }

    function _openLong(uint128 collateral) internal returns (uint256) {
        vm.prank(trader);
        return vault.open(EUR, true, collateral, 0, new bytes[](0));
    }

    function test_DepositMintsSharesAndTracksAssets() public {
        uint256 shares = _deposit(lpA, 100_000e6);
        assertGt(shares, 0);
        assertEq(lv.totalAssets(), 100_000e6);
    }

    /// @dev NAV must net out what the trading vault owes open positions. Without this an LP could
    ///      deposit just before traders lose and withdraw just before they win, extracting value
    ///      from the other LPs.
    function test_TotalAssetsSubtractsWhatTradersAreOwed() public {
        _deposit(lpA, 100_000e6);
        _openLong(1_000e6);
        _price(1.2e18); // trader up 200 USD

        assertEq(lv.totalAssets(), 100_000e6 - 200e6, "200 USD is spoken for");
    }

    function test_TotalAssetsAddsWhatTradersHaveLost() public {
        _deposit(lpA, 100_000e6);
        _openLong(1_000e6);
        _price(0.8e18); // trader down 200 USD

        assertEq(lv.totalAssets(), 100_000e6 + 200e6);
    }

    function test_TotalAssetsClampsAtZeroWhenLiabilityExceedsCapital() public {
        _deposit(lpA, 100e6);
        _openLong(100_000e6);
        _price(3e18); // traders owe far more than the pool holds

        assertEq(lv.totalAssets(), 0, "never underflows");
    }

    /// @dev The economic point of the pool: a losing trader makes LPs richer.
    function test_TraderLossRaisesSharePrice() public {
        uint256 shares = _deposit(lpA, 100_000e6);
        uint256 before = lv.convertToAssets(shares);

        _openLong(1_000e6);
        _price(0.8e18);

        assertGt(lv.convertToAssets(shares), before);
    }

    function test_TraderProfitLowersSharePrice() public {
        uint256 shares = _deposit(lpA, 100_000e6);
        uint256 before = lv.convertToAssets(shares);

        _openLong(1_000e6);
        _price(1.2e18);

        assertLt(lv.convertToAssets(shares), before);
    }

    function test_OnlyTheSyntheticVaultCanCallPayout() public {
        _deposit(lpA, 100_000e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.NotVault.selector, stranger));
        lv.payout(stranger, 1e6);
    }

    function test_PayoutRevertsWhenPoolCannotCover() public {
        _deposit(lpA, 10e6);
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.InsufficientLiquidity.selector, 100e6, 10e6));
        lv.payout(stranger, 100e6);
    }

    function test_VaultCanOnlyBeSetOnce() public {
        vm.expectRevert(LiquidityVault.VaultAlreadySet.selector);
        lv.setVault(address(0xBEEF));
    }

    function test_OnlyOwnerCanSetVault() public {
        LiquidityVault fresh = new LiquidityVault(usdc, address(this));
        vm.prank(stranger);
        vm.expectRevert();
        fresh.setVault(address(vault));
    }

    /// @dev The exit fee removes the short-term timing edge an LP would otherwise have around
    ///      known-imminent P&L. It stays in the pool, so it accrues to the LPs who remain.
    function test_ExitFeeIsWithheldAndAccruesToRemainingHolders() public {
        lv.setExitFeeBps(100); // 1%
        uint256 sharesA = _deposit(lpA, 100_000e6);
        uint256 sharesB = _deposit(lpB, 100_000e6);

        uint256 valueBBefore = lv.convertToAssets(sharesB);

        vm.prank(lpA);
        uint256 got = lv.redeem(sharesA, lpA, lpA);

        assertEq(got, 99_000e6, "1% withheld");
        assertGt(lv.convertToAssets(sharesB), valueBBefore, "withheld fee lifts remaining LPs");
    }

    function test_PreviewRedeemReportsAmountNetOfExitFee() public {
        lv.setExitFeeBps(100);
        uint256 shares = _deposit(lpA, 100_000e6);
        assertEq(lv.previewRedeem(shares), 99_000e6);
    }

    function test_ExitFeeIsCapped() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidityVault.ExitFeeTooHigh.selector, 1001, 1000));
        lv.setExitFeeBps(1001);
    }

    /// @dev Sub-micro-USDC liability must round UP, not toward zero. Truncating makes the pool
    ///      report marginally more assets than it can back, which is the wrong direction: every
    ///      rounding decision should favour the protocol, never the redeemer.
    function test_LiabilityRoundsAgainstThePool() public {
        _deposit(lpA, 100_000e6);
        _openLong(1_000e6);

        // A price a hair above entry: traders are owed a fraction of one micro-USDC.
        _price(1e18 + 1);

        assertEq(vault.liability(EUR), int256(1_000), "1000 wei of USD owed");
        assertEq(lv.totalAssets(), 100_000e6 - 1, "rounded up to a full micro-USDC");
    }

    // --- share precision ---------------------------------------------------------------------

    /// @dev Shares carry more decimals than the asset so that rounding cannot eat a deposit. With
    ///      no offset, shares are 6-decimal like USDC and there is no headroom at all.
    function test_SharesHaveMoreDecimalsThanTheAsset() public view {
        assertEq(lv.decimals(), 18, "6-decimal asset, 18-decimal shares");
    }

    /// @dev The failure this prevents, observed live before the fix: a vault holding assets with a
    ///      distorted share price minted ZERO shares for small deposits and simply absorbed the
    ///      money. Anything a UI lets a user type must mint something redeemable.
    function test_SmallDepositsMintNonZeroSharesEvenAfterADonation() public {
        // The live sequence: a trade pushed fees into the vault while supply was still zero, so the
        // first deposit minted at a ~4407:1 price and every later deposit inherited it.
        usdc.mint(address(lv), 4_405);
        _deposit(lpA, 20e6);

        uint256 shares = lv.previewDeposit(1_000); // 0.001 USDC
        assertGt(shares, 0, "a deposit must never mint zero shares");
        assertGt(lv.previewRedeem(shares), 0, "and must be redeemable for something");
    }

    /// @dev Round-tripping a small deposit must return substantially all of it. Before the offset a
    ///      0.01 USDC deposit came back as 0.0088 -- a 12% haircut to rounding alone.
    function testFuzz_SmallDepositRoundTripsWithinRounding(uint96 amount) public {
        uint256 deposited = bound(uint256(amount), 1_000, 1_000e6);
        usdc.mint(address(lv), 4_405);
        _deposit(lpA, 100e6);

        vm.prank(lpB);
        uint256 shares = lv.deposit(deposited, lpB);
        uint256 returned = lv.previewRedeem(shares);

        // Only the 0.10% exit fee and sub-unit rounding may be lost.
        assertGe(returned, deposited - (deposited / 1000) - 1, "round trip loses only the exit fee");
    }

    /// @dev The classic ERC-4626 inflation attack: seed one wei, donate a pile, wait for a victim.
    ///      Virtual shares scale with the offset, which is what makes it uneconomic.
    function test_DonationAttackCannotStealAVictimsDeposit() public {
        address attacker = lpA;
        address victim = lpB;

        vm.prank(attacker);
        lv.deposit(1, attacker);

        // Donate directly, inflating assets against a supply of one unit.
        usdc.mint(attacker, 100_000e6);
        vm.prank(attacker);
        usdc.transfer(address(lv), 50_000e6);

        vm.prank(victim);
        uint256 victimShares = lv.deposit(20_000e6, victim);

        assertGt(victimShares, 0, "victim must not be rounded to zero");
        uint256 recoverable = lv.previewRedeem(victimShares);
        assertGe(recoverable, 19_000e6, "victim recovers substantially all of their deposit");
    }
}
