// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Config} from "../script/Config.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Runs the real deployment path. A deploy script that is never executed in CI is a script
///         that breaks silently between the last time anyone ran it and the day it matters.
contract DeployTest is Test {
    MockUSDC usdc;
    Deploy deployer;
    Deploy.Deployment d;

    address owner = makeAddr("owner");
    address trader = makeAddr("trader");

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        deployer = new Deploy();
        d = deployer.deployFor(usdc, owner, "push");
    }

    function test_WiresTheTwoVaultsTogether() public view {
        assertEq(address(d.liquidityVault.vault()), address(d.vault));
        assertEq(address(d.vault.liquidityVault()), address(d.liquidityVault));
        assertEq(address(d.vault.oracle()), address(d.oracle));
    }

    function test_TransfersOwnershipToTheConfiguredOwner() public view {
        assertEq(d.vault.owner(), owner);
        assertEq(d.liquidityVault.owner(), owner);
    }

    function test_ConfiguresEveryLaunchAsset() public view {
        bytes32[] memory feeds = Config.feeds();
        assertEq(d.vault.enabledFeeds().length, feeds.length);

        for (uint256 i; i < feeds.length; ++i) {
            (bool enabled,,,,, uint128 maxOi, uint128 maxPos) = d.vault.assetConfig(feeds[i]);
            assertTrue(enabled, "asset must be live");
            assertGt(maxOi, 0, "OI cap must be set");
            assertGt(maxPos, 0, "position cap must be set");
        }
    }

    /// @dev Caps left at zero would be an unlimited-risk deployment that still looks configured.
    function test_SetsProtocolFees() public view {
        assertEq(d.vault.authorFeeBps(), 1000);
        assertEq(d.liquidityVault.exitFeeBps(), 10);
    }

    /// @dev The point of a deployment test: the thing it produces actually trades.
    function test_DeployedSystemCanTakeAndSettleATrade() public {
        PushOracle oracle = PushOracle(address(d.oracle));
        vm.startPrank(owner);
        oracle.setPusher(owner, true);
        oracle.push(Config.FX_EUR_USD, 1e18, 0, uint64(vm.getBlockTimestamp()));
        vm.stopPrank();

        usdc.mint(address(this), 500_000e6);
        usdc.approve(address(d.liquidityVault), type(uint256).max);
        d.liquidityVault.deposit(500_000e6, address(this));

        usdc.mint(trader, 10_000e6);
        vm.startPrank(trader);
        usdc.approve(address(d.vault), type(uint256).max);
        uint256 id = d.vault.open(Config.FX_EUR_USD, true, 1_000e6, 0, new bytes[](0));
        vm.stopPrank();

        // vm.getBlockTimestamp rather than block.timestamp: under via_ir the latter can be cached
        // in a local across the warp, so the push would carry a stale publish time.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(owner);
        oracle.push(Config.FX_EUR_USD, 1.1e18, 0, uint64(vm.getBlockTimestamp()));

        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        d.vault.close(id, new bytes[](0));

        assertGt(usdc.balanceOf(trader) - before, 1_000e6, "a winning trade pays out more than it cost");
    }
}
