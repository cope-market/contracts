// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidityVault} from "../../src/interfaces/ILiquidityVault.sol";

/// @notice Stands in for LiquidityVault while the synthetic vault is built in isolation.
contract MockLiquidityVault is ILiquidityVault {
    IERC20 public immutable usdc;
    address public vault;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setVault(address v) external {
        vault = v;
    }

    function payout(address to, uint256 amount) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        uint256 bal = usdc.balanceOf(address(this));
        if (bal < amount) revert InsufficientLiquidity(amount, bal);
        usdc.transfer(to, amount);
    }
}
