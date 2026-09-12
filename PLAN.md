# Cope Market Contracts — Implementation Plan

Oracle-priced synthetic vault on Arc. See `ARCHITECTURE.md` in
[cope-market-architecture](https://github.com/cope-market/cope-market-architecture) for the system
design this implements.

**Method: strict TDD.** Every production line is preceded by a test that was watched to fail for the
right reason. Each step below ends in a commit and a push.

---

## Design decisions locked before coding

**Decimals.** USDC is 6. All internal math is 1e18 ("wad"). Conversion happens only at the USDC
boundary via `Math.toWad` / `Math.fromWad`, scaling by `1e12`. The two are never added directly.

**Fees are charged in 6-decimal space** so no dust accumulates:

```
openFee6 = collateral6 * openFeeBps / 1e4
net6     = collateral6 - openFee6          // this is what the position stores
units    = (net6 * 1e12) * 1e18 / entryPrice
```

Storing net collateral (not gross) means a close at an unchanged price returns
`net - closeFee`, which is correct. Storing gross would silently refund the open fee.

**Close:**

```
exitNotional = units * exit / 1e18
closeFee     = exitNotional * closeFeeBps / 1e4
pnl          = isLong ? units*(exit-entry)/1e18 : units*(entry-exit)/1e18
gross        = netCollateralWad + pnl - closeFee
payout       = gross > 0 ? gross : 0
```

**Confidence always moves price against the user.** Entry: long `+conf`, short `-conf`. Exit: long
`-conf`, short `+conf`. This absorbs oracle latency drift in the protocol's favour.

**Open interest is measured at entry value** — `units * avgEntry / 1e18` per side — so caps are
deterministic and do not move with price.

**Circular dependency.** `SyntheticVault` calls `LiquidityVault.payout`; `LiquidityVault.totalAssets`
calls `SyntheticVault.liability`. Resolved with interfaces plus a one-time `setVault` on the
liquidity vault, callable by the owner exactly once and immutable after.

**Author fee is snapshotted at open** (`copyAuthor`, `authorFeeBps`) so it survives the origin
position being closed and burned, and so transferring the position NFT cannot redirect it.

---

## Steps

Each step: write tests → watch them fail → minimal implementation → watch them pass → commit → push.

| # | Step | Key tests |
|---|---|---|
| **1** | Repo scaffold | `forge build` and `forge test` run clean on an empty suite |
| **2** | Pyth live-read spike | Script reads `FX.EUR/USD` from Pyth on Arc testnet. De-risks the whole design. Not TDD — a probe. |
| **3** | `Math` library | `toWad`/`fromWad` round-trip; `fromWad` truncates and never rounds up; fuzzed |
| **4** | `IPriceOracle` + `MockOracle` | Returns configured price and conf; reverts `StalePrice` past `maxAge`; `updateFee` is 0 |
| **5** | `SyntheticVault.open` | Mints ERC-721, pulls collateral, stores net collateral, skews entry by conf, computes units, charges open fee |
| **6** | Open guards | Reverts on: disabled asset, stale price, confidence too wide, position cap, OI cap |
| **7** | Aggregate state | `longUnits`/`longAvgEntry` update correctly across multiple opens; weighted average is exact |
| **8** | `SyntheticVault.close` | Long profit, long loss, short profit, short loss; close fee; payout clamps at zero; burns; only owner or approved |
| **9** | `liability()` | Zero with no positions; positive when traders win; negative when they lose; longs and shorts net |
| **10** | `LiquidityVault` | ERC-4626 deposit/redeem; `totalAssets` nets liability; `payout` is `onlyVault`; exit fee stays with remaining LPs |
| **11** | Settlement wiring | Winning close pulls from LV; losing close pushes to LV; fees reach LV; insufficient liquidity reverts cleanly |
| **12** | Copy + author fee | `copiedFromId` and `copyAuthor` snapshot; fee only on profit; **NFT transfer does not redirect the author fee**; payout goes to the current owner |
| **13** | `liquidate()` | Fires exactly at threshold, not one wei before; caller reward; remainder to LV; burns; healthy positions revert |
| **14** | `PythOracle` | Normalises `(price, expo)` to 1e18 for several expos; conf passthrough; fee delegation; fork test against Arc testnet |
| **15** | `ChainlinkOracle` | `latestRoundData` to 1e18 across decimals; static conf bps; stale round rejected |
| **16** | Invariant suite | The eight invariants from `ARCHITECTURE.md §2.6`, fuzzed and stateful |
| **17** | Deploy script | Deploys all three, wires `setVault`, seeds asset configs; dry run against Arc testnet |
| **18** | Security review | Reentrancy, access control, oracle manipulation, rounding direction, overflow, griefing, DoS |

---

## Layout

```
src/
  SyntheticVault.sol
  LiquidityVault.sol
  interfaces/
    IPriceOracle.sol
    ISyntheticVault.sol
    ILiquidityVault.sol
  libraries/
    Math.sol
  oracle/
    PythOracle.sol
    ChainlinkOracle.sol
test/
  Math.t.sol
  MockOracle.t.sol
  SyntheticVaultOpen.t.sol
  SyntheticVaultClose.t.sol
  SyntheticVaultCopy.t.sol
  SyntheticVaultLiquidate.t.sol
  LiquidityVault.t.sol
  Settlement.t.sol
  PythOracle.t.sol
  ChainlinkOracle.t.sol
  invariant/VaultInvariants.t.sol
  mocks/MockOracle.sol, MockUSDC.sol
script/
  Deploy.s.sol
  SpikePythRead.s.sol
```

## Dependencies

- `forge-std`
- `openzeppelin-contracts` v5 — ERC721, ERC4626, Ownable, SafeERC20, ReentrancyGuard
- `pyth-sdk-solidity` — `IPyth`, `PythStructs`

Chainlink's `AggregatorV3Interface` is declared locally rather than pulling the whole package.

## Out of scope for this repo

Backend, subgraph, frontend. Contracts only, per the split with Alok.
