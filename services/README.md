# Liquidation keeper

Closes underwater `SyntheticVault` positions and collects the reward.

`liquidate` is permissionless on purpose: a long at 1x cannot lose more than its collateral, but a
short's loss is unbounded, so without someone calling it the LP pool absorbs the tail. Permissionless
only helps if somebody is watching, and on Arc testnet nobody else is.

## Running it

```bash
npm install
npm run keeper -- --once           # one sweep, reports only
npm run keeper -- --once --send    # one sweep, sends transactions
npm run keeper -- --send           # runs until stopped
```

Sending is opt-in. The default is a dry run, so the first thing anyone runs to see what it does
cannot spend money.

Configuration comes from `contracts/.env`, which already holds the key used for deployment and price
pushing:

| Variable                  | Meaning                                    |
| ------------------------- | ------------------------------------------ |
| `PRIVATE_KEY`             | The keeper's account. Needs a gas balance. |
| `SYNTHETIC_VAULT_ADDRESS` | The vault to watch.                        |
| `RPC_URL`                 | Defaults to Arc testnet.                   |
| `KEEPER_INTERVAL_SECONDS` | Seconds between sweeps. Default 60.        |

## How it decides

**It simulates `liquidate` rather than recomputing the health check.** The alternative is reading
the position and the oracle and reproducing `_quoteClose` and the threshold in TypeScript, which
puts contract arithmetic in a second language. A drift there does not announce itself: it shows up
as a keeper that either misses liquidations or burns gas on reverts. `eth_call` runs the contract's
real logic against real state, so it succeeds exactly when a transaction would.

**It reads the open set from the chain, not the subgraph.** `nextTokenId` is public and `ownerOf`
reverts for a burned token. An index is behind by design, and for a keeper that means positions it
cannot see.

**Every revert is classified, and an unrecognised one is loud.** `PositionHealthy` means skip.
`StalePrice` means the oracle has not been pushed and nothing can be done — which also means trading
is broken, so it is worth waking up for. Anything else is reported as an error rather than quietly
treated as "not liquidatable", because that is how a keeper stops working while still reporting that
everything is fine.

**One transaction at a time.** Several liquidatable positions in one sweep would otherwise be a
nonce race against itself.

## The ABI is generated

```bash
node scripts/gen-abi.mjs    # after forge build
```

Hand-writing it went wrong twice. The stale-price error is `StalePrice`, not `PriceStale`, and viem
decodes a revert only against an ABI that declares it — a wrong name arrives as opaque hex.
Then taking the errors from `SyntheticVault` alone was still short: Solidity omits from a contract's
ABI any error thrown inside an external call, and `StalePrice` is raised by the oracle and only
propagated by the vault. The generator now merges the errors of every contract of ours and fails the
build if the three the keeper depends on are missing.

## Running it on the VPS

```ini
# /etc/systemd/system/cope-keeper.service
[Unit]
Description=Cope Market liquidation keeper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/srv/cope-market/contracts/services
ExecStart=/usr/bin/npm run keeper -- --send
Restart=always
RestartSec=30
# The key lives in contracts/.env, which this reads two directories up.
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now cope-keeper
journalctl -u cope-keeper -f
```

`Restart=always` because the failure that matters is the RPC going away, and the next sweep is the
cheapest place to find out it came back.

## Economics

A liquidation pays `liquidationRewardBps` of the position's collateral — 1% at present, so 0.02 USDC
on a 2 USDC position — against Arc's 20 gwei gas floor. On testnet that is not worth having, and the
keeper runs anyway: the point is bounding LP risk, not earning the reward. Each liquidation logs its
gas cost so the trade-off is visible rather than assumed.

## What it will not do

It does not open, close, deposit or withdraw. The only transaction it can send is `liquidate`, and
the only thing that gains it is the reward the contract pays for the call.

## Verified end to end on Arc testnet

`liquidate` had never been called on a live deployment. It has now.

A position was opened for the test rather than an existing one being used, the threshold was
lowered so it qualified, `--token` kept every other position out of scope, and the threshold was
restored afterwards. Lowering a parameter rather than pushing a false price means nothing about the
vault's accounting was falsified to make the test work.

```
[keeper] threshold 0.01% of collateral lost; reward 1% of collateral
[keeper] mode      SENDING
[keeper] scope     position 6 only
[keeper] position 6: liquidated in 0xda75585254c1..., gas 128535 at 21000000000 wei (0.002699235 USDC)
```

|                             |                                                                       |
| --------------------------- | --------------------------------------------------------------------- |
| `PositionLiquidated` reward | `19980` — exactly 1% of the position's `1998000` collateral           |
| Payout to the owner         | `1975282`                                                             |
| Realised                    | `-740036948395095` WAD                                                |
| `ownerOf(6)` afterwards     | reverts; the NFT is burned                                            |
| Subgraph                    | same `payout`, `liquidationReward` and P&L, `liquidationsPerformed` 1 |

The subgraph's liquidation handling was written before anything could produce a `PositionLiquidated`
event. This is the first time it has indexed one.

### Gas is USDC, and it shows up in the token balance

Arc's native currency is USDC at 18 decimals and the ERC-20 at `0x3600…0000` is a 6-decimal view of
the same balance. They are not two assets. The keeper's ERC-20 balance moved by `1991342` across
the test where payout plus reward was `1995262`, and the `3920` difference is the gas for the
liquidation and the two parameter changes. Anything reconciling USDC balances on Arc has to account
for gas, which is not true on a chain where gas is a different token.

---

# Price pusher

Feeds prices to `PushOracle`. Without it the vault has no prices and nothing can open or close.

This exists only because Pyth's pull path does not work on Arc — the chain's Wormhole receiver holds
Wormhole's guardian set rather than Pythnet's, so a valid update blob is rejected. When that is
fixed, this service is deleted rather than improved.

```bash
npm run pusher -- --once              # one cycle
npm run pusher -- --interval 60       # runs until stopped
npm run pusher -- --interval 60 --stamp-now
```

## What it does that the shell script did not

**Feeds come from the chain.** `enabledFeeds()` intersected with what the Hermes key can fetch. A
feed the vault has enabled that the key cannot fetch is an asset users can select and never trade,
and the pusher now says so on every cycle instead of nobody noticing.

**A push is judged by the oracle, not by the receipt.** After pushing, each feed's age is compared
against that asset's own `maxAgeSec`. A price can be written and still too old, and those look
identical from a mined transaction. This is why a cycle can report `1 pushed` and
`SOME FEEDS UNUSABLE` in the same line — which is the true state most weekends.

**The interval is enforced.** The script said "keep well under the vault's `maxAgeSec`". This reads
the tightest `maxAgeSec` on chain and refuses anything slower than a third of it, so one missed
cycle does not take every price stale.

**Sustained failure is louder than a blip.** One failed cycle is a warning; three in a row is an
error naming the consequence. Repeating one line at one volume forever is the same as no alerting.

**One instance.** Two pushers share a key and race nonces, producing intermittent "nonce too low"
errors that look like an RPC fault. The second one says so and exits. The lock records a pid and is
taken over if that process is gone, so a crash does not keep the service down.

## Health

Each cycle writes `/tmp/cope-pusher-status.json` (override with `PUSHER_HEARTBEAT`):

```json
{
  "at": "2026-09-12T21:09:58.598Z",
  "ok": true,
  "healthy": false,
  "pushed": 1,
  "feeds": [{"feedId": "0xe62df6…", "ageSec": 5, "maxAgeSec": 600, "fresh": true}]
}
```

`ok` is whether the cycle ran. `healthy` is whether every feed is usable by the vault. They differ
whenever a market is closed, and the difference is the point: the pusher is working and the vault
still cannot price three of its four assets.

The dangerous failure is silence — the process dies, prices go stale, and the first symptom is a
trade reverting mid-demo. Check the file's timestamp, not the logs.

## `--stamp-now`

Publishes under the chain's clock rather than the real market time, which keeps a demo tradeable
when FX and equity markets are closed. It asserts a freshness the data does not have. Opt-in, warned
about on every start, and never appropriate for anything but a demo.

## Running it on the VPS

```ini
# /etc/systemd/system/cope-pusher.service
[Unit]
Description=Cope Market price pusher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/srv/cope-market/contracts/services
ExecStart=/usr/bin/npx tsx src/pusher/index.ts --interval 60
Restart=always
RestartSec=15
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now cope-pusher cope-keeper
journalctl -u cope-pusher -f
```

`ExecStart` runs the entrypoint directly rather than through `npm run`. npm adds a wrapper process
between systemd and the service, and signals then have to travel one hop further than they should.

The two services log under `[pusher]` and `[keeper]` so one journal stays readable.

## The shell script is still there

`script/price-pusher.sh` still works and still does the arithmetic correctly. It stays until this
service has run a demo. Deleting the thing that works before its replacement has proved itself is
how a demo ends up with neither.
