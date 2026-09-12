# Deployments

## Arc testnet (chain 5042002)

Deployed 2026-09-12. Explorer: https://testnet.arcscan.app

| Contract | Address | Verified |
|---|---|---|
| `SyntheticVault` | [`0x2c720283A8Bbb5CC5b13C0C4Bcf2300826286c47`](https://testnet.arcscan.app/address/0x2c720283A8Bbb5CC5b13C0C4Bcf2300826286c47) | ✅ |
| `LiquidityVault` | [`0x0ffABC4e80125C5742D5ed04Cc1fD1b634Bc3C5d`](https://testnet.arcscan.app/address/0x0ffABC4e80125C5742D5ed04Cc1fD1b634Bc3C5d) | ✅ |
| `PushOracle` | [`0x0f2d191fEC3bB2DEEd8cE3E326193fd9b5203277`](https://testnet.arcscan.app/address/0x0f2d191fEC3bB2DEEd8cE3E326193fd9b5203277) | ✅ |
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
       ORACLE=0x0f2d191fEC3bB2DEEd8cE3E326193fd9b5203277 PRIVATE_KEY=0x...
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

### LP share precision

`LiquidityVault` sets `_decimalsOffset() = 12`, so shares are 18-decimal against a 6-decimal asset.

This was not cosmetic. A previous deployment ran with the default offset of zero and took fees while
total supply was still zero, which left the share price distorted at roughly 4,407:1. Measured on
that live deployment:

| Deposit | Shares minted | Redeemable |
|---|---|---|
| 0.004 USDC | **0** | **0 — total loss** |
| 0.01 USDC | 2 | 0.0088 — 12% lost to rounding |
| 0.1 USDC | 22 | 0.0969 — 3.1% lost |

With the offset, the same deposits return everything but the 0.10% exit fee. The offset also raises
OpenZeppelin's virtual share count to 1e12, which is what makes the classic inflation attack
uneconomic rather than merely awkward.

**The pool is seeded as the first action after deployment**, before anything can donate into an
empty vault. Do the same on mainnet, and hold or burn those first shares.
