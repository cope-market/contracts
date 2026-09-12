// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../../src/SyntheticVault.sol";
import {PushOracle} from "../../src/oracle/PushOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockLiquidityVault} from "../mocks/MockLiquidityVault.sol";

/// Emits quote fixtures for the backend by actually opening positions and reading back what the
/// contract stored.
///
/// The backend has to show a user an entry price, a unit count and a fee before they sign, and
/// SyntheticVault has no quote view, so that arithmetic is reimplemented in TypeScript. Generating
/// the expected values from real contract execution means parity is proven against the
/// implementation rather than against a careful reading of it.
///
///   forge test --match-contract GenerateQuoteFixtures
///
/// Writes out/parity/quotes.json. Copy it into the backend when the contract's maths changes.
contract GenerateQuoteFixturesTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address trader = address(0xA11CE);
    bytes32 constant FEED = keccak256("PARITY/USD");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        oracle = new PushOracle(address(this));
        oracle.setPusher(address(this), true);
        lp = new MockLiquidityVault(usdc);
        vault = new SyntheticVault(usdc, oracle, lp, address(this));
        lp.setVault(address(vault));

        usdc.mint(trader, 1_000_000_000e6);
        usdc.mint(address(lp), 1_000_000_000e6);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _configure(uint32 openFeeBps, uint32 maxConfBps) internal {
        vault.setAssetConfig(
            FEED,
            SyntheticVault.AssetConfig({
                enabled: true,
                maxAgeSec: type(uint32).max,
                maxConfBps: maxConfBps,
                openFeeBps: openFeeBps,
                closeFeeBps: 10,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );
    }

    function test_WriteQuoteFixtures() public {
        // Prices and confidences spanning the real feeds: FX near 1, equities in the hundreds,
        // gold in the thousands, BTC in the tens of thousands. Fees at 0, the default and the cap.
        uint256[6] memory prices =
            [uint256(1.16e18), 365.275e18, 4349.021e18, 77337.89e18, 1e18, 99999.999999e18];
        uint256[6] memory confs = [uint256(0), 0.0004e18, 17.598e18, 1.5e18, 0.01e18, 12.34e18];
        uint128[6] memory collaterals = [uint128(1e6), 2e6, 1000e6, 25_000e6, 1, 7_777_777];
        uint32[3] memory fees = [uint32(0), 10, 500];

        string memory out = "[";
        uint256 written;

        for (uint256 f; f < fees.length; ++f) {
            _configure(fees[f], 1000);
            for (uint256 i; i < prices.length; ++i) {
                for (uint256 side; side < 2; ++side) {
                    bool isLong = side == 0;

                    vm.warp(block.timestamp + 1);
                    oracle.push(FEED, prices[i], confs[i], uint64(block.timestamp));

                    vm.prank(trader);
                    uint256 tokenId = vault.open(FEED, isLong, collaterals[i], 0, new bytes[](0));
                    SyntheticVault.Position memory p = vault.positions(tokenId);

                    if (written > 0) out = string.concat(out, ",");
                    out = string.concat(
                        out,
                        "{",
                        '"price":"',
                        vm.toString(prices[i]),
                        '",',
                        '"conf":"',
                        vm.toString(confs[i]),
                        '",',
                        '"collateral":"',
                        vm.toString(uint256(collaterals[i])),
                        '",',
                        '"openFeeBps":',
                        vm.toString(uint256(fees[f])),
                        ",",
                        '"isLong":',
                        isLong ? "true" : "false",
                        ",",
                        '"expectedNetCollateral":"',
                        vm.toString(uint256(p.collateral)),
                        '",',
                        '"expectedEntryPrice":"',
                        vm.toString(p.entryPrice),
                        '",',
                        '"expectedUnits":"',
                        vm.toString(p.units),
                        '"',
                        "}"
                    );
                    ++written;
                }
            }
        }

        out = string.concat(out, "]");
        vm.writeFile("out/parity/quotes.json", out);
        assertGt(written, 30, "generated a meaningful number of cases");
    }
}
