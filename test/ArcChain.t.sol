// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Wad} from "../src/libraries/Wad.sol";

/// @notice Characterises Arc's dual-representation USDC against the live chain.
///
/// Arc's native currency is USDC with 18 decimals, while the ERC-20 view of the same balance uses
/// 6. Mixing the two is the single easiest way to be wrong by a factor of 1e12 on this chain, so the
/// relationship is pinned here rather than trusted from documentation.
///
///   FORK_TESTS=1 forge test --match-contract ArcChain -vv
contract ArcChainTest is Test {
    IERC20Metadata constant USDC = IERC20Metadata(0x3600000000000000000000000000000000000000);

    /// @dev A funded testnet account, used read-only.
    address constant FUNDED = 0x311F471eF24971B6728F8b628C82e5396d222Fa9;

    modifier forked() {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
        }
        _;
    }

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork("arc_testnet");
    }

    function test_ChainId() public forked {
        assertEq(block.chainid, 5042002);
    }

    /// @dev The ERC-20 view reports 6 decimals, which is what every contract in this repo assumes.
    function test_Erc20ViewIsSixDecimals() public forked {
        assertEq(USDC.decimals(), 6);
        assertEq(USDC.symbol(), "USDC");
    }

    /// @dev The same balance, two representations, differing by exactly Wad.USDC_SCALE. The native
    ///      side carries sub-micro-USDC precision that the ERC-20 side truncates away.
    function test_NativeIsEighteenDecimalsAndErc20IsTruncatedSixDecimals() public forked {
        uint256 native = FUNDED.balance;
        uint256 erc20 = USDC.balanceOf(FUNDED);

        assertGt(native, 0, "pick a funded account");
        assertEq(erc20, native / Wad.USDC_SCALE, "ERC-20 view is the native balance truncated");
        assertEq(erc20, Wad.fromWad(native), "and Wad.fromWad is exactly that conversion");
    }

    /// @dev KNOWN LIMITATION. Arc's USDC is a proxy whose implementation is not published at the
    ///      EIP-1967 slot (it reads as zero), so a Foundry fork cannot resolve the delegate target
    ///      and any state-changing call runs away on gas and reverts. Reads work, writes do not.
    ///
    ///      Consequence: nothing that moves USDC on Arc can be fork-tested. Unit tests use MockUSDC
    ///      and integration has to run against the live testnet with a real broadcast.
    ///
    ///      A static call to the same function against the live node returns true, so this is a
    ///      simulation limitation, not a broken token. When this test starts failing, forks work and
    ///      the constraint can be lifted.
    function test_TransfersCannotBeSimulatedInAFork_KnownLimitation() public forked {
        vm.prank(FUNDED);
        try USDC.transfer(makeAddr("recipient"), 1_000_000) {
            fail();
        } catch {}
    }

    /// @dev Arc enforces a 20 gwei floor on maxFeePerGas. A transaction built with less is rejected,
    ///      so anything constructing transactions server-side has to account for it.
    function test_BaseFeeFloorIsTwentyGwei() public forked {
        assertGe(block.basefee, 20 gwei, "Arc's documented gas floor");
    }
}
