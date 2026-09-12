// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Script, console} from "forge-std/Script.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Probe: can we read prices from Pyth on Arc?
///
/// This is the single highest-risk assumption in the whole design. The Pyth contract is known to
/// have bytecode at this address on Arc testnet, but that proves nothing about whether publishers
/// are actually pushing prices to this chain. If this script cannot read a fresh price, the
/// oracle-priced vault design does not work on Arc and we need to know now, not at M1.
///
///   forge script script/SpikePythRead.s.sol --rpc-url arc_testnet -vv
contract SpikePythRead is Script {
    IPyth constant PYTH = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43);

    bytes32 constant FX_EUR_USD = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 constant EQUITY_AAPL = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    bytes32 constant METAL_XAU = 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;

    function run() external view {
        console.log("chainid   ", block.chainid);
        console.log("timestamp ", block.timestamp);
        console.log("pyth code ", address(PYTH).code.length);

        _probe("FX.EUR/USD    ", FX_EUR_USD);
        _probe("Equity.US.AAPL", EQUITY_AAPL);
        _probe("Metal.XAU/USD ", METAL_XAU);
    }

    function _probe(string memory label, bytes32 id) internal view {
        // getPriceUnsafe ignores staleness, so we can see the age rather than just reverting on it.
        try PYTH.getPriceUnsafe(id) returns (PythStructs.Price memory p) {
            console.log("---", label);
            console.logInt(p.price);
            console.log("  expo/conf/publishTime:");
            console.logInt(p.expo);
            console.log("  conf   ", p.conf);
            console.log("  age (s)", block.timestamp - p.publishTime);
        } catch Error(string memory reason) {
            console.log("--- FAIL", label, reason);
        } catch (bytes memory data) {
            console.log("--- FAIL", label);
            console.logBytes(data);
        }
    }
}
