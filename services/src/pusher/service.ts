import type {Address, Hex} from "viem";
import {ORACLE_ABI, VAULT_ABI} from "../abi.js";
import {withGasFloor} from "../chain.js";
import type {Clients} from "../chain.js";
import type {Logger} from "../keeper.js";
import {fetchLatest} from "./hermes.js";
import {assessFreshness, planPush, selectFeeds} from "./plan.js";
import type {Freshness, PushPlan} from "./plan.js";

export interface PusherConfig {
  vault: Address;
  oracle: Address;
  apiKey: string;
  /// Feeds this Hermes key can actually fetch. One unentitled feed fails the whole request, so this
  /// is a hard constraint rather than a preference.
  entitledFeeds: Hex[];
  stampNow: boolean;
  minMaxFeePerGasWei: bigint;
}

export interface CycleResult {
  pushed: number;
  skipped: number;
  /// Feeds the vault has enabled that this key cannot fetch. An asset users can select and never
  /// trade.
  unentitled: Hex[];
  freshness: Freshness[];
  /// True when every feed the vault has enabled and we can fetch is inside its own maxAgeSec. This,
  /// not a mined transaction, is what "the pusher is working" means.
  healthy: boolean;
  txHash: Hex | null;
}

/// Reads what the vault has enabled and how stale each asset is allowed to be.
async function readVaultFeeds(
  clients: Clients,
  vault: Address,
): Promise<{enabled: Hex[]; maxAgeSec: Map<string, number>}> {
  const enabled = (await clients.publicClient.readContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "enabledFeeds",
  })) as readonly Hex[];

  const maxAgeSec = new Map<string, number>();
  for (const feedId of enabled) {
    const config = (await clients.publicClient.readContract({
      address: vault,
      abi: VAULT_ABI,
      functionName: "assetConfig",
      args: [feedId],
    })) as readonly [boolean, number, number, number, number, bigint, bigint];
    // Field order is enabled, maxAgeSec, maxConfBps, openFeeBps, closeFeeBps, maxOiUsd,
    // maxPositionUsd. Reading the wrong index here would silently accept a stale price as fresh.
    maxAgeSec.set(feedId.toLowerCase(), Number(config[1]));
  }

  return {enabled: [...enabled], maxAgeSec};
}

async function readStoredTimes(
  clients: Clients,
  oracle: Address,
  feeds: Hex[],
): Promise<Map<string, number>> {
  const stored = new Map<string, number>();
  for (const feedId of feeds) {
    const time = await clients.publicClient.readContract({
      address: oracle,
      abi: ORACLE_ABI,
      functionName: "lastPublishTime",
      args: [feedId],
    });
    stored.set(feedId.toLowerCase(), Number(time));
  }
  return stored;
}

/// One cycle: read the chain, fetch prices, push what will be accepted, then check whether the
/// oracle is actually usable.
export async function cycle(
  clients: Clients,
  config: PusherConfig,
  log: Logger,
): Promise<CycleResult> {
  const {enabled, maxAgeSec} = await readVaultFeeds(clients, config.vault);
  const selection = selectFeeds(enabled, config.entitledFeeds);

  for (const feedId of selection.unentitled) {
    // Not a transient problem and not something a retry fixes. Users can select this asset and will
    // never be able to trade it.
    log.warn(
      `${feedId.slice(0, 12)}… is enabled in the vault but this Hermes key cannot fetch it. ` +
        `Nobody can trade it until the entitlement or the vault config changes.`,
    );
  }

  const block = await clients.publicClient.getBlock();
  const chainNow = Number(block.timestamp);

  const [prices, storedPublishTime] = await Promise.all([
    fetchLatest(config.apiKey, selection.push),
    readStoredTimes(clients, config.oracle, selection.push),
  ]);

  const plan: PushPlan = planPush({
    prices,
    storedPublishTime,
    chainNow,
    stampNow: config.stampNow,
  });

  for (const skip of plan.skipped) {
    log.info(`  skip ${skip.feedId.slice(0, 12)}… ${skip.reason}`);
  }

  let txHash: Hex | null = null;
  if (plan.push.length > 0) {
    const fees = await clients.publicClient.estimateFeesPerGas();
    const priced = withGasFloor(fees, config.minMaxFeePerGasWei);

    txHash = await clients.walletClient.writeContract({
      address: config.oracle,
      abi: ORACLE_ABI,
      functionName: "pushMany",
      args: [
        plan.push.map((entry) => entry.feedId),
        plan.push.map((entry) => entry.priceWad),
        plan.push.map((entry) => entry.confWad),
        plan.push.map((entry) => BigInt(entry.publishTime)),
      ],
      ...priced,
      account: clients.account,
      chain: clients.walletClient.chain ?? null,
    });

    const receipt = await clients.publicClient.waitForTransactionReceipt({hash: txHash});
    if (receipt.status !== "success") {
      throw new Error(`pushMany reverted in ${txHash}`);
    }
    log.info(`pushed ${plan.push.length} feed(s) in ${txHash}`);
  } else {
    log.info("nothing to push");
  }

  // The check that matters. A mined transaction is not a working oracle: a feed can be written and
  // still older than its asset allows, and the vault will reject it either way.
  const afterBlock = await clients.publicClient.getBlock();
  const afterStored = await readStoredTimes(clients, config.oracle, selection.push);
  const freshness = assessFreshness(
    afterStored,
    maxAgeSec,
    Number(afterBlock.timestamp),
    selection.push,
  );

  const stale = freshness.filter((feed) => !feed.fresh);
  for (const feed of stale) {
    log.warn(
      `${feed.feedId.slice(0, 12)}… is ${
        Number.isFinite(feed.ageSec) ? `${feed.ageSec}s` : "never written and so infinitely"
      } old against a ${feed.maxAgeSec}s limit — the vault will reject it`,
    );
  }

  return {
    pushed: plan.push.length,
    skipped: plan.skipped.length,
    unentitled: selection.unentitled,
    freshness,
    healthy: stale.length === 0,
    txHash,
  };
}
