// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/oracle/ChainlinkOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract ChainlinkOracleTest is Test {
    ChainlinkOracle oracle;
    MockAggregator agg8;

    bytes32 constant EUR = keccak256("FX.EUR/USD");
    bytes32 constant MISSING = keccak256("FX.GBP/USD");
    uint16 constant CONF_BPS = 20; // 0.20%

    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new ChainlinkOracle(address(this));
        agg8 = new MockAggregator(8);
        oracle.setFeed(EUR, address(agg8));
        oracle.setSyntheticConfBps(CONF_BPS);
        agg8.set(1.16e8, block.timestamp);
    }

    function test_NormalisesEightDecimalAnswer() public view {
        assertEq(oracle.getPrice(EUR, 60).price, 1.16e18);
    }

    function test_NormalisesEighteenDecimalAnswer() public {
        MockAggregator agg18 = new MockAggregator(18);
        bytes32 feed = keccak256("ETH/USD");
        oracle.setFeed(feed, address(agg18));
        agg18.set(3_000e18, block.timestamp);
        assertEq(oracle.getPrice(feed, 60).price, 3_000e18);
    }

    /// @dev Chainlink publishes no confidence interval, but the vault skews every trade by conf. A
    ///      configured synthetic spread keeps that protection in place when Chainlink is the live
    ///      oracle; a zero would silently remove it.
    function test_AppliesConfiguredSyntheticConfidence() public view {
        assertEq(oracle.getPrice(EUR, 60).conf, uint256(1.16e18) * CONF_BPS / 1e4);
    }

    function test_StalenessUsesTheCommonErrorVocabulary() public {
        skip(61);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.StalePrice.selector, EUR, 61, 60));
        oracle.getPrice(EUR, 60);
    }

    function test_UnmappedFeedReportsPriceUnavailable() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.PriceUnavailable.selector, MISSING));
        oracle.getPrice(MISSING, 60);
    }

    function test_NonPositiveAnswerIsRejected() public {
        agg8.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, EUR));
        oracle.getPrice(EUR, 60);
    }

    /// @dev updatedAt of zero means the round never completed. Treating it as a timestamp would
    ///      make the price look maximally stale rather than invalid, which is a different bug.
    function test_IncompleteRoundIsRejected() public {
        agg8.set(1.16e8, 0);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, EUR));
        oracle.getPrice(EUR, 60);
    }

    function test_UpdateFeeIsZeroAndUpdatePricesRejectsValue() public {
        bytes[] memory data = new bytes[](1);
        assertEq(oracle.updateFee(data), 0);
        oracle.updatePrices(data);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.UnexpectedValue.selector, 1 ether));
        oracle.updatePrices{value: 1 ether}(data);
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setFeed(EUR, address(agg8));

        vm.prank(stranger);
        vm.expectRevert();
        oracle.setSyntheticConfBps(10);
    }

    function test_SyntheticConfidenceIsCapped() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.ConfidenceTooHigh.selector, 1001, 1000));
        oracle.setSyntheticConfBps(1001);
    }
}
