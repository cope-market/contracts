import type {Hex} from "viem";
import type {HermesPrice} from "./hermes.js";

/// Deciding what to push.
///
/// `PushOracle` requires a strictly increasing publish time per feed, so a batch containing one
/// unchanged feed reverts as a whole. Everything here exists to make sure the batch that goes out
/// contains only feeds that will be accepted.

export interface PushCandidate {
  feedId: Hex;
  priceWad: bigint;
  confWad: bigint;
  publishTime: number;
}

export interface Skipped {
  feedId: Hex;
  reason: string;
}

export interface PushPlan {
  push: PushCandidate[];
  skipped: Skipped[];
}

export interface PlanInput {
  prices: HermesPrice[];
  /// What the oracle already holds, per feed. Missing means never written.
  storedPublishTime: Map<string, number>;
  /// The chain's current timestamp, which is what the vault compares against.
  chainNow: number;
  /// Publish under chain time rather than the real market time. Keeps a demo tradeable when FX and
  /// equity markets are closed, at the cost of asserting a freshness the data does not have.
  stampNow: boolean;
}

export function planPush(input: PlanInput): PushPlan {
  const push: PushCandidate[] = [];
  const skipped: Skipped[] = [];

  for (const price of input.prices) {
    const key = price.feedId.toLowerCase();
    const stored = input.storedPublishTime.get(key) ?? 0;

    if (price.priceWad <= 0n) {
      // The vault rejects a non-positive price, so sending one would revert the whole batch on
      // behalf of a feed that was never going to work.
      skipped.push({feedId: price.feedId, reason: "Hermes reported a non-positive price"});
      continue;
    }

    let stamp = input.stampNow ? input.chainNow : price.publishTime;

    // Never publish under a future timestamp. Hermes can be marginally ahead of the chain's clock,
    // and a future stamp would make the price look fresh for longer than it is — and would block
    // every later push for that feed until the chain caught up.
    if (stamp > input.chainNow) stamp = input.chainNow;

    if (stamp <= stored) {
      skipped.push({
        feedId: price.feedId,
        reason:
          stored === 0
            ? "no usable timestamp"
            : "no newer data — the market is closed, or the price has not moved",
      });
      continue;
    }

    push.push({
      feedId: price.feedId,
      priceWad: price.priceWad,
      confWad: price.confWad,
      publishTime: stamp,
    });
  }

  return {push, skipped};
}

export interface FeedSelection {
  /// Enabled on chain and fetchable with this key. The set that gets pushed.
  push: Hex[];
  /// Enabled on chain but not fetchable. Users can select these assets and will never be able to
  /// trade them, because the vault will always see a stale price.
  unentitled: Hex[];
  /// Fetchable but not enabled on chain. Harmless, and worth saying so nobody hunts for a bug.
  notEnabled: Hex[];
}

/// Intersects what the vault has enabled with what the API key can fetch.
///
/// The intersection is a correctness requirement rather than a nicety: one unentitled feed fails
/// the entire Hermes request, so asking for everything enabled would push nothing at all.
///
/// The leftovers are the interesting part. A feed enabled in the vault that the key cannot fetch is
/// an asset a user can pick, stake against and never trade — and nothing in the system says so
/// today.
export function selectFeeds(enabledOnChain: Hex[], entitled: Hex[]): FeedSelection {
  const enabled = new Set(enabledOnChain.map((feed) => feed.toLowerCase()));
  const canFetch = new Set(entitled.map((feed) => feed.toLowerCase()));

  return {
    push: enabledOnChain.filter((feed) => canFetch.has(feed.toLowerCase())),
    unentitled: enabledOnChain.filter((feed) => !canFetch.has(feed.toLowerCase())),
    notEnabled: entitled.filter((feed) => !enabled.has(feed.toLowerCase())),
  };
}

export interface Freshness {
  feedId: Hex;
  ageSec: number;
  maxAgeSec: number;
  fresh: boolean;
}

/// Whether the oracle is now fresh enough for the vault to accept, which is the only definition of
/// a successful push that matters.
///
/// A mined transaction is not the same thing. The push can succeed and the feed still be too old —
/// a market closed hours ago, and the timestamp written is the real publish time.
export function assessFreshness(
  storedPublishTime: Map<string, number>,
  maxAgeSec: Map<string, number>,
  chainNow: number,
  feeds: Hex[],
): Freshness[] {
  return feeds.map((feedId) => {
    const key = feedId.toLowerCase();
    const stored = storedPublishTime.get(key) ?? 0;
    const max = maxAgeSec.get(key) ?? 0;
    // A feed never written is infinitely stale, not zero seconds old.
    const ageSec = stored === 0 ? Number.POSITIVE_INFINITY : chainNow - stored;
    return {feedId, ageSec, maxAgeSec: max, fresh: ageSec <= max};
  });
}

/// The largest interval that leaves room to recover from a missed cycle.
///
/// The old script said "keep well under the vault's maxAgeSec" and enforced nothing. A single
/// missed cycle at an interval equal to `maxAgeSec` means every price goes stale and nothing can
/// trade, so the service refuses an interval that leaves no margin.
export function maxSafeInterval(tightestMaxAgeSec: number): number {
  return Math.max(1, Math.floor(tightestMaxAgeSec / 3));
}
