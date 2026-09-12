// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ISyntheticVault} from "./interfaces/ISyntheticVault.sol";
import {Wad} from "./libraries/Wad.sol";

/// @notice LP capital for the synthetic vault. Depositors underwrite every open position: traders'
///         losses and fees accrue to them, traders' profits are paid out of their capital.
contract LiquidityVault is ILiquidityVault, ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_EXIT_FEE_BPS = 1000; // 10%
    uint256 internal constant BPS = 1e4;

    ISyntheticVault public vault;
    uint16 public exitFeeBps;

    event VaultSet(address indexed vault);
    event ExitFeeSet(uint16 bps);

    error VaultAlreadySet();
    error ExitFeeTooHigh(uint16 requested, uint16 max);

    constructor(IERC20 usdc_, address initialOwner)
        ERC20("Cope Market Liquidity", "COPE-LP")
        ERC4626(usdc_)
        Ownable(initialOwner)
    {}

    /// @dev Write-once. The synthetic vault can move LP capital, so the ability to repoint it would
    ///      be a licence to drain the pool.
    function setVault(address vault_) external onlyOwner {
        if (address(vault) != address(0)) revert VaultAlreadySet();
        vault = ISyntheticVault(vault_);
        emit VaultSet(vault_);
    }

    function setExitFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_EXIT_FEE_BPS) revert ExitFeeTooHigh(bps, MAX_EXIT_FEE_BPS);
        exitFeeBps = bps;
        emit ExitFeeSet(bps);
    }

    /// @notice USDC held, less what the synthetic vault currently owes open positions.
    ///
    /// @dev Netting the liability is what stops an LP depositing just before traders lose and
    ///      withdrawing just before they win, which would extract value from the other LPs. The
    ///      figure comes from per-asset aggregates, so this stays cheap regardless of how many
    ///      positions are open.
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (address(vault) == address(0)) return balance;

        int256 owed = vault.totalLiability() / int256(Wad.USDC_SCALE);
        int256 nav = int256(balance) - owed;
        return nav > 0 ? uint256(nav) : 0;
    }

    /// @inheritdoc ILiquidityVault
    function payout(address to, uint256 amount) external {
        if (msg.sender != address(vault)) revert NotVault(msg.sender);

        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance < amount) revert InsufficientLiquidity(amount, balance);

        IERC20(asset()).safeTransfer(to, amount);
    }

    /// @dev The exit fee is simply not paid out, so it stays in the pool and lifts the share price
    ///      for the LPs who remain. Reporting the net here is what makes `redeem` withhold it:
    ///      ERC4626.redeem forwards this value straight to `_withdraw`.
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        return gross - (gross * exitFeeBps / BPS);
    }

    /// @dev Grossed up so that a caller asking to withdraw `assets` receives exactly `assets`.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 gross = Math.ceilDiv(assets * BPS, BPS - exitFeeBps);
        return super.previewWithdraw(gross);
    }
}
