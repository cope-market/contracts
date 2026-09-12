# Spike: Pyth on Arc testnet

Run before writing any vault code, because the whole design rests on being able to read a fresh
oracle price on Arc. Date: 2026-09-12. Reproduce with `script/SpikePythRead.s.sol` and
`test/PythArcFork.t.sol` (`FORK_TESTS=1`).

## Summary

| Question | Answer |
|---|---|
| Is Pyth deployed on Arc testnet? | **Yes.** `0x2880aB155794e7179c9eE2e38200202908C17B43`, 177 bytes. |
| Do feed ids and exponents work? | **Yes.** EUR/USD 1.16090 (expo -5), AAPL 316.97, XAU 4597.687 (expo -3). |
| Are ambient prices usable? | **No.** EUR/USD 25h stale, XAU 16 days, AAPL 22 days. Nothing pushes updates to this chain. |
| Can we post our own update blob? | **No, not on testnet.** Mainnet Hermes VAAs are rejected with `InvalidWormholeVaa()`. |
| Does the API key cover every feed? | **No.** Entitlement is per feed. |

## Detail

### Ambient prices are stale, so the pull model is mandatory

Reading whatever happens to be stored is not an option — `getPriceNoOlderThan(id, 60)` reverts
`StalePrice()` on every feed. This is expected for a pull oracle and matches the architecture: the
vault posts its own update blob inside every open and close. It does mean there is no fallback to
ambient reads if blob posting fails.

### Mainnet Hermes VAAs are rejected on Arc testnet

`updatePriceFeeds` reverts with `InvalidWormholeVaa()` (`0x2acbe915`). Cause, from on-chain state:

- Arc testnet Pyth points at Wormhole receiver `0xb27e5ca259702f209a29225d0eDdC131039C9933`.
- Hermes blobs carry a VAA signed under **guardian set 1 with 3 signatures**.
- On that receiver, set 1 holds **19 guardians** and **expired at 1768946141** (~234 days ago).
  Sets 0, 1 and 2 are all expired; only **set 7** is current.

So the VAA fails both quorum and expiry. The receiver expects standard Wormhole VAAs while Hermes
serves Pythnet-signed ones. `hermes-beta` does not help — it rejects the API key outright.

**Consequence:** the real Pyth pull path cannot be exercised on Arc testnet today. Testnet runs on
`MockOracle`. This is why the vault depends on `IPriceOracle` and never on `IPyth` directly.

**Recheck on Arc mainnet launch (Sept 16)** — mainnet may be wired correctly. The characterisation
test fails loudly if testnet is fixed.

### The API key has per-feed entitlements

`Not entitled: feed <id> (invalid API key)`, HTTP 403. Any request containing one unentitled feed
fails entirely, so feeds cannot be batched blindly.

| Feed | Result |
|---|---|
| `FX.EUR/USD` | 200 |
| `Metal.XAU/USD` | 200 |
| `Crypto.BTC/USD` | 200 |
| `Equity.US.TSLA/USD` | 200 |
| `Equity.US.AAPL/USD` | **403** |
| `Equity.US.SPY/USD` | **403** |
| `Equity.US.NVDA/USD` | **403** |

Verified twice per feed; deterministic, not rate limiting.

## Decisions this forces

1. **Contracts depend on `IPriceOracle`, never `IPyth`.** Already the plan; now it is load-bearing
   rather than tidy.
2. **Testnet demos run on `MockOracle`** with a price-pusher, not real Pyth.
3. **The asset catalogue must be entitlement-checked**, not taken from Pyth's 1,249-feed list. A
   feed in the catalogue that 403s is a broken market in the UI.
4. **Open question for the team:** upgrade the Pyth plan to cover the equities we want, or ship
   FX + metals + crypto + whatever equities are entitled. Chainlink on Arc mainnet has no equity
   feeds either, so this cannot be solved by switching oracle.
