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

#### Proven, not inferred: the blob is genuine and Arc's deployment is misconfigured

The same Hermes blob, posted in the same minute (`test/PythCrossChain.t.sol`):

| Chain | Pyth contract | Result |
|---|---|---|
| Base mainnet | `0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a` | **accepted** |
| Arc testnet | `0x2880aB155794e7179c9eE2e38200202908C17B43` | **rejected**, `0x2acbe915` |

So the update data is valid and our Hermes API key is fine. The difference is which guardian set each
chain's Pyth verifies against:

| Chain | Wormhole receiver | Current set | Set 1 size | Set 1 first guardian |
|---|---|---|---|---|
| Base | `0x581aaF059CC83A353fc51aDC9a0480FbeDFc6c55` | **1** | **5** | `0x41534bB176E461A3fb30479400f210549eCCE638` (Pythnet) |
| Arc testnet | `0xb27e5ca259702f209a29225d0eDdC131039C9933` | **7** | **19** | `0x58CC3AE5C097b213cE3c81979e1B9f9570746AA5` (Wormhole devnet) |

Pyth price VAAs are emitted from **Pythnet** (Wormhole chain id 26, emitter
`PythnetPythnetPythnetPythnetPyth`) and signed by **Pythnet's** 5-guardian set at index 1. Arc's
receiver was instead seeded with **Wormhole's own** guardian sets — devnet at index 0/1, mainnet by
index 7. It is holding the wrong public keys, so no Pyth price update can ever verify.

This is a deployment configuration fault in Pyth-on-Arc, not a Pyth protocol bug, not an entitlement
problem, and not something we can work around from the contract side. See `BUG-ARC-PYTH.md`.

**Consequence:** the real Pyth pull path cannot be exercised on Arc testnet today. Testnet runs on
`PushOracle`. This is why the vault depends on `IPriceOracle` and never on `IPyth` directly.

**Recheck on Arc mainnet launch (Sept 16)** — mainnet is a separate deployment and may be wired
correctly. The characterisation test fails loudly if testnet is fixed.

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


---

# Spike: Arc's dual-representation USDC

Verified 2026-09-12 against Arc testnet. Tests in `test/ArcChain.t.sol` (`FORK_TESTS=1`).

| Question | Answer |
|---|---|
| Chain id | `5042002` |
| ERC-20 `decimals()` at `0x3600…0000` | **6** |
| Native balance decimals | **18** |
| Relationship | `balanceOf(a) == a.balance / 1e12`, exactly `Wad.fromWad` |
| Base fee | **20 gwei**, matching the documented floor |
| Can USDC transfers be fork-tested? | **No.** See below. |

## The two representations are consistent

For a funded account, `eth_getBalance` returned `11705898898359212279` (18 dec) while ERC-20
`balanceOf` returned `11705898` (6 dec). Same balance, the ERC-20 side truncated. This is what the
contracts assume, and it is now asserted against the live chain rather than taken from docs.

`totalSupply()` is the exception: it reports `3.1498e17`, which is neither a sensible 6-decimal nor
18-decimal figure. Do not build anything on it. Nothing in this repo does.

## USDC writes cannot be simulated in a fork

`0x3600…0000` is a proxy, but its EIP-1967 implementation slot reads as zero, so Foundry cannot
resolve the delegate target. State-changing calls run away on gas and revert; reads work fine. A
static `transfer` call against the live node returns `true`, so the token is not broken — forking is.

**Consequences:**

1. Nothing that moves USDC on Arc can be fork-tested. Unit tests use `MockUSDC`.
2. Integration testing must run against the live testnet with a real broadcast, not a fork.
3. The first real proof the system works end to end is a broadcast deploy plus a smoke trade.
