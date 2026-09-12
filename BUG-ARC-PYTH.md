# Pyth price updates cannot be verified on Arc testnet

**Impact:** `IPyth.updatePriceFeeds` reverts for every feed on Arc testnet, so no Pyth price can be
posted. Ambient prices are 25 hours to 22 days stale, so reads are unusable too. Any protocol that
prices against Pyth cannot run on Arc testnet.

**Summary:** Pyth's Wormhole receiver on Arc testnet holds **Wormhole's** guardian sets. Pyth price
VAAs are signed by **Pythnet's** guardian set. The verifier has the wrong public keys.

---

## Reproduction

Fetch any price update from Hermes and post it:

```solidity
IPyth pyth = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43); // Arc testnet
bytes[] memory u = /* Hermes /v2/updates/price/latest, encoding=hex */;
pyth.updatePriceFeeds{value: pyth.getUpdateFee(u)}(u);
// reverts 0x2acbe915 = PythErrors.InvalidWormholeVaa()
```

**Control:** the byte-identical blob posted to Base mainnet Pyth
(`0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a`) in the same minute is **accepted**. The update data is
valid.

## Root cause

The VAA carried by every Pyth update is emitted from Pythnet:

```
emitterChain     26 (Pythnet)
emitterAddress   507974686e6574...  ("PythnetPythnetPythnetPythnetPyth")
guardianSetIndex 1
signatures       3, from guardian indices [0, 1, 2]
```

Pythnet's guardian set is small. Chains where Pyth works verify against exactly that set:

| Chain | `IPyth.wormhole()` | current set index | set 1 size | set 1 guardian[0] |
|---|---|---|---|---|
| Base mainnet | `0x581aaF059CC83A353fc51aDC9a0480FbeDFc6c55` | 1 | 5 | `0x41534bB176E461A3fb30479400f210549eCCE638` |
| Arbitrum One | `0x8d289CdD60E7F73F352F42c8524a06Ef1ad746f8` | 1 | 5 | *(same Pythnet set)* |
| **Arc testnet** | `0xb27e5ca259702f209a29225d0eDdC131039C9933` | **7** | **19** | `0x58CC3AE5C097b213cE3c81979e1B9f9570746AA5` |

`0x58CC3AE5C097b213cE3c81979e1B9f9570746AA5` is the well-known Wormhole **devnet** guardian. Arc's
receiver holds Wormhole's own guardian progression — devnet at set 0/1, Wormhole mainnet's 19-key set
by set 7 — rather than Pythnet's 5-key set.

A Pythnet VAA declaring set 1 with 3 signatures is therefore checked against a 19-key set that also
expired at `1768946141`. It fails both quorum and expiry. Every Pyth update fails the same way.

## Fix

Point Arc's Pyth at a `WormholeReceiver` initialised with **Pythnet's** guardian set, as on Base and
Arbitrum — either by deploying a correctly seeded receiver, or by submitting the guardian-set
governance VAAs to the existing one.

## Environment

- Arc testnet, chain id `5042002`, RPC `https://rpc.testnet.arc.io`
- Pyth `0x2880aB155794e7179c9eE2e38200202908C17B43` (per Pyth's EVM contract address list)
- Verified 2026-09-12

## Please also confirm

Whether the **Arc mainnet** (chain id `5042`) Pyth deployment is seeded from Pythnet's guardian set,
so the same fault does not ship at launch.
