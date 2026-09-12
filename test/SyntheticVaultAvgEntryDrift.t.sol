// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockLiquidityVault} from "./mocks/MockLiquidityVault.sol";

contract AvgEntryDriftTest is Test {
    SyntheticVault vault;
    PushOracle oracle;
    MockUSDC usdc;
    MockLiquidityVault lp;

    address alice = makeAddr("alice");
    bytes32 constant EUR = keccak256("FX.EUR/USD");

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
                maxAgeSec: type(uint32).max,
                maxConfBps: 100,
                openFeeBps: 0,
                closeFeeBps: 0,
                maxOiUsd: type(uint128).max,
                maxPositionUsd: type(uint128).max
            })
        );
        _price(1e18);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(address(lp), 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _price(uint256 p) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        oracle.push(EUR, p, 0, uint64(vm.getBlockTimestamp()));
    }

    function _open(uint128 collateral) internal returns (uint256) {
        vm.prank(alice);
        return vault.open(EUR, true, collateral, 0, new bytes[](0));
    }

    /// @dev Two longs at different prices, then the first is closed. The aggregate average entry
    ///      must end up equal to the surviving position's own entry price -- it is the only
    ///      position left. If closing does not remove that position's share of notional, the
    ///      aggregate keeps a blend of both and liability is computed against a price nobody
    ///      actually entered at.
    function test_AverageEntryIsExactAfterSelectiveClose() public {
        uint256 a = _open(1_000e6); // 1000 units at 1.0
        _price(2e18);
        _open(1_000e6); // 500 units at 2.0

        assertEq(
            vault.avgEntry(EUR, true),
            uint256(2_000e18) * 1e18 / 1_500e18,
            "blend of both while both are open"
        );

        vm.prank(alice);
        vault.close(a, new bytes[](0));

        (uint256 units,,,) = vault.assetState(EUR);
        assertEq(units, 500e18, "only the second position remains");
        assertEq(vault.avgEntry(EUR, true), 2e18, "average must equal the survivor's entry price");
    }

    /// @dev The consequence. With only a position entered at 2.0 left, and the market at 2.0, the
    ///      pool owes nothing. A drifted average makes the vault report a liability that does not
    ///      exist, which directly misprices every LP share.
    function test_LiabilityIsZeroWhenTheOnlySurvivorIsAtTheMarket() public {
        uint256 a = _open(1_000e6);
        _price(2e18);
        _open(1_000e6);

        vm.prank(alice);
        vault.close(a, new bytes[](0));

        assertEq(vault.liability(EUR), int256(0), "no open position is in profit");
    }
}
