# Deployments

## Arc testnet (chain 5042002)

Deployed 2026-09-12. Explorer: https://testnet.arcscan.app

| Contract | Address | Verified |
|---|---|---|
| `SyntheticVault` | [`0xBC9697fdcD58bED8A87E90f0cD6ed0Fc1b104524`](https://testnet.arcscan.app/address/0xBC9697fdcD58bED8A87E90f0cD6ed0Fc1b104524) | ✅ |
| `LiquidityVault` | [`0xD28a08692D291e38c970DdAE776D0deFD12538E2`](https://testnet.arcscan.app/address/0xD28a08692D291e38c970DdAE776D0deFD12538E2) | ✅ |
| `PushOracle` | [`0x48503a79a8d35E15dF274BDf9fD9272E69DefD87`](https://testnet.arcscan.app/address/0x48503a79a8d35E15dF274BDf9fD9272E69DefD87) | ✅ |
| USDC (collateral and gas) | `0x3600000000000000000000000000000000000000` | — |

Owner and pusher: `0xeeb3e0999D01f0d1Ed465513E414725a357F6ae4`. A throwaway testnet key, never reused
on mainnet.

Config: `maxAgeSec` 600s on every asset, `maxConfBps` 1%, open and close fees 0.10%, author fee 10%
of a copy's profit, LP exit fee 0.10%, per-position cap 25,000 USD, per-side OI cap 250,000 USD.

### Compiler is pinned to 0.8.36 for a reason

arcscan's Blockscout carries solc up to **v0.8.36** out of 1,657 versions. On 0.8.37 the contracts
compile and run fine but the explorer cannot recompile them, so verification returns
`Fail - Unable to verify` and a judge sees unverified source. Sourcify does have 0.8.37 and matched
cleanly, but Blockscout will not accept its relay for a compiler it lacks.

**Do not bump past 0.8.36 without checking the explorer's supported list first.**

### The oracle is `PushOracle`, not Pyth

Pyth's pull path does not work on Arc testnet — see `SPIKE.md` and `BUG-ARC-PYTH.md`. The price
pusher must be running or the vault has no prices and nothing can trade:

```bash
export PYTH_API_KEY=... RPC_URL=https://rpc.testnet.arc.io \
       ORACLE=0x48503a79a8d35E15dF274BDf9fD9272E69DefD87 PRIVATE_KEY=0x...
./script/price-pusher.sh --interval 60
```

### Smoke test against this deployment

USDC writes cannot be fork-tested on Arc, so this is the real evidence.

| Step | Result |
|---|---|
| Push prices | 4 feeds written |
| Open 2 USDC long BTC | collateral 1,998,000 (2 USDC less the 0.10% fee), entry 77,325.70 = mid **+ conf** |
| `liability(BTC)` | `-203243159890433` — marginally underwater, as the entry skew implies |
| Close | burned, `openInterest` back to 0, ~1.9931 USDC returned net of gas |
| LP `totalAssets` | 20,004,405 → 20,008,810 across the trade: fees plus the trader's loss |
| `open` on EUR/USD | reverts — FX market closed, correctly untradeable |
| LP `redeem` | full balance returned less the 0.10% exit fee |

### One live confirmation of SECURITY.md A-5

The first LP deposit into the new vault minted **4,539 shares for 20 USDC**, because an earlier trade
had already pushed 4,405 units of fees into the vault while total supply was zero. Assets present
before any shares exist inflate the share price — harmless here since the same account held both
sides, but it is exactly the ERC-4626 first-depositor situation A-5 describes.

**Seed the pool and burn the first shares before it is public.**
