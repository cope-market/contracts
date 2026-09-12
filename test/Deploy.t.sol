// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SetMaxAge} from "../script/SetMaxAge.s.sol";
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
        // The script's interim owner is msg.sender, which under `--broadcast` is the EOA making the
        // calls. Here the Deploy contract itself makes them, so it has to look like the sender.
        vm.prank(address(deployer));
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

    /// @dev A push-fed deployment must tolerate the pusher's cycle time. At the live-oracle bound of
    ///      60s, every trade between cycles would revert StalePrice.
    function test_PushDeploymentUsesTheWiderStalenessBound() public view {
        bytes32[] memory feeds = Config.feeds();
        for (uint256 i; i < feeds.length; ++i) {
            (, uint32 maxAgeSec,,,,,) = d.vault.assetConfig(feeds[i]);
            assertEq(maxAgeSec, Config.PUSHED_MAX_AGE_SEC, "push deployments get the wider bound");
        }
    }

    function test_ExplicitMaxAgeOverridesTheDefault() public {
        Deploy alt_ = new Deploy();
        vm.prank(address(alt_));
        Deploy.Deployment memory alt = alt_.deployFor(usdc, owner, "push", 1234);

        (, uint32 maxAgeSec,,,,,) = alt.vault.assetConfig(Config.FX_EUR_USD);
        assertEq(maxAgeSec, 1234);
    }

    /// @dev The cadence of the price pusher will change, so the bound has to be an ordinary
    ///      operation rather than a redeploy. Everything else about the asset must survive it.
    function test_SetMaxAgeRewritesOnlyTheStalenessBound() public {
        (
            ,,
            uint32 confBefore,
            uint32 openFeeBefore,
            uint32 closeFeeBefore,
            uint128 oiBefore,
            uint128 posBefore
        ) = d.vault.assetConfig(Config.FX_EUR_USD);

        SetMaxAge ops = new SetMaxAge();
        vm.prank(owner);
        d.vault.transferOwnership(address(ops));
        ops.applyTo(d.vault, 300);

        (
            bool enabled,
            uint32 maxAgeAfter,
            uint32 confAfter,
            uint32 openFeeAfter,
            uint32 closeFeeAfter,
            uint128 oiAfter,
            uint128 posAfter
        ) = d.vault.assetConfig(Config.FX_EUR_USD);

        assertEq(maxAgeAfter, 300, "bound updated");
        assertTrue(enabled, "still enabled");
        assertEq(confAfter, confBefore, "confidence bound preserved");
        assertEq(openFeeAfter, openFeeBefore, "open fee preserved");
        assertEq(closeFeeAfter, closeFeeBefore, "close fee preserved");
        assertEq(oiAfter, oiBefore, "OI cap preserved");
        assertEq(posAfter, posBefore, "position cap preserved");
    }

    function test_SetMaxAgeRejectsZero() public {
        SetMaxAge ops = new SetMaxAge();
        vm.prank(owner);
        d.vault.transferOwnership(address(ops));

        vm.expectRevert("maxAgeSec must be non-zero");
        ops.applyTo(d.vault, 0);
    }
}
