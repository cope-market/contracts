// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Wad} from "../src/libraries/Wad.sol";

contract WadTest is Test {
    function test_ToWadScalesUsdcToEighteenDecimals() public pure {
        assertEq(Wad.toWad(1e6), 1e18, "1 USDC is 1e18 wad");
        assertEq(Wad.toWad(0), 0);
        assertEq(Wad.toWad(1), 1e12, "1 micro-USDC is 1e12 wad");
    }

    function test_FromWadScalesBackToUsdc() public pure {
        assertEq(Wad.fromWad(1e18), 1e6, "1e18 wad is 1 USDC");
        assertEq(Wad.fromWad(0), 0);
    }

    /// @dev Rounding direction is a solvency property: the protocol must never pay out a rounded-up
    ///      amount, so fromWad truncates.
    function test_FromWadTruncatesAndNeverRoundsUp() public pure {
        assertEq(Wad.fromWad(1e18 - 1), 999_999, "just under 1 USDC truncates down");
        assertEq(Wad.fromWad(1e12 - 1), 0, "sub-micro-USDC dust truncates to zero");
        assertEq(Wad.fromWad(1_999_999_999_999), 1, "1.999999 micro-USDC truncates to 1");
    }

    function testFuzz_RoundTripIsLossless(uint128 amount6) public pure {
        assertEq(Wad.fromWad(Wad.toWad(amount6)), uint256(amount6));
    }

    /// @dev Asserts fromWad is the *greatest* value that does not round up, so the test cannot be
    ///      satisfied by a degenerate implementation that always returns zero.
    function testFuzz_FromWadIsExactFloor(uint256 wad) public pure {
        wad = bound(wad, 0, type(uint256).max - Wad.USDC_SCALE);
        uint256 got = Wad.fromWad(wad);
        assertLe(got * Wad.USDC_SCALE, wad, "must never round up");
        assertGt((got + 1) * Wad.USDC_SCALE, wad, "must be the exact floor, not merely below");
    }

    function testFuzz_ToWadRevertsOnOverflow(uint256 amount6) public {
        amount6 = bound(amount6, type(uint256).max / Wad.USDC_SCALE + 1, type(uint256).max);
        vm.expectRevert();
        this.callToWad(amount6);
    }

    function callToWad(uint256 a) external pure returns (uint256) {
        return Wad.toWad(a);
    }
}
