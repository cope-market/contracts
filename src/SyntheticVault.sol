// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {ISyntheticVault} from "./interfaces/ISyntheticVault.sol";
import {Wad} from "./libraries/Wad.sol";

/// @notice Oracle-priced synthetic positions, collateralised in USDC, with an LP pool as
///         counterparty to every trade.
///
/// Positions are ERC-721 rather than ERC-20 because each one carries its own entry price: two long
/// positions on the same feed opened at different prices are not interchangeable. Making them
/// fungible would mean pooling holders at one shared average entry, which loses both shorts and
/// per-holder P&L.
contract SyntheticVault is ISyntheticVault, ERC721, Ownable {
    using SafeERC20 for IERC20;

    struct Position {
        bytes32 feedId;
        bool isLong;
        uint64 openedAt;
        uint128 collateral; // USDC, 6 decimals, NET of the open fee
        uint256 units; // 1e18, quantity of the synthetic asset
        uint256 entryPrice; // 1e18, already skewed against the trader
        address author; // who opened this position; never changes, even if the NFT is sold
        uint256 copiedFromId; // origin tokenId for lineage; 0 if original
        address copyAuthor; // snapshot; receives the author fee
        uint16 authorFeeBps; // snapshot of the rate at copy time
    }

    struct AssetConfig {
        bool enabled;
        uint32 maxAgeSec;
        uint32 maxConfBps;
        uint32 openFeeBps;
        uint32 closeFeeBps;
        uint128 maxOiUsd; // per side, 1e18
        uint128 maxPositionUsd; // per position, 1e18
    }

    /// @dev Cost basis is stored as total notional, not as a running average price. An average
    ///      cannot be un-mixed: closing one of several positions would leave a blend of entries
    ///      that no surviving position actually has, and liability would then be measured against a
    ///      price nobody entered at. Notional subtracts exactly.
    struct AssetState {
        uint256 longUnits;
        uint256 longNotional; // USD wad, sum of units * entryPrice
        uint256 shortUnits;
        uint256 shortNotional;
    }

    uint256 internal constant BPS = 1e4;
    uint16 public constant MAX_AUTHOR_FEE_BPS = 5000;
    uint16 public constant MAX_LIQUIDATION_REWARD_BPS = 1000;

    IERC20 public immutable usdc;
    IPriceOracle public immutable oracle;
    ILiquidityVault public immutable liquidityVault;

    uint256 public nextTokenId = 1;

    /// @notice Share of a copied position's profit paid to the author of the position it copied.
    uint16 public authorFeeBps;

    /// @notice Fraction of collateral that must be lost before a position can be liquidated.
    uint16 public liquidationThresholdBps = 9000;

    /// @notice Fraction of collateral paid to whoever liquidates.
    uint16 public liquidationRewardBps = 100;

    mapping(bytes32 feedId => AssetConfig) public assetConfig;
    mapping(uint256 tokenId => Position) private _positions;
    mapping(bytes32 feedId => AssetState) public assetState;

    bytes32[] private _feeds;
    mapping(bytes32 feedId => bool) private _feedKnown;

    event AssetConfigured(bytes32 indexed feedId, AssetConfig config);
    event AuthorFeeSet(uint16 bps);
    event LiquidationParamsSet(uint16 thresholdBps, uint16 rewardBps);
    event PositionLiquidated(
        uint256 indexed tokenId,
        address indexed liquidator,
        bytes32 indexed feedId,
        uint256 exitPrice,
        int256 pnlWad,
        uint256 payout,
        uint256 reward
    );
    event AuthorFeePaid(uint256 indexed tokenId, address indexed author, uint256 amount);
    event PositionClosed(
        uint256 indexed tokenId,
        address indexed closedBy,
        bytes32 indexed feedId,
        uint256 exitPrice,
        int256 pnlWad,
        uint256 payout
    );
    event PositionOpened(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 indexed feedId,
        bool isLong,
        uint128 collateral,
        uint256 units,
        uint256 entryPrice,
        uint256 copiedFromId
    );

    error UnknownPosition(uint256 tokenId);
    error AssetDisabled(bytes32 feedId);
    error ConfidenceTooWide(bytes32 feedId, uint256 confBps, uint256 maxConfBps);
    error PositionTooLarge(bytes32 feedId, uint256 notionalUsd, uint256 maxPositionUsd);
    error ZeroCollateral();
    error AuthorFeeTooHigh(uint16 requested, uint16 max);
    error PositionHealthy(uint256 tokenId, uint256 lossWad, uint256 thresholdWad);
    error InvalidLiquidationParams(uint16 thresholdBps, uint16 rewardBps);
    error NotPositionOwner(uint256 tokenId, address caller);
    error OpenInterestCapExceeded(bytes32 feedId, bool isLong, uint256 oiUsd, uint256 maxOiUsd);

    constructor(IERC20 usdc_, IPriceOracle oracle_, ILiquidityVault liquidityVault_, address initialOwner)
        ERC721("Cope Market Position", "COPE-POS")
        Ownable(initialOwner)
    {
        usdc = usdc_;
        oracle = oracle_;
        liquidityVault = liquidityVault_;
    }

    /// @notice Closes an underwater position on someone else's behalf, paying the caller a reward.
    ///
    /// @dev Permissionless on purpose. A long at 1x cannot lose more than its collateral, but a
    ///      short's loss is unbounded, so without this the pool would absorb the tail. Anyone can
    ///      call it, so the protocol does not depend on our own keeper staying up.
    function liquidate(uint256 tokenId, bytes[] calldata updateData) external payable {
        address owner = _requireOwned(tokenId);
        Position memory pos = _positions[tokenId];
        AssetConfig memory cfg = assetConfig[pos.feedId];

        oracle.updatePrices{value: msg.value}(updateData);
        IPriceOracle.Price memory p = oracle.getPrice(pos.feedId, cfg.maxAgeSec);

        uint256 exitPrice = pos.isLong ? p.price - p.conf : p.price + p.conf;
        (uint256 payout, int256 pnlWad) = _quoteClose(pos, cfg.closeFeeBps, exitPrice);

        uint256 lossWad = pnlWad < 0 ? uint256(-pnlWad) : 0;
        uint256 thresholdWad = Wad.toWad(pos.collateral) * liquidationThresholdBps / BPS;
        if (lossWad < thresholdWad) revert PositionHealthy(tokenId, lossWad, thresholdWad);

        uint256 reward = uint256(pos.collateral) * liquidationRewardBps / BPS;
        if (reward > payout) reward = payout;
        payout -= reward;

        _removeFromSide(pos.feedId, pos.isLong, pos.units, pos.entryPrice);
        delete _positions[tokenId];
        _burn(tokenId);

        _settle(owner, msg.sender, pos.collateral, payout, reward);

        emit PositionLiquidated(tokenId, msg.sender, pos.feedId, exitPrice, pnlWad, payout, reward);
    }

    function setLiquidationParams(uint16 thresholdBps, uint16 rewardBps) external onlyOwner {
        if (thresholdBps > BPS || rewardBps > MAX_LIQUIDATION_REWARD_BPS) {
            revert InvalidLiquidationParams(thresholdBps, rewardBps);
        }
        liquidationThresholdBps = thresholdBps;
        liquidationRewardBps = rewardBps;
        emit LiquidationParamsSet(thresholdBps, rewardBps);
    }

    function setAuthorFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_AUTHOR_FEE_BPS) revert AuthorFeeTooHigh(bps, MAX_AUTHOR_FEE_BPS);
        authorFeeBps = bps;
        emit AuthorFeeSet(bps);
    }

    function setAssetConfig(bytes32 feedId, AssetConfig calldata config) external onlyOwner {
        assetConfig[feedId] = config;
        if (!_feedKnown[feedId]) {
            _feedKnown[feedId] = true;
            _feeds.push(feedId);
        }
        emit AssetConfigured(feedId, config);
    }

    function positions(uint256 tokenId) external view returns (Position memory) {
        Position memory p = _positions[tokenId];
        if (p.entryPrice == 0) revert UnknownPosition(tokenId);
        return p;
    }

    /// @notice Net USD the vault owes open positions on one feed, in wad. Negative means traders
    ///         are underwater and the amount accrues to LPs instead.
    ///
    /// @dev Reads the price with no staleness bound on purpose. FX and equity feeds stop updating
    ///      outside market hours, so a staleness revert here would brick the ERC-4626 vault's
    ///      totalAssets every weekend. Trading is gated on freshness; valuation must not be.
    function liability(bytes32 feedId) public view returns (int256) {
        AssetState storage st = assetState[feedId];
        if (st.longUnits == 0 && st.shortUnits == 0) return 0;

        uint256 px = oracle.getPrice(feedId, type(uint256).max).price;

        // Mark to market against cost basis: what the open units are worth now, less what they cost.
        int256 longPnl = int256(st.longUnits * px / Wad.ONE) - int256(st.longNotional);
        int256 shortPnl = int256(st.shortNotional) - int256(st.shortUnits * px / Wad.ONE);

        return longPnl + shortPnl;
    }

    /// @notice Net USD owed across every configured feed, in wad.
    /// @dev O(feeds), not O(positions). Bounded by how many assets the owner enables.
    function totalLiability() external view returns (int256 total) {
        uint256 len = _feeds.length;
        for (uint256 i; i < len; ++i) {
            total += liability(_feeds[i]);
        }
    }

    function enabledFeeds() external view returns (bytes32[] memory) {
        return _feeds;
    }

    /// @notice Open interest on one side, valued at average entry rather than at the current
    ///         price, so a cap does not tighten or loosen as the market moves.
    function openInterest(bytes32 feedId, bool isLong) public view returns (uint256) {
        AssetState storage st = assetState[feedId];
        return isLong ? st.longNotional : st.shortNotional;
    }

    /// @notice Notional-weighted average entry for one side, derived rather than stored.
    function avgEntry(bytes32 feedId, bool isLong) external view returns (uint256) {
        AssetState storage st = assetState[feedId];
        (uint256 units, uint256 notional) =
            isLong ? (st.longUnits, st.longNotional) : (st.shortUnits, st.shortNotional);
        return units == 0 ? 0 : notional * Wad.ONE / units;
    }

    /// @dev Keeping units and notional as running sums is what makes liability O(assets) rather
    ///      than O(positions), and what makes a partial close exact.
    function _addToSide(bytes32 feedId, bool isLong, uint256 units, uint256 entryPrice) internal {
        AssetState storage st = assetState[feedId];
        uint256 notional = units * entryPrice / Wad.ONE;

        if (isLong) {
            st.longUnits += units;
            st.longNotional += notional;
        } else {
            st.shortUnits += units;
            st.shortNotional += notional;
        }
    }

    /// @notice Closes a position and settles it against the LP pool.
    /// @dev State is cleared and the token burned before any USDC moves, so a re-entrant call
    ///      finds nothing left to close.
    function close(uint256 tokenId, bytes[] calldata updateData) external payable {
        address owner = _requireOwned(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert NotPositionOwner(tokenId, msg.sender);

        Position memory pos = _positions[tokenId];
        AssetConfig memory cfg = assetConfig[pos.feedId];

        oracle.updatePrices{value: msg.value}(updateData);
        IPriceOracle.Price memory p = oracle.getPrice(pos.feedId, cfg.maxAgeSec);

        // Confidence moves against the trader on the way out too: a long exits below mid.
        uint256 exitPrice = pos.isLong ? p.price - p.conf : p.price + p.conf;
        (uint256 payout, int256 pnlWad) = _quoteClose(pos, cfg.closeFeeBps, exitPrice);

        // The author earns only when the copy earns. No profit, no fee.
        uint256 authorFee;
        if (pos.copyAuthor != address(0) && pnlWad > 0) {
            authorFee = Wad.fromWad(uint256(pnlWad) * pos.authorFeeBps / BPS);
            if (authorFee > payout) authorFee = payout;
            payout -= authorFee;
        }

        _removeFromSide(pos.feedId, pos.isLong, pos.units, pos.entryPrice);
        delete _positions[tokenId];
        _burn(tokenId);

        _settle(owner, pos.copyAuthor, pos.collateral, payout, authorFee);

        emit PositionClosed(tokenId, msg.sender, pos.feedId, exitPrice, pnlWad, payout);
        if (authorFee != 0) emit AuthorFeePaid(tokenId, pos.copyAuthor, authorFee);
    }

    /// @dev Attribution is snapshotted at open, from the origin's `author` rather than its current
    ///      owner. Reading the owner would let someone buy a popular position to capture fees they
    ///      did not earn; reading it lazily at close would break once the origin is burned.
    function _resolveCopy(uint256 copiedFromId) internal view returns (address copyAuthor_, uint16 feeBps_) {
        if (copiedFromId == 0) return (address(0), 0);

        Position storage origin = _positions[copiedFromId];
        if (origin.entryPrice == 0) revert UnknownPosition(copiedFromId);

        return (origin.author, authorFeeBps);
    }

    /// @notice Payout in USDC and signed P&L in wad, for a position exiting at `exitPrice`.
    function _quoteClose(Position memory pos, uint32 closeFeeBps, uint256 exitPrice)
        internal
        pure
        returns (uint256 payout, int256 pnlWad)
    {
        uint256 exitNotional = pos.units * exitPrice / Wad.ONE;
        uint256 closeFee = exitNotional * closeFeeBps / BPS;

        int256 entry = int256(pos.entryPrice);
        int256 exit_ = int256(exitPrice);
        int256 delta = pos.isLong ? exit_ - entry : entry - exit_;
        pnlWad = int256(pos.units) * delta / int256(Wad.ONE);

        int256 gross = int256(Wad.toWad(pos.collateral)) + pnlWad - int256(closeFee);
        // A trader can be wiped out but never owes more than their collateral. The shortfall is
        // the LPs' risk, which is what liquidation exists to bound.
        payout = gross > 0 ? Wad.fromWad(uint256(gross)) : 0;
    }

    /// @dev Tops up from the LP pool when the trader won, and returns the remainder to it when they
    ///      lost. Close fees arrive at the pool the same way, inside the remainder.
    function _settle(address owner, address author, uint128 collateral, uint256 payout, uint256 authorFee)
        internal
    {
        uint256 total = payout + authorFee;
        if (total > collateral) {
            liquidityVault.payout(address(this), total - collateral);
        } else if (total < collateral) {
            usdc.safeTransfer(address(liquidityVault), collateral - total);
        }
        if (payout != 0) usdc.safeTransfer(owner, payout);
        if (authorFee != 0) usdc.safeTransfer(author, authorFee);
    }

    /// @dev Subtracts this position's own notional, computed the same way it was added, so the
    ///      aggregate stays exactly the sum over surviving positions.
    function _removeFromSide(bytes32 feedId, bool isLong, uint256 units, uint256 entryPrice) internal {
        AssetState storage st = assetState[feedId];
        uint256 notional = units * entryPrice / Wad.ONE;

        if (isLong) {
            st.longUnits -= units;
            st.longNotional -= notional;
        } else {
            st.shortUnits -= units;
            st.shortNotional -= notional;
        }
    }

    /// @notice Opens a 1x long or short against the LP pool.
    /// @param updateData Oracle payload, posted before the price is read. Empty for push oracles.
    function open(
        bytes32 feedId,
        bool isLong,
        uint128 collateral,
        uint256 copiedFromId,
        bytes[] calldata updateData
    ) external payable returns (uint256 tokenId) {
        AssetConfig memory cfg = assetConfig[feedId];
        // Checked before touching the oracle so an unconfigured feed reports the real reason
        // rather than a confusing PriceUnavailable.
        if (!cfg.enabled) revert AssetDisabled(feedId);
        if (collateral == 0) revert ZeroCollateral();

        oracle.updatePrices{value: msg.value}(updateData);
        IPriceOracle.Price memory p = oracle.getPrice(feedId, cfg.maxAgeSec);

        // A wide confidence interval means the oracle itself is unsure. Trading against it is how
        // a vault gets picked off during thin or disorderly markets.
        uint256 confBps = p.conf * BPS / p.price;
        if (confBps > cfg.maxConfBps) revert ConfidenceTooWide(feedId, confBps, cfg.maxConfBps);

        // Confidence always moves the price against the trader.
        uint256 entryPrice = isLong ? p.price + p.conf : p.price - p.conf;

        uint256 openFee = uint256(collateral) * cfg.openFeeBps / BPS;
        uint128 net = uint128(collateral - openFee);

        uint256 notionalUsd = Wad.toWad(net);
        if (notionalUsd > cfg.maxPositionUsd) {
            revert PositionTooLarge(feedId, notionalUsd, cfg.maxPositionUsd);
        }

        uint256 units = notionalUsd * Wad.ONE / entryPrice;
        (address copyAuthor_, uint16 feeBps_) = _resolveCopy(copiedFromId);

        _addToSide(feedId, isLong, units, entryPrice);
        uint256 oi = openInterest(feedId, isLong);
        if (oi > cfg.maxOiUsd) revert OpenInterestCapExceeded(feedId, isLong, oi, cfg.maxOiUsd);

        usdc.safeTransferFrom(msg.sender, address(this), collateral);
        if (openFee != 0) usdc.safeTransfer(address(liquidityVault), openFee);

        tokenId = nextTokenId++;
        _positions[tokenId] = Position({
            feedId: feedId,
            isLong: isLong,
            openedAt: uint64(block.timestamp),
            collateral: net,
            units: units,
            entryPrice: entryPrice,
            author: msg.sender,
            copiedFromId: copiedFromId,
            copyAuthor: copyAuthor_,
            authorFeeBps: feeBps_
        });
        _mint(msg.sender, tokenId);

        emit PositionOpened(tokenId, msg.sender, feedId, isLong, net, units, entryPrice, copiedFromId);
    }
}
