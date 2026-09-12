# Cope Market — Contracts

Oracle-priced synthetic vault on [Arc](https://docs.arc.io). Users open long or short synthetic
positions in FX, metals and equities against a USDC pool supplied by liquidity providers. Prices
come from Pyth. Positions are ERC-721; LP shares are ERC-4626.

- **System design:** [cope-market-architecture](https://github.com/cope-market/cope-market-architecture)
- **Build plan:** [`PLAN.md`](./PLAN.md)

## Contracts

| Contract | Standard | Role |
|---|---|---|
| `SyntheticVault` | ERC-721 | Positions. Open, close, liquidate, copy attribution. |
| `LiquidityVault` | ERC-4626 | LP capital. NAV nets open-position liability. |
| `PythOracle` | — | Pull oracle adapter. Primary. |
| `ChainlinkOracle` | — | Push oracle adapter. Mainnet fallback. |

## Develop

```bash
forge build
forge test -vvv
forge fmt
```

Copy `.env.example` to `.env` before running scripts that need network access.

## Status

Pre-audit, hackathon software. Not for production use.
