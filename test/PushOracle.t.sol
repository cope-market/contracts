// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

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

    // --- batching -------------------------------------------------------------------------------

    bytes32 constant FEED_B = keccak256("Metal.XAU/USD");
    bytes32 constant FEED_C = keccak256("Crypto.BTC/USD");

    function _batch(uint256 n)
        internal
        view
        returns (bytes32[] memory f, uint256[] memory p, uint256[] memory c, uint64[] memory t)
    {
        bytes32[3] memory all = [FEED, FEED_B, FEED_C];
        f = new bytes32[](n);
        p = new uint256[](n);
        c = new uint256[](n);
        t = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            f[i] = all[i];
            p[i] = (i + 1) * 1e18;
            c[i] = i;
            t[i] = uint64(block.timestamp);
        }
    }

    /// @dev The pusher writes every feed in one transaction. At a feed per transaction the job costs
    ///      four times the gas and has four times the ways to half-fail.
    function test_PushManyWritesEveryFeedInOneCall() public {
        (bytes32[] memory f, uint256[] memory p, uint256[] memory c, uint64[] memory t) = _batch(3);
        vm.prank(pusher);
        oracle.pushMany(f, p, c, t);

        assertEq(oracle.getPrice(FEED, 60).price, 1e18);
        assertEq(oracle.getPrice(FEED_B, 60).price, 2e18);
        assertEq(oracle.getPrice(FEED_C, 60).price, 3e18);
    }

    function test_PushManyRevertsOnLengthMismatch() public {
        (bytes32[] memory f, uint256[] memory p, uint256[] memory c,) = _batch(3);
        uint64[] memory shortT = new uint64[](2);
        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(PushOracle.LengthMismatch.selector));
        oracle.pushMany(f, p, c, shortT);
    }

    /// @dev All-or-nothing. A batch that silently dropped bad entries would let the pusher believe
    ///      it had updated a feed it had not, and the vault would trade on a stale price.
    function test_PushManyRevertsEntirelyIfAnyEntryIsInvalid() public {
        (bytes32[] memory f, uint256[] memory p, uint256[] memory c, uint64[] memory t) = _batch(3);
        p[1] = 0;

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, FEED_B));
        oracle.pushMany(f, p, c, t);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.PriceUnavailable.selector, FEED));
        oracle.getPrice(FEED, 60);
    }

    function test_PushManyRevertsIfAnyEntryIsNotNewer() public {
        _push(1.16e18, 0);
        (bytes32[] memory f, uint256[] memory p, uint256[] memory c, uint64[] memory t) = _batch(3);

        vm.prank(pusher);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector, FEED));
        oracle.pushMany(f, p, c, t);
    }

    function test_PushManyRejectsNonPusher() public {
        (bytes32[] memory f, uint256[] memory p, uint256[] memory c, uint64[] memory t) = _batch(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PushOracle.NotPusher.selector, stranger));
        oracle.pushMany(f, p, c, t);
    }

    function test_PushManyWithNoEntriesIsHarmless() public {
        vm.prank(pusher);
        oracle.pushMany(new bytes32[](0), new uint256[](0), new uint256[](0), new uint64[](0));
    }

    // --- last publish time ------------------------------------------------------------------------

    /// @dev The pusher reads this to decide which feeds actually have newer data. Hermes keeps
    ///      returning the same publishTime while a market is closed, and pushing it again reverts.
    function test_LastPublishTimeIsZeroForAnUnknownFeed() public view {
        assertEq(oracle.lastPublishTime(FEED_B), 0);
    }

    function test_LastPublishTimeReportsTheStoredTimestamp() public {
        _push(1.16e18, 0);
        assertEq(oracle.lastPublishTime(FEED), uint64(block.timestamp));
    }
}
