// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";
import {Wad} from "./libraries/Wad.sol";

/// @notice Oracle-priced synthetic positions, collateralised in USDC, with an LP pool as
///         counterparty to every trade.
///
/// Positions are ERC-721 rather than ERC-20 because each one carries its own entry price: two long
/// positions on the same feed opened at different prices are not interchangeable. Making them
/// fungible would mean pooling holders at one shared average entry, which loses both shorts and
/// per-holder P&L.
contract SyntheticVault is ERC721, Ownable {
    using SafeERC20 for IERC20;

    struct Position {
        bytes32 feedId;
        bool isLong;
        uint64 openedAt;
        uint128 collateral; // USDC, 6 decimals, NET of the open fee
        uint256 units; // 1e18, quantity of the synthetic asset
        uint256 entryPrice; // 1e18, already skewed against the trader
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

    uint256 internal constant BPS = 1e4;

    IERC20 public immutable usdc;
    IPriceOracle public immutable oracle;
    ILiquidityVault public immutable liquidityVault;

    uint256 public nextTokenId = 1;

    mapping(bytes32 feedId => AssetConfig) public assetConfig;
    mapping(uint256 tokenId => Position) private _positions;

    bytes32[] private _feeds;
    mapping(bytes32 feedId => bool) private _feedKnown;

    event AssetConfigured(bytes32 indexed feedId, AssetConfig config);
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

    constructor(IERC20 usdc_, IPriceOracle oracle_, ILiquidityVault liquidityVault_, address initialOwner)
        ERC721("Cope Market Position", "COPE-POS")
        Ownable(initialOwner)
    {
        usdc = usdc_;
        oracle = oracle_;
        liquidityVault = liquidityVault_;
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
            copiedFromId: copiedFromId,
            copyAuthor: address(0),
            authorFeeBps: 0
        });
        _mint(msg.sender, tokenId);

        emit PositionOpened(tokenId, msg.sender, feedId, isLong, net, units, entryPrice, copiedFromId);
    }
}
