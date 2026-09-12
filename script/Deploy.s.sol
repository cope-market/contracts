// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {SyntheticVault} from "../src/SyntheticVault.sol";
import {LiquidityVault} from "../src/LiquidityVault.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {PushOracle} from "../src/oracle/PushOracle.sol";
import {PythOracle} from "../src/oracle/PythOracle.sol";
import {ChainlinkOracle} from "../src/oracle/ChainlinkOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Config} from "./Config.sol";

/// @notice Deploys the protocol and wires it.
///
///   ORACLE_KIND=push forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
///
/// ORACLE_KIND selects the price source: `push` for Arc testnet, where Pyth's pull path is broken
/// (SPIKE.md); `pyth` once it works; `chainlink` on Arc mainnet, which has 30 published feeds but
/// no equities.
contract Deploy is Script {
    struct Deployment {
        LiquidityVault liquidityVault;
        SyntheticVault vault;
        IPriceOracle oracle;
    }

    function run() external returns (Deployment memory d) {
        address owner = vm.envOr("OWNER", msg.sender);
        IERC20 usdc = IERC20(vm.envAddress("USDC"));

        vm.startBroadcast();
        d = _deploy(usdc, owner, vm.envOr("ORACLE_KIND", string("push")));
        vm.stopBroadcast();

        console.log("oracle         ", address(d.oracle));
        console.log("liquidityVault ", address(d.liquidityVault));
        console.log("syntheticVault ", address(d.vault));
    }

    /// @dev Exposed so the deployment test exercises the same wiring the script performs, rather
    ///      than a parallel copy of it that could drift.
    function deployFor(IERC20 usdc, address owner, string memory oracleKind)
        public
        returns (Deployment memory)
    {
        return _deploy(usdc, owner, oracleKind);
    }

    function _deploy(IERC20 usdc, address owner, string memory oracleKind)
        internal
        returns (Deployment memory d)
    {
        d.oracle = _deployOracle(oracleKind);

        // Deploy owned by the deployer, configure, then hand over. Constructing straight into the
        // final owner would leave every onlyOwner setter below unreachable, shipping a vault with
        // no assets and no caps.
        d.liquidityVault = new LiquidityVault(usdc, address(this));
        d.vault = new SyntheticVault(usdc, d.oracle, d.liquidityVault, address(this));
        d.liquidityVault.setVault(address(d.vault));

        bytes32[] memory feeds = Config.feeds();
        for (uint256 i; i < feeds.length; ++i) {
            d.vault.setAssetConfig(feeds[i], Config.configFor(feeds[i]));
        }

        d.liquidityVault.setExitFeeBps(10); // 0.10%
        d.vault.setAuthorFeeBps(1000); // 10% of a copy's profit

        d.vault.transferOwnership(owner);
        d.liquidityVault.transferOwnership(owner);
        _transferOracleOwnership(d.oracle, owner);
    }

    function _transferOracleOwnership(IPriceOracle oracle, address owner) internal {
        try Ownable(address(oracle)).transferOwnership(owner) {} catch {}
    }

    function _deployOracle(string memory kind) internal returns (IPriceOracle) {
        bytes32 k = keccak256(bytes(kind));

        if (k == keccak256("pyth")) {
            return new PythOracle(IPyth(vm.envAddress("PYTH")));
        }
        if (k == keccak256("chainlink")) {
            ChainlinkOracle o = new ChainlinkOracle(address(this));
            o.setSyntheticConfBps(20); // Chainlink publishes no confidence; stand one in
            return o;
        }
        return new PushOracle(address(this));
    }
}
