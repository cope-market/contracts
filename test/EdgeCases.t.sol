// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Boundary and misconfiguration cases: zero values, absurd parameters, and the states a
///         live deployment can reach by accident rather than by attack.
contract EdgeCasesTest is Test {
    LiquidityVault lv;
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;

    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    bytes32 constant EUR = keccak256("FX.EUR/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lv = new LiquidityVault(usdc, address(this));
        vault = new SyntheticVault(usdc, oracle, lv, address(this));
        lv.setVault(address(vault));
        _cfg(0, 0, 3600, 100);
        oracle.push(EUR, 1e18, 0, uint64(vm.getBlockTimestamp()));

        usdc.mint(lp, 1_000_000e6);
        usdc.mint(trader, 1_000_000e6);
        vm.prank(lp);
        usdc.approve(address(lv), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _cfg(uint32 openFeeBps, uint32 closeFeeBps, uint32 maxAgeSec, uint32 maxConfBps) internal {
        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: maxAgeSec,
                maxConfBps: maxConfBps,
                openFeeBps: openFeeBps,
                closeFeeBps: closeFeeBps,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );
    }

    // --- asset configuration is the owner's most dangerous surface -------------------------------

    /// @dev A fat-fingered fee is a realistic deployment mistake, not an attack. 1000 typed where 10
    ///      was meant is a 10% fee; 10000 takes the entire deposit.
    function test_RejectsOpenFeeAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.FeeTooHigh.selector, 10_000, 500));
        _cfg(10_000, 0, 3600, 100);
    }

    function test_RejectsCloseFeeAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.FeeTooHigh.selector, 501, 500));
        _cfg(0, 501, 3600, 100);
    }

    function test_AcceptsFeeExactlyAtCap() public {
        _cfg(500, 500, 3600, 100);
    }

    /// @dev maxAgeSec of zero makes every price stale, so the asset cannot be traded AND existing
    ///      positions cannot be closed. That is a fund-freezing misconfiguration.
    function test_RejectsZeroMaxAge() public {
        vm.expectRevert(SyntheticVault.InvalidMaxAge.selector);
        _cfg(0, 0, 0, 100);
    }

    /// @dev A confidence bound at or above 100% would let conf exceed price, underflowing the short
    ///      entry price calculation.
    function test_RejectsConfidenceBoundAboveCap() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.ConfBoundTooHigh.selector, 1001, 1000));
        _cfg(0, 0, 3600, 1001);
    }

    // --- zero-value positions --------------------------------------------------------------------

    /// @dev With the fee cap in place a fee can no longer consume the whole deposit, but the guard
    ///      is asserted directly: a position with no exposure must never be mintable, because the
    ///      trader would have paid and received nothing redeemable.
    function test_CannotMintPositionWithZeroUnits() public {
        _cfg(500, 0, 3600, 100);
        // One micro-USDC, of which the fee rounds away nothing, still yields units. Drive units to
        // zero by making the price astronomically larger than the notional.
        skip(1);
        oracle.push(EUR, type(uint192).max, 0, uint64(vm.getBlockTimestamp()));

        vm.prank(trader);
        vm.expectRevert(SyntheticVault.ZeroUnits.selector);
        vault.open(EUR, true, 1, 0, new bytes[](0));
    }

    // --- traders must always be able to exit -----------------------------------------------------

    /// @dev Disabling an asset must stop new risk, not trap existing positions.
    function test_DisablingAnAssetStillAllowsClosing() public {
        vm.prank(trader);
        uint256 id = vault.open(EUR, true, 1_000e6, 0, new bytes[](0));

        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: false,
                maxAgeSec: 3600,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: 0,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );

        vm.prank(trader);
        vault.close(id, new bytes[](0));
        assertEq(usdc.balanceOf(trader), 1_000_000e6, "collateral returned in full");
    }

    /// @dev Caps bind new positions only. Lowering them below current open interest must not strand
    ///      the positions already open.
    function test_LoweringCapsDoesNotTrapOpenPositions() public {
        vm.prank(trader);
        uint256 id = vault.open(EUR, true, 1_000e6, 0, new bytes[](0));

        vault.setAssetConfig(
            EUR,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: 3600,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: 0,
                maxOiUsd: 1,
                maxPositionUsd: 1
            })
        );

        vm.prank(trader);
        vault.close(id, new bytes[](0));
    }

    // --- liquidity vault boundaries ---------------------------------------------------------------

    /// @dev Before setVault is called there is no trading vault to owe anything, so NAV is simply
    ///      the balance. Reached during deployment, between constructing and wiring.
    function test_TotalAssetsBeforeVaultIsWired() public {
        LiquidityVault fresh = new LiquidityVault(usdc, address(this));
        usdc.mint(address(fresh), 5_000e6);
        assertEq(fresh.totalAssets(), 5_000e6);
    }

    /// @dev withdraw() is the ERC-4626 path an integrator may use instead of redeem(). It must
    ///      deliver exactly the amount asked for, with the exit fee taken on top in shares.
    function test_WithdrawDeliversTheExactAmountRequested() public {
        lv.setExitFeeBps(100);
        vm.prank(lp);
        lv.deposit(100_000e6, lp);

        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        uint256 sharesBurned = lv.withdraw(10_000e6, lp, lp);

        assertEq(usdc.balanceOf(lp) - before, 10_000e6, "receives exactly what was asked");
        assertGt(sharesBurned, 10_000e6, "burns more than 1:1 to cover the fee");
    }

    /// @dev maxWithdraw must be actually withdrawable. If it over-reported, a UI offering "withdraw
    ///      max" would revert.
    function test_MaxWithdrawIsActuallyWithdrawable() public {
        lv.setExitFeeBps(100);
        vm.prank(lp);
        lv.deposit(100_000e6, lp);

        uint256 maxW = lv.maxWithdraw(lp);
        vm.prank(lp);
        lv.withdraw(maxW, lp, lp);
    }

    function test_PreviewWithdrawGrossesUpForTheExitFee() public {
        lv.setExitFeeBps(100);
        vm.prank(lp);
        lv.deposit(100_000e6, lp);

        uint256 shares = lv.previewWithdraw(10_000e6);
        assertEq(shares, lv.previewWithdraw(10_000e6));
        assertGt(shares, 10_000e6, "grossed up");
    }

    function test_ZeroValueLpOperationsAreHarmless() public {
        vm.prank(lp);
        assertEq(lv.deposit(0, lp), 0);
        vm.prank(lp);
        assertEq(lv.redeem(0, lp, lp), 0);
    }

    function test_PayoutOfZeroIsANoOp() public {
        vm.prank(lp);
        lv.deposit(1_000e6, lp);
        uint256 before = usdc.balanceOf(address(lv));
        vm.prank(address(vault));
        lv.payout(trader, 0);
        assertEq(usdc.balanceOf(address(lv)), before);
    }

    /// @dev Reading a position that never existed, or one already closed and burned, must fail
    ///      loudly rather than return a zeroed struct that a caller could mistake for real.
    function test_ReadingAnUnknownPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.UnknownPosition.selector, 999));
        vault.positions(999);

        vm.prank(trader);
        uint256 id = vault.open(EUR, true, 1_000e6, 0, new bytes[](0));
        vm.prank(trader);
        vault.close(id, new bytes[](0));

        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.UnknownPosition.selector, id));
        vault.positions(id);
    }

    /// @dev Retuning liquidation parameters is a live operation, so the happy path matters as much
    ///      as the rejection. A tighter threshold must actually make positions liquidatable sooner.
    function test_LiquidationParamsTakeEffect() public {
        usdc.mint(address(lv), 1_000_000e6);
        vm.prank(lp);
        lv.deposit(500_000e6, lp);

        vm.prank(trader);
        uint256 id = vault.open(EUR, true, 1_000e6, 0, new bytes[](0));

        skip(1);
        oracle.push(EUR, 0.5e18, 0, uint64(vm.getBlockTimestamp())); // down 500 of 1000

        // Default threshold is 90%, so a 50% loss is still healthy.
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.PositionHealthy.selector, id, 500e18, 900e18));
        vault.liquidate(id, new bytes[](0));

        vault.setLiquidationParams(4000, 200); // 40% threshold, 2% reward
        assertEq(vault.liquidationThresholdBps(), 4000);
        assertEq(vault.liquidationRewardBps(), 200);

        uint256 before = usdc.balanceOf(address(this));
        vault.liquidate(id, new bytes[](0));
        assertEq(usdc.balanceOf(address(this)) - before, 20e6, "2% of 1000 USDC collateral");
    }
}
