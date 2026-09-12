// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythOracle} from "../src/oracle/PythOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract PythOracleTest is Test {
    MockPyth pyth;
    PythOracle oracle;

    bytes32 constant EUR = bytes32(uint256(1));
    bytes32 constant MISSING = bytes32(uint256(99));
    uint256 constant FEE = 1 wei;

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPyth(type(uint256).max, FEE);
        oracle = new PythOracle(pyth);
    }

    function _publish(bytes32 id, int64 price, uint64 conf, int32 expo) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(id, price, conf, expo, price, conf, uint64(block.timestamp));
        pyth.updatePriceFeeds{value: FEE}(data);
    }

    /// @dev Pyth reports a price and an exponent. Every one of these is a real exponent from the
    ///      feeds we use: -5 for FX, -3 for metals, -8 for crypto.
    function test_NormalisesFxExponent() public {
        _publish(EUR, 116_090, 63, -5);
        assertEq(oracle.getPrice(EUR, 60).price, 1.1609e18);
    }

    function test_NormalisesMetalExponent() public {
        _publish(EUR, 4_597_687, 372, -3);
        assertEq(oracle.getPrice(EUR, 60).price, 4597.687e18);
    }

    function test_NormalisesCryptoExponent() public {
        _publish(EUR, 6_000_000_000_000, 100, -8);
        assertEq(oracle.getPrice(EUR, 60).price, 60_000e18);
    }

    function test_NormalisesZeroExponent() public {
        _publish(EUR, 42, 1, 0);
        assertEq(oracle.getPrice(EUR, 60).price, 42e18);
    }

    /// @dev An exponent finer than 1e-18 has to divide rather than multiply.
    function test_NormalisesExponentFinerThanWad() public {
        _publish(EUR, 1_000_000, 1_000, -24);
        assertEq(oracle.getPrice(EUR, 60).price, 1e18 / 1e18);
    }

    function test_NormalisesConfidenceOnTheSameScale() public {
        _publish(EUR, 116_090, 63, -5);
        assertEq(oracle.getPrice(EUR, 60).conf, 63 * 1e13);
    }

    function test_ReportsPublishTime() public {
        _publish(EUR, 116_090, 63, -5);
        assertEq(oracle.getPrice(EUR, 60).publishTime, uint64(block.timestamp));
    }

    /// @dev Staleness is reported as IPriceOracle.StalePrice, not Pyth's own error, so callers see
    ///      one error vocabulary whichever oracle is deployed.
    function test_StalenessUsesTheCommonErrorVocabulary() public {
        _publish(EUR, 116_090, 63, -5);
        skip(61);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.StalePrice.selector, EUR, 61, 60));
        oracle.getPrice(EUR, 60);
    }

    function test_AgeExactlyAtMaxIsAccepted() public {
        _publish(EUR, 116_090, 63, -5);
        skip(60);
        assertEq(oracle.getPrice(EUR, 60).price, 1.1609e18);
    }

    function test_UnknownFeedReportsPriceUnavailable() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.PriceUnavailable.selector, MISSING));
        oracle.getPrice(MISSING, 60);
    }

    function test_NonPositivePriceIsRejected() public {
        _publish(EUR, -5, 1, -5);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, EUR));
        oracle.getPrice(EUR, 60);
    }

    function test_UpdateFeeDelegatesToPyth() public view {
        bytes[] memory data = new bytes[](2);
        assertEq(oracle.updateFee(data), FEE * 2);
    }

    /// @dev The vault forwards msg.value straight through, so this path has to actually work.
    function test_UpdatePricesForwardsValueAndPostsTheUpdate() public {
        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(EUR, 116_090, 63, -5, 116_090, 63, uint64(block.timestamp));
        oracle.updatePrices{value: FEE}(data);
        assertEq(oracle.getPrice(EUR, 60).price, 1.1609e18);
    }
}
