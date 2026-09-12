// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

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
        d = _deploy(
            usdc, owner, vm.envOr("ORACLE_KIND", string("push")), uint32(vm.envOr("MAX_AGE_SEC", uint256(0)))
        );
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
        return _deploy(usdc, owner, oracleKind, 0);
    }

    /// @dev Same wiring with an explicit staleness bound, so tests need not go through env vars.
    function deployFor(IERC20 usdc, address owner, string memory oracleKind, uint32 maxAgeSec)
        public
        returns (Deployment memory)
    {
        return _deploy(usdc, owner, oracleKind, maxAgeSec);
    }

    function _deploy(IERC20 usdc, address owner, string memory oracleKind, uint32 maxAgeOverride)
        internal
        returns (Deployment memory d)
    {
        d.oracle = _deployOracle(oracleKind);

        // Deploy owned by whoever is making these calls, configure, then hand over. Constructing
        // straight into the final owner would leave every onlyOwner setter below unreachable,
        // shipping a vault with no assets and no caps.
        //
        // msg.sender, not address(this): under `forge script --broadcast` the contract creations
        // and the setter calls all originate from the broadcasting EOA, while address(this) is the
        // ephemeral script contract - which Foundry refuses to let scripts reference at all.
        d.liquidityVault = new LiquidityVault(usdc, msg.sender);
        d.vault = new SyntheticVault(usdc, d.oracle, d.liquidityVault, msg.sender);
        d.liquidityVault.setVault(address(d.vault));

        // A push-fed deployment needs a staleness bound wider than the pusher's cycle, otherwise
        // trades revert between cycles. MAX_AGE_SEC overrides for either kind.
        bool pushed = keccak256(bytes(oracleKind)) == keccak256("push");

        bytes32[] memory feeds = Config.feeds();
        for (uint256 i; i < feeds.length; ++i) {
            uint32 maxAgeSec = maxAgeOverride != 0
                ? maxAgeOverride
                : (pushed ? Config.PUSHED_MAX_AGE_SEC : Config.defaultMaxAge(feeds[i]));
            d.vault.setAssetConfig(feeds[i], Config.configFor(feeds[i], maxAgeSec));
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
            ChainlinkOracle o = new ChainlinkOracle(msg.sender);
            o.setSyntheticConfBps(20); // Chainlink publishes no confidence; stand one in
            return o;
        }
        return new PushOracle(msg.sender);
    }
}
