# Cope Market — Contracts

Oracle-priced synthetic vault on [Arc](https://docs.arc.io). Users open long or short synthetic
positions in FX, metals and equities against a USDC pool supplied by liquidity providers. Prices
come from Pyth. Positions are ERC-721; LP shares are ERC-4626.

- **System design:** [cope-market-architecture](https://github.com/cope-market/cope-market-architecture)
- **Build plan:** [`PLAN.md`](./PLAN.md)

## Deployed on Arc testnet

| Contract | Address |
|---|---|
| `SyntheticVault` | [`0xBC9697fdcD58bED8A87E90f0cD6ed0Fc1b104524`](https://testnet.arcscan.app/address/0xBC9697fdcD58bED8A87E90f0cD6ed0Fc1b104524) |
| `LiquidityVault` | [`0xD28a08692D291e38c970DdAE776D0deFD12538E2`](https://testnet.arcscan.app/address/0xD28a08692D291e38c970DdAE776D0deFD12538E2) |
| `PushOracle` | [`0x48503a79a8d35E15dF274BDf9fD9272E69DefD87`](https://testnet.arcscan.app/address/0x48503a79a8d35E15dF274BDf9fD9272E69DefD87) |

All three verified on [arcscan](https://testnet.arcscan.app). Chain 5042002; USDC at
`0x3600000000000000000000000000000000000000` is both collateral and gas. Full details, config and
smoke-test results in [`DEPLOYMENTS.md`](./DEPLOYMENTS.md).

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

Solc is pinned to **0.8.36**: arcscan's Blockscout does not carry 0.8.37, and contracts it cannot
recompile cannot be verified. Check the explorer's supported versions before bumping.

Copy `.env.example` to `.env` before running scripts that need network access.

## Price pusher

`PushOracle` stores whatever was last written to it. Nothing writes unless we do, so a deployment
without the pusher running has no prices and no trade can open or close.

```bash
export PYTH_API_KEY=... RPC_URL=https://rpc.testnet.arc.io ORACLE=0x... PRIVATE_KEY=0x...
./script/price-pusher.sh --once
./script/price-pusher.sh --interval 60
```

It fetches the entitled feeds from Hermes, scales `(price, expo)` to wad, drops any feed whose
publish time has not advanced, and writes the rest in a single `pushMany`.

The cycle must stay **well under the vault's `maxAgeSec`**, or trades revert between cycles.
Push-oracle deployments therefore default to a 600s bound rather than the 60s a live oracle
supports. Change it later without redeploying:

```bash
VAULT=0x... MAX_AGE_SEC=300 forge script script/SetMaxAge.s.sol --rpc-url arc_testnet --broadcast
```

**Markets close.** Hermes keeps returning the same publish time while they are shut, and re-posting
it is correctly rejected as not-newer, so those feeds simply stop updating. Measured on a Saturday:
FX and gold 13h stale, TSLA 10h, and only `Crypto.BTC/USD` still live. Demos out of hours should
lead with BTC. `--stamp-now` republishes under chain time instead, which keeps everything tradeable
at the cost of asserting a freshness the data does not have — acceptable only against an oracle
already documented as fully trusted, and never on mainnet.

This whole component is a workaround for Arc's Pyth deployment (see `SPIKE.md`). When that is fixed,
`ORACLE_KIND=pyth` replaces it and this script is deleted.

## Status

Pre-audit, hackathon software. Not for production use.
