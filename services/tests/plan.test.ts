import {describe, expect, it} from "vitest";
import type {Hex} from "viem";
import type {HermesPrice} from "../src/pusher/hermes.js";
import {assessFreshness, maxSafeInterval, planPush, selectFeeds} from "../src/pusher/plan.js";

const BTC = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43" as Hex;
const EUR = "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b" as Hex;
const AAPL = "0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688" as Hex;

const NOW = 1_789_247_000;

function price(feedId: Hex, publishTime: number, priceWad = 10n ** 18n): HermesPrice {
  return {feedId, priceWad, confWad: 10n ** 15n, publishTime};
}

function stored(entries: [Hex, number][]): Map<string, number> {
  return new Map(entries.map(([feed, time]) => [feed.toLowerCase(), time]));
}

describe("planning a push", () => {
  it("pushes a feed with newer data", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 10)],
      storedPublishTime: stored([[BTC, NOW - 60]]),
      chainNow: NOW,
      stampNow: false,
    });

    expect(plan.push).toHaveLength(1);
    expect(plan.push[0]?.publishTime).toBe(NOW - 10);
  });

  /// PushOracle requires a strictly increasing publish time, so one unchanged feed in the batch
  /// reverts the whole thing — every other feed included.
  it("drops a feed whose timestamp has not moved", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 60)],
      storedPublishTime: stored([[BTC, NOW - 60]]),
      chainNow: NOW,
      stampNow: false,
    });

    expect(plan.push).toHaveLength(0);
    expect(plan.skipped[0]?.reason).toMatch(/market is closed/);
  });

  it("drops a feed whose timestamp has gone backwards", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 120)],
      storedPublishTime: stored([[BTC, NOW - 60]]),
      chainNow: NOW,
      stampNow: false,
    });
    expect(plan.push).toHaveLength(0);
  });

  it("pushes a feed the oracle has never seen", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 10)],
      storedPublishTime: stored([]),
      chainNow: NOW,
      stampNow: false,
    });
    expect(plan.push).toHaveLength(1);
  });

  /// Hermes can run marginally ahead of the chain's clock. A future stamp makes the price look
  /// fresh for longer than it is, and blocks every later push for that feed until the chain catches
  /// up — so it is clamped rather than rejected.
  it("never publishes under a future timestamp", () => {
    const plan = planPush({
      prices: [price(BTC, NOW + 30)],
      storedPublishTime: stored([[BTC, NOW - 60]]),
      chainNow: NOW,
      stampNow: false,
    });

    expect(plan.push[0]?.publishTime).toBe(NOW);
  });

  it("rejects a non-positive price rather than letting it revert the batch", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 10, 0n), price(EUR, NOW - 10)],
      storedPublishTime: stored([]),
      chainNow: NOW,
      stampNow: false,
    });

    expect(plan.push.map((entry) => entry.feedId)).toEqual([EUR]);
    expect(plan.skipped[0]?.reason).toMatch(/non-positive/);
  });

  /// The whole point of the batch: a closed market must not stop an open one from updating.
  it("pushes the feeds that moved and skips the ones that did not", () => {
    const plan = planPush({
      prices: [price(BTC, NOW - 5), price(EUR, NOW - 90_000)],
      storedPublishTime: stored([
        [BTC, NOW - 60],
        [EUR, NOW - 90_000],
      ]),
      chainNow: NOW,
      stampNow: false,
    });

    expect(plan.push.map((entry) => entry.feedId)).toEqual([BTC]);
    expect(plan.skipped.map((entry) => entry.feedId)).toEqual([EUR]);
  });

  describe("stamping under chain time", () => {
    /// Keeps a demo tradeable when FX and equity markets are closed, by asserting a freshness the
    /// data does not have. Opt-in, and loud about it elsewhere.
    it("republishes a stale feed under the current chain time", () => {
      const plan = planPush({
        prices: [price(EUR, NOW - 90_000)],
        storedPublishTime: stored([[EUR, NOW - 90_000]]),
        chainNow: NOW,
        stampNow: true,
      });

      expect(plan.push).toHaveLength(1);
      expect(plan.push[0]?.publishTime).toBe(NOW);
    });

    /// Two cycles inside one block share a chain timestamp, and the second is not newer. Without
    /// this the batch reverts and the cycle looks like a failure.
    it("still drops a feed already stamped at this chain time", () => {
      const plan = planPush({
        prices: [price(EUR, NOW - 90_000)],
        storedPublishTime: stored([[EUR, NOW]]),
        chainNow: NOW,
        stampNow: true,
      });
      expect(plan.push).toHaveLength(0);
    });
  });
});

describe("choosing feeds", () => {
  /// One unentitled feed fails the entire Hermes request, so asking for everything the vault has
  /// enabled would push nothing at all.
  it("pushes only what is both enabled and fetchable", () => {
    const selection = selectFeeds([BTC, EUR, AAPL], [BTC, EUR]);
    expect(selection.push).toEqual([BTC, EUR]);
  });

  /// The finding worth surfacing: an asset a user can pick, stake against, and never trade, because
  /// its price can never be written.
  it("names a feed the vault enabled that the key cannot fetch", () => {
    const selection = selectFeeds([BTC, AAPL], [BTC]);
    expect(selection.unentitled).toEqual([AAPL]);
  });

  it("names a fetchable feed the vault has not enabled", () => {
    const selection = selectFeeds([BTC], [BTC, EUR]);
    expect(selection.notEnabled).toEqual([EUR]);
  });

  it("matches regardless of case", () => {
    const selection = selectFeeds([BTC.toUpperCase().replace("0X", "0x") as Hex], [BTC]);
    expect(selection.push).toHaveLength(1);
    expect(selection.unentitled).toHaveLength(0);
  });

  it("pushes nothing when the vault has nothing enabled", () => {
    expect(selectFeeds([], [BTC]).push).toEqual([]);
  });
});

describe("freshness after a push", () => {
  /// A mined transaction is not a successful push. The question the vault will ask is whether the
  /// stored price is inside that asset's maxAgeSec, and it can be written and still too old.
  it("calls a feed fresh when it is inside its own maxAgeSec", () => {
    const [freshness] = assessFreshness(
      stored([[BTC, NOW - 100]]),
      new Map([[BTC.toLowerCase(), 600]]),
      NOW,
      [BTC],
    );
    expect(freshness).toMatchObject({ageSec: 100, maxAgeSec: 600, fresh: true});
  });

  it("calls a feed stale when it is past it", () => {
    const [freshness] = assessFreshness(
      stored([[BTC, NOW - 900]]),
      new Map([[BTC.toLowerCase(), 600]]),
      NOW,
      [BTC],
    );
    expect(freshness?.fresh).toBe(false);
  });

  it("uses each asset's own maxAgeSec rather than one number", () => {
    const freshness = assessFreshness(
      stored([
        [BTC, NOW - 500],
        [EUR, NOW - 500],
      ]),
      new Map([
        [BTC.toLowerCase(), 600],
        [EUR.toLowerCase(), 300],
      ]),
      NOW,
      [BTC, EUR],
    );
    expect(freshness[0]?.fresh).toBe(true);
    expect(freshness[1]?.fresh).toBe(false);
  });

  /// A feed never written is infinitely stale. Treating an unwritten feed as zero seconds old would
  /// report a brand new deployment as perfectly healthy.
  it("treats a feed that was never written as infinitely old", () => {
    const [freshness] = assessFreshness(stored([]), new Map([[BTC.toLowerCase(), 600]]), NOW, [
      BTC,
    ]);
    expect(freshness?.fresh).toBe(false);
    expect(freshness?.ageSec).toBe(Number.POSITIVE_INFINITY);
  });
});

describe("the safe interval", () => {
  /// The old script said "keep well under maxAgeSec" and enforced nothing. At an interval equal to
  /// maxAgeSec, one missed cycle means every price is stale and nothing can trade.
  it("leaves room to miss a cycle", () => {
    expect(maxSafeInterval(600)).toBe(200);
    expect(maxSafeInterval(60)).toBe(20);
  });

  it("never returns zero, however tight the asset", () => {
    expect(maxSafeInterval(1)).toBe(1);
    expect(maxSafeInterval(0)).toBe(1);
  });
});
