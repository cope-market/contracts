# Deployments

## Arc testnet (chain 5042002)

Deployed 2026-09-12. Explorer: https://testnet.arcscan.app

| Contract | Address |
|---|---|
| `SyntheticVault` | `0x607483B50C5F06c25cDC316b6d1E071084EeC9f5` |
| `LiquidityVault` | `0xc2b6aEb0F9c431F26C8cf3343F3c14135accb34a` |
| `PushOracle` | `0x645E01a47672feeA4F229cc5b9E22Ff6393be0CD` |
| USDC (collateral and gas) | `0x3600000000000000000000000000000000000000` |

Owner and pusher: `0xeeb3e0999D01f0d1Ed465513E414725a357F6ae4`. A throwaway testnet key, not used
anywhere else and never to be reused on mainnet.

**Oracle is `PushOracle`, not Pyth.** Pyth's pull path does not work on Arc testnet — see
`SPIKE.md` and `BUG-ARC-PYTH.md`. The price pusher must be running or the vault has no prices:

```bash
export PYTH_API_KEY=... RPC_URL=https://rpc.testnet.arc.io \
       ORACLE=0x645E01a47672feeA4F229cc5b9E22Ff6393be0CD PRIVATE_KEY=0x...
./script/price-pusher.sh --interval 60
```

Config: `maxAgeSec` 600s on every asset, `maxConfBps` 1%, open and close fees 0.10%, author fee 10%
of a copy's profit, LP exit fee 0.10%, per-position cap 25,000 USD, per-side OI cap 250,000 USD.

### Smoke test, run against this deployment

Since USDC writes cannot be fork-tested on Arc, this is the first real end-to-end proof.

| Step | Result |
|---|---|
| Push prices | 4 feeds written |
| `getPrice(BTC, 600)` | 77,337.89, conf 17.60 |
| `getPrice(EUR, 600)` | reverts `StalePrice(…, 49712, 600)` — FX market closed, correctly untradeable |
| LP deposit 20 USDC | 20,000,000 shares, `totalAssets` 20,000,000 |
| Open 2 USDC long BTC | collateral 1,998,000 (2 USDC less the 0.10% fee), entry 77,355.49 = mid **+ conf** |
| `liability(BTC)` | `-454552364643663` — trader marginally underwater, as expected from the entry skew |
| `totalAssets` after | 20,002,454 — LPs up by the open fee plus the trader's loss |
| Close | position burned, `openInterest` back to 0, ~1.9926 USDC returned net of gas |

Confidence skew, fee accounting, staleness enforcement, LP economics and position lifecycle all
behaved exactly as the unit tests predicted, against real USDC on a real chain.
