// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract PushOracleTest is Test {
    PushOracle oracle;
    address pusher = makeAddr("pusher");
    address stranger = makeAddr("stranger");

    bytes32 constant FEED = keccak256("FX.EUR/USD");

    function setUp() public {
        oracle = new PushOracle(address(this));
        oracle.setPusher(pusher, true);
        vm.warp(1_000_000);
    }

    function _push(uint256 price, uint256 conf) internal {
        vm.prank(pusher);
        oracle.push(FEED, price, conf, uint64(block.timestamp));
    }

    function test_ReturnsPushedPriceAndConfidence() public {
        _push(1.16e18, 0.0001e18);
        IPriceOracle.Price memory p = oracle.getPrice(FEED, 60);
        assertEq(p.price, 1.16e18);
        assertEq(p.conf, 0.0001e18);
        assertEq(p.publishTime, uint64(block.timestamp));
    }

    function test_RevertsWhenFeedWasNeverPushed() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.PriceUnavailable.selector, FEED));
        oracle.getPrice(FEED, 60);
    }

    function test_RevertsWhenPriceIsOlderThanMaxAge() public {
        _push(1.16e18, 0);
        skip(61);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.StalePrice.selector, FEED, 61, 60));
        oracle.getPrice(FEED, 60);
    }

    /// @dev The boundary is inclusive. A price exactly maxAge old is still acceptable; one second
    ///      later is not. Off-by-one here silently widens the staleness window the vault trades on.
    function test_AgeExactlyEqualToMaxAgeIsAccepted() public {
        _push(1.16e18, 0);
        skip(60);
        IPriceOracle.Price memory p = oracle.getPrice(FEED, 60);
        assertEq(p.price, 1.16e18);
    }

    function test_RevertsOnZeroPrice() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, FEED));
        oracle.push(FEED, 0, 0, uint64(block.timestamp));
    }

    function test_RejectsFuturePublishTime() public {
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, FEED));
        oracle.push(FEED, 1e18, 0, uint64(block.timestamp + 1));
    }

    function test_OnlyPusherCanPush() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.push(FEED, 1e18, 0, uint64(block.timestamp));
    }

    /// @dev A push oracle needs no payload and charges nothing, so the vault must not send value.
    function test_UpdateFeeIsZeroAndUpdatePricesIsNoOp() public {
        bytes[] memory data = new bytes[](0);
        assertEq(oracle.updateFee(data), 0);
        oracle.updatePrices(data);
    }

    function test_RejectsOutOfOrderPush() public {
        _push(1.16e18, 0);
        uint64 older = uint64(block.timestamp - 1);
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, FEED));
        oracle.push(FEED, 1.17e18, 0, older);
    }

    /// @dev The interface is payable because pull oracles charge a fee. This one does not, so any
    ///      value sent would be stranded in the contract forever. Reject it instead.
    function test_UpdatePricesRejectsValue() public {
        bytes[] memory data = new bytes[](0);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PushOracle.UnexpectedValue.selector, 1 ether));
        oracle.updatePrices{value: 1 ether}(data);
    }
}
