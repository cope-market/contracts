# Security review

Self-review of the contracts at the end of the initial build, covering correctness, access control,
economics and the usual EVM footguns. Two issues were found and fixed; the rest are accepted risks
recorded here so nobody has to rediscover them.

**These contracts are unaudited hackathon software.**

---

## Findings fixed

### H-1 — Aggregate cost basis drifted after a selective close

**Severity: high. LP shares were mispriced.**

The per-asset aggregate stored a running *average entry price*. An average cannot be un-mixed:
closing one of several positions reduced total units but left the average as a blend of entries no
surviving position actually had. Liability was then marked against a price nobody entered at.

Reproduction, now a regression test in `SyntheticVaultAvgEntryDrift.t.sol`:

```
open 1000 units @ 1.0
open  500 units @ 2.0     -> aggregate average 1.333
close the first position  -> 500 units remain, all entered at 2.0
market at 2.0             -> the pool owes nothing
vault reported            -> liability of 333.33 USD
```

`LiquidityVault.totalAssets` subtracts liability, so every LP share was underpriced by value that
was never owed. Extractable by depositing while the distortion existed and redeeming after it
unwound.

**Fix:** store total notional (`sum(units * entryPrice)`) rather than an average, and subtract each
position's own notional on close, computed the same way it was added so the arithmetic is exact.
Average entry became a derived view. Liability is now a plain mark-to-market.

**Why the invariant suite missed it:** it compared unit quantities, which were correct the whole
time. It now compares cost basis as well.

### L-1 — `totalAssets` rounded in the redeemer's favour

Converting wad liability to USDC used plain integer division, which truncates toward zero. For a
debt that shaved a fraction off what was owed, so the pool reported marginally more assets than it
could back. Sub-micro-USDC in size, but the wrong direction.

**Fix:** debts round up, credits round down. Every rounding decision now favours the protocol.

### M-1 — `setAssetConfig` validated nothing

Found by probing for misconfiguration rather than attack. The owner could set any fee, any
confidence bound, and a zero `maxAgeSec`. Three concrete ways that goes wrong:

- `openFeeBps = 10000` takes the entire deposit. A trader paid 1,000 USDC and received a position
  with **zero units and zero collateral** — funds to the LPs, worthless NFT to them.
- `maxAgeSec = 0` makes every price stale, which blocks opens **and traps open positions**, since
  closing reads the price too.
- `maxConfBps >= 10000` lets confidence exceed price, underflowing the short entry calculation.

None of these require malice. `1000` typed where `10` was meant is a 10% fee.

**Fix:** fees capped at 5% (`MAX_ASSET_FEE_BPS`), confidence bound capped at 10%
(`MAX_CONF_BOUND_BPS`), `maxAgeSec` must be non-zero.

### M-2 — A position with zero units could be minted

Reachable via M-1, but guarded independently: `open` now reverts `ZeroUnits` if the computed
exposure rounds to zero. A position with no exposure is redeemable for nothing, so the trader would
have paid and received nothing.

---

## Accepted risks

Ordered by how much they would matter with real money at stake.

### A-1 — `PushOracle` is fully trusted

The testnet oracle is a single address that can set any price, and the vault prices every position
against it. This exists because Pyth's pull path does not work on Arc testnet (`SPIKE.md`), not
because it is a good design. Mainnet uses `PythOracle` or `ChainlinkOracle`.

### A-2 — Owner is unconstrained and there is no timelock

The owner can change caps, fees, liquidation parameters and disable assets. Two specific griefing
paths: setting `maxAgeSec` to zero makes existing positions impossible to close, and disabling an
asset blocks new opens (closes deliberately still work). Mitigation is procedural — the owner should
be a multisig — not technical.

### A-3 — The oracle is immutable

`SyntheticVault.oracle` is set at construction and cannot be changed. This removes an obvious rug
vector, at the cost of there being no migration path if the oracle breaks. Recovery would mean
deploying a new vault and having users close out of the old one.

### A-4 — A drained pool blocks winning closes

If `LiquidityVault` cannot cover a profitable close it reverts with `InsufficientLiquidity`. That is
a liveness failure, not a solvency one — the position stays open and closeable later — but a winning
trader can be temporarily stuck. Open-interest caps exist to keep the pool's maximum obligation
below its capital; they are the control that makes this unlikely.

### A-5 — ERC-4626 first-depositor inflation

OpenZeppelin v5 mitigates this with virtual shares, but the mitigation is weaker at a decimals
offset of zero. **Deployment requirement:** seed the pool with a non-trivial first deposit whose
shares are burned or held by the team, before the vault is public. The deploy script does not do
this automatically.

### A-6 — Latency arbitrage is inherent to a pull oracle

The caller chooses *when* to post a price update, so they can wait for a favourable tick. Three
controls blunt it rather than eliminate it: open and close fees, a tight `maxAgeSec`, and a
confidence skew that always moves price against the trader. If fees are ever set below typical
oracle drift, this becomes profitable.

### A-7 — No funding rate

A persistently one-sided book costs LPs with nothing to compensate them. Caps bound the damage;
nothing corrects the imbalance. A skew fee is the intended follow-up.

### A-8 — `_feeds` grows without bound

`totalLiability` loops over every configured feed and is called on every LP deposit and withdrawal.
Enough enabled assets would make LP operations expensive and eventually un-runnable. Bounded only by
owner discipline.

### A-9 — Copy attribution does not verify the copy

`copiedFromId` records lineage and pays the origin's author, but nothing requires the copy to be on
the same feed or the same side. It is social metadata, not a guarantee of mirroring; the UI should
not present it as one.

### A-10 — No reentrancy guard

Checks-effects-interactions is followed everywhere: aggregates are updated, the position deleted and
the token burned before any USDC moves, so a re-entrant call finds nothing to close. `_mint` is used
rather than `_safeMint`, so opening a position makes no callback either — deliberate, though it does
mean a contract without `onERC721Received` can still be minted a position. This all relies on the
collateral token having no transfer hooks. **USDC qualifies; a fee-on-transfer or ERC-777-style
token would break these assumptions.**

---

## Checked and found sound

- **Arithmetic.** Solidity 0.8 checked math throughout. Bounds on `units`, notional and P&L stay far
  inside `int256` at realistic caps; the fixed-point boundary is covered by fuzz tests.
- **Decimals.** All internal math is wad; USDC converts only through `Wad`. `fromWad` truncates, so
  dust stays in the contract rather than being minted. Directly tested.
- **Author fee.** Cannot be redirected by transferring either the copy or the origin, is charged
  only on profit, and is clamped to the payout so it can never push a settlement negative.
- **Liquidation.** Threshold boundary is inclusive and tested on both sides. The reward is capped by
  what remains, so a wiped-out position never pays a keeper out of thin air. Permissionless, so the
  protocol does not depend on our keeper.
- **Payout floor.** A trader can be wiped out but the payout never goes negative and the settlement
  arithmetic never underflows.
- **Access control.** `payout` is vault-only, `setVault` is write-once, every parameter setter is
  owner-only with a cap, and the pusher role is separate from ownership.
- **Staleness.** Enforced in the contract, not the UI. Valuation deliberately reads without a
  staleness bound so LP operations do not brick every weekend when FX stops publishing.

---

## Test evidence

149 tests. Coverage: **100% of lines**, 98.21% of branches, 100% of functions across `src/`.

The single uncovered branch is the author-fee clamp in `close`, which is unreachable under the
current caps — with the author fee at most 50% of profit and the close fee at most 5% of exit
notional, the fee cannot exceed the payout on any price path. It is retained as defence in depth
against a future cap change. The two load-bearing invariants were mutation-tested rather than trusted for being green:

| Mutation | Result |
|---|---|
| Halve units removed on close | `long units drifted: 254663103405340496902 != 254658107900790041857` |
| Skim 0.1% from each payout | `vault balance must equal open collateral: 52893782925 != 49949001749` |

Both pass again once reverted.

## Before mainnet

1. Seed the LP pool and burn the first shares (A-5).
2. Move ownership to a multisig (A-2).
3. Confirm Pyth at `0x2880aB155794e7179c9eE2e38200202908C17B43` on chain 5042, else use Chainlink.
4. Set open and close fees above observed oracle drift (A-6).
5. Start with caps well below pool capital (A-4).
