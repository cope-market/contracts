// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";

/// @notice Characterisation tests for the real Pyth deployment on Arc testnet.
///
/// These document what Pyth on Arc actually does today, as opposed to what the docs imply. They
/// are the evidence behind the decision to build the vault against `IPriceOracle` with a mock,
/// rather than against `IPyth` directly. See SPIKE.md.
///
/// Network-gated so the default suite stays offline and fast:
///   FORK_TESTS=1 forge test --match-contract PythArcFork -vv
contract PythArcForkTest is Test {
    IPyth constant PYTH = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43);
    bytes32 constant FX_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) return;
        vm.createSelectFork("arc_testnet");
    }

    modifier forked() {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
        }
        _;
    }

    /// @dev Pyth is deployed and returns correctly-scaled prices, so feed ids and exponents are
    ///      right. But nothing is pushing updates to this chain, so ambient reads are far outside
    ///      any maxAge the vault would accept. The vault must post its own update every trade.
    function test_AmbientPriceIsDeployedButFarTooStale() public forked {
        assertGt(address(PYTH).code.length, 0, "Pyth must be deployed");

        PythStructs.Price memory p = PYTH.getPriceUnsafe(FX_EUR_USD);
        assertGt(p.price, 0, "a price is stored");
        assertEq(p.expo, -5, "EUR/USD exponent");

        uint256 age = block.timestamp - uint256(uint64(p.publishTime));
        assertGt(age, 3600, "ambient price is stale by more than an hour");

        vm.expectRevert(PythErrors.StalePrice.selector);
        PYTH.getPriceNoOlderThan(FX_EUR_USD, 60);
    }

    /// @dev KNOWN ISSUE. Update blobs from mainnet Hermes are rejected by the Wormhole receiver
    ///      that Arc testnet's Pyth points at: the VAA is signed under guardian set 1 with 3
    ///      signatures, but that receiver's set 1 holds 19 guardians and expired at 1768946141.
    ///      Only set 7 is current. So the pull path is unusable on Arc testnet today.
    ///
    ///      When this test starts failing, Arc has fixed the wiring and we can enable the real
    ///      Pyth path on testnet. Until then testnet runs on MockOracle.
    function test_MainnetHermesVaaIsRejected_KnownIssue() public forked {
        bytes[] memory updates = new bytes[](1);
        updates[0] = vm.parseBytes(vm.readFile("test/fixtures/pyth_eurusd.hex"));

        uint256 fee = PYTH.getUpdateFee(updates);
        vm.deal(address(this), fee);

        vm.expectRevert(PythErrors.InvalidWormholeVaa.selector);
        PYTH.updatePriceFeeds{value: fee}(updates);
    }
}
