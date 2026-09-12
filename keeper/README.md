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
WorkingDirectory=/srv/cope-market/contracts/keeper
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
