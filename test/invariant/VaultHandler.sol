// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {SyntheticVault} from "../../src/SyntheticVault.sol";
import {LiquidityVault} from "../../src/LiquidityVault.sol";
import {PushOracle} from "../../src/oracle/PushOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Drives the protocol through random but legal sequences so the invariants are tested
///         against real state transitions rather than hand-picked scenarios.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    SyntheticVault public vault;
    LiquidityVault public lv;
    PushOracle public oracle;
    MockUSDC public usdc;

    bytes32[] public feeds;
    address[] public actors;
    uint256[] public openIds;

    uint256 public ghostAuthorFeesPaid;

    constructor(SyntheticVault v, LiquidityVault l, PushOracle o, MockUSDC u, bytes32[] memory f) {
        vault = v;
        lv = l;
        oracle = o;
        usdc = u;
        feeds = f;

        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0x1000 + i));
            actors.push(a);
            usdc.mint(a, 10_000_000e6);
            vm.prank(a);
            usdc.approve(address(vault), type(uint256).max);
            vm.prank(a);
            usdc.approve(address(lv), type(uint256).max);
        }
    }

    function openIdCount() external view returns (uint256) {
        return openIds.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _feed(uint256 seed) internal view returns (bytes32) {
        return feeds[seed % feeds.length];
    }

    function openPosition(uint256 actorSeed, uint256 feedSeed, bool isLong, uint256 collateralSeed) external {
        uint128 collateral = uint128(bound(collateralSeed, 1e6, 50_000e6));
        vm.prank(_actor(actorSeed));
        try vault.open(_feed(feedSeed), isLong, collateral, 0, new bytes[](0)) returns (uint256 id) {
            openIds.push(id);
        } catch {}
    }

    function openCopy(uint256 actorSeed, uint256 idSeed, uint256 collateralSeed) external {
        if (openIds.length == 0) return;
        uint256 origin = openIds[idSeed % openIds.length];
        uint128 collateral = uint128(bound(collateralSeed, 1e6, 50_000e6));

        SyntheticVault.Position memory p;
        try vault.positions(origin) returns (SyntheticVault.Position memory got) {
            p = got;
        } catch {
            return;
        }

        vm.prank(_actor(actorSeed));
        try vault.open(p.feedId, p.isLong, collateral, origin, new bytes[](0)) returns (uint256 id) {
            openIds.push(id);
        } catch {}
    }

    function closePosition(uint256 idSeed) external {
        if (openIds.length == 0) return;
        uint256 i = idSeed % openIds.length;
        uint256 id = openIds[i];

        address owner;
        try vault.ownerOf(id) returns (address o) {
            owner = o;
        } catch {
            _remove(i);
            return;
        }

        vm.prank(owner);
        try vault.close(id, new bytes[](0)) {
            _remove(i);
        } catch {}
    }

    function liquidatePosition(uint256 idSeed, uint256 actorSeed) external {
        if (openIds.length == 0) return;
        uint256 i = idSeed % openIds.length;

        vm.prank(_actor(actorSeed));
        try vault.liquidate(openIds[i], new bytes[](0)) {
            _remove(i);
        } catch {}
    }

    /// @dev Prices move hard: the point is to push positions into liquidation and the pool into
    ///      stress, not to simulate a calm market.
    function movePrice(uint256 feedSeed, uint256 priceSeed) external {
        uint256 price = bound(priceSeed, 0.01e18, 100e18);
        vm.warp(block.timestamp + 1);
        try oracle.push(_feed(feedSeed), price, 0, uint64(block.timestamp)) {} catch {}
    }

    function lpDeposit(uint256 actorSeed, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e6, 1_000_000e6);
        vm.prank(_actor(actorSeed));
        try lv.deposit(amount, _actor(actorSeed)) {} catch {}
    }

    function lpWithdraw(uint256 actorSeed, uint256 shareSeed) external {
        address a = _actor(actorSeed);
        uint256 shares = lv.balanceOf(a);
        if (shares == 0) return;
        shares = bound(shareSeed, 1, shares);
        vm.prank(a);
        try lv.redeem(shares, a, a) {} catch {}
    }

    function _remove(uint256 i) internal {
        openIds[i] = openIds[openIds.length - 1];
        openIds.pop();
    }
}
