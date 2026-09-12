// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract SyntheticVaultLiquidateTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

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

        usdc.mint(alice, 100_000e6);
        usdc.mint(address(lp), 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _price(uint256 p) internal {
        skip(1);
        oracle.push(EUR, p, 0, uint64(block.timestamp));
    }

    function _openLong() internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, true, COLLATERAL, 0, new bytes[](0));
    }

    function _liquidate(uint256 id) internal {
        vm.prank(keeper);
        vault.liquidate(id, new bytes[](0));
    }

    // 1000 units. Default threshold is 90%, so the position is liquidatable once it is down 900 USD,
    // which happens at a price of 0.10.

    function test_HealthyPositionCannotBeLiquidated() public {
        uint256 id = _openLong();
        _price(0.11e18); // down 890, threshold is 900
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.PositionHealthy.selector, id, 890e18, 900e18));
        _liquidate(id);
    }

    function test_ProfitablePositionCannotBeLiquidated() public {
        uint256 id = _openLong();
        _price(1.5e18);
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.PositionHealthy.selector, id, 0, 900e18));
        _liquidate(id);
    }

    /// @dev The boundary is inclusive: exactly at the threshold is liquidatable. One tick healthier
    ///      is not. Getting this backwards either lets bad positions linger or lets keepers seize
    ///      solvent ones.
    function test_LiquidatableExactlyAtThreshold() public {
        uint256 id = _openLong();
        _price(0.1e18); // down exactly 900
        _liquidate(id);
        vm.expectRevert();
        vault.ownerOf(id);
    }

    function test_AnyoneCanLiquidate() public {
        uint256 id = _openLong();
        _price(0.05e18);
        _liquidate(id); // keeper is not the owner and has no approval
    }

    function test_CallerReceivesTheReward() public {
        uint256 id = _openLong();
        _price(0.05e18); // down 950, so 50 USDC of collateral remains
        uint256 before = usdc.balanceOf(keeper);
        _liquidate(id);
        assertEq(usdc.balanceOf(keeper) - before, 10e6, "1% of 1000 USDC collateral");
    }

    function test_OwnerReceivesWhatIsLeftAfterTheReward() public {
        uint256 id = _openLong();
        _price(0.05e18);
        uint256 before = usdc.balanceOf(alice);
        _liquidate(id);
        assertEq(usdc.balanceOf(alice) - before, 40e6, "50 remaining less the 10 reward");
    }

    /// @dev When nothing is left the keeper is still not paid out of thin air.
    function test_RewardIsCappedByWhatRemains() public {
        uint256 id = _openLong();
        _price(0.0001e18); // wiped out
        uint256 keeperBefore = usdc.balanceOf(keeper);
        _liquidate(id);
        assertLe(usdc.balanceOf(keeper) - keeperBefore, 10e6);
    }

    function test_ReducesOpenInterestAndBurns() public {
        uint256 id = _openLong();
        _price(0.05e18);
        _liquidate(id);
        assertEq(vault.openInterest(EUR, true), 0);
        vm.expectRevert();
        vault.ownerOf(id);
    }

    function test_LiquidityVaultReceivesTheLoss() public {
        uint256 id = _openLong();
        _price(0.05e18);
        uint256 before = usdc.balanceOf(address(lp));
        _liquidate(id);
        assertEq(usdc.balanceOf(address(lp)) - before, 950e6, "the 950 the trader lost");
    }

    function test_ShortsAreLiquidatableToo() public {
        vm.prank(alice);
        uint256 id = vault.open(EUR, false, COLLATERAL, 0, new bytes[](0));
        _price(1.95e18); // short down 950
        _liquidate(id);
        vm.expectRevert();
        vault.ownerOf(id);
    }

    function test_ThresholdAndRewardAreCapped() public {
        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.InvalidLiquidationParams.selector, 10_001, 100));
        vault.setLiquidationParams(10_001, 100);

        vm.expectRevert(abi.encodeWithSelector(SyntheticVault.InvalidLiquidationParams.selector, 9000, 1001));
        vault.setLiquidationParams(9000, 1001);
    }
}
