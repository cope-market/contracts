// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Posts the exact same Hermes blob to Pyth on Base and on Arc, to establish whether the
///         blob is bad (our API key / tier) or the chain's Pyth deployment is (Arc's wiring).
contract PythCrossChainTest is Test {
    bytes32 constant FX_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;

    function _blob() internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = vm.parseBytes(vm.readFile("test/fixtures/pyth_eurusd.hex"));
    }

    function _post(string memory rpc, address pythAddr) internal returns (bool ok, bytes memory err) {
        vm.createSelectFork(rpc);
        IPyth pyth = IPyth(pythAddr);
        bytes[] memory u = _blob();
        uint256 fee = pyth.getUpdateFee(u);
        vm.deal(address(this), fee + 1 ether);

        try pyth.updatePriceFeeds{value: fee}(u) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function test_SameBlobOnBaseMainnet() public {
        (bool ok, bytes memory err) =
            _post("https://mainnet.base.org", 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);
        emit log_named_string("base accepted", ok ? "YES" : "NO");
        if (!ok) emit log_named_bytes("base error", err);
        assertTrue(ok, "Base must accept a genuine Pyth mainnet blob");
    }

    function test_SameBlobOnArcTestnet() public {
        (bool ok, bytes memory err) =
            _post("https://rpc.testnet.arc.io", 0x2880aB155794e7179c9eE2e38200202908C17B43);
        emit log_named_string("arc accepted", ok ? "YES" : "NO");
        if (!ok) emit log_named_bytes("arc error", err);
    }
}
