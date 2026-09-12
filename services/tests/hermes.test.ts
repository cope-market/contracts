import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";
import {describe, expect, it} from "vitest";
import {HermesError, fetchLatest, toWad} from "../src/pusher/hermes.js";

const here = dirname(fileURLToPath(import.meta.url));
/// A real Hermes answer, captured live. The binary VAA is stripped: it is megabytes of Wormhole
/// payload that Arc cannot verify and this service never uses.
const FIXTURE = readFileSync(join(here, "fixtures", "hermes-latest.json"), "utf8");

const BTC = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43" as const;

function stubFetch(answer: () => Response | Promise<Response>): typeof fetch {
  return (async () => answer()) as unknown as typeof fetch;
}

describe("scaling to 18 decimals", () => {
  /// The real BTC entry from the fixture: 7719114861519 at exponent -8 is 77191.14861519 USD.
  it("rescales a negative exponent by multiplying", () => {
    expect(toWad(7_719_114_861_519n, -8)).toBe(77_191_148_615_190_000_000_000n);
  });

  it("handles each feed's own exponent", () => {
    // EUR/USD at -5, gold at -3, TSLA at -5. One shared exponent would misprice three of four.
    expect(toWad(115_985n, -5)).toBe(1_159_850_000_000_000_000n);
    expect(toWad(4_349_021n, -3)).toBe(4_349_021_000_000_000_000_000n);
    expect(toWad(36_527_500n, -5)).toBe(365_275_000_000_000_000_000n);
  });

  it("is exact at eighteen decimals", () => {
    expect(toWad(1n, -18)).toBe(1n);
  });

  it("treats a zero exponent as a whole-number price", () => {
    expect(toWad(5n, 0)).toBe(5_000_000_000_000_000_000n);
  });

  /// Division happens only for an exponent finer than eighteen decimals. Truncating toward zero is
  /// a rounding the vault already tolerates on a price, and errs narrow on a confidence interval.
  it("divides only when the exponent is finer than eighteen decimals", () => {
    expect(toWad(12_345n, -19)).toBe(1_234n);
    expect(toWad(9n, -19)).toBe(0n);
  });

  /// Doing this in double precision would lose the low digits of every BTC price, because
  /// 77191.14861519e18 is far past 2^53.
  it("keeps every digit of a value past 2^53", () => {
    expect(toWad(7_719_114_861_519n, -8).toString()).toBe("77191148615190000000000");
  });
});

describe("fetching", () => {
  it("parses every feed in a real answer", async () => {
    const prices = await fetchLatest(
      "key",
      [BTC],
      stubFetch(() => new Response(FIXTURE, {status: 200})),
    );

    expect(prices).toHaveLength(4);
    const btc = prices.find((price) => price.feedId === BTC);
    expect(btc?.priceWad).toBe(77_191_148_615_190_000_000_000n);
    expect(btc?.publishTime).toBe(1_789_247_057);
  });

  /// Hermes returns ids without the 0x prefix and the rest of the system uses bytes32 with one. A
  /// mismatch here means every feed silently fails to match what the oracle holds.
  it("returns feed ids in the 0x form everything else uses", async () => {
    const prices = await fetchLatest(
      "key",
      [BTC],
      stubFetch(() => new Response(FIXTURE, {status: 200})),
    );
    for (const price of prices) {
      expect(price.feedId.startsWith("0x")).toBe(true);
      expect(price.feedId).toBe(price.feedId.toLowerCase());
    }
  });

  it("sends the ids without a prefix, which is what Hermes expects", async () => {
    let seen = "";
    const recording = (async (url: string) => {
      seen = url;
      return new Response(FIXTURE, {status: 200});
    }) as unknown as typeof fetch;

    await fetchLatest("key", [BTC], recording);
    expect(seen).toContain("ids[]=e62df6c8");
    expect(seen).not.toContain("ids[]=0x");
  });

  it("asks for nothing when given no feeds", async () => {
    let called = false;
    const prices = await fetchLatest(
      "key",
      [],
      stubFetch(() => {
        called = true;
        return new Response(FIXTURE);
      }),
    );
    expect(prices).toEqual([]);
    expect(called).toBe(false);
  });

  /// The message matters. A 403 is not a rate limit and not a transient failure: the key is not
  /// entitled to something in the batch, and because one unentitled feed fails the whole request,
  /// retrying the same batch will fail forever.
  it("explains a 403 as an entitlement problem, not a retryable one", async () => {
    await expect(
      fetchLatest(
        "key",
        [BTC],
        stubFetch(() => new Response("", {status: 403})),
      ),
    ).rejects.toThrow(/not entitled.*removed, not retried/s);
  });

  it("reports other statuses with the status", async () => {
    const failure = fetchLatest(
      "key",
      [BTC],
      stubFetch(() => new Response("", {status: 502})),
    );
    await expect(failure).rejects.toThrow(/HTTP 502/);
    await expect(failure).rejects.toMatchObject({name: "HermesError", status: 502});
  });

  it("rejects a body that is not JSON", async () => {
    await expect(
      fetchLatest(
        "key",
        [BTC],
        stubFetch(() => new Response("<html>", {status: 200})),
      ),
    ).rejects.toThrow(/not JSON/);
  });

  it("rejects when Hermes is unreachable", async () => {
    await expect(
      fetchLatest(
        "key",
        [BTC],
        stubFetch(() => {
          throw new TypeError("fetch failed");
        }),
      ),
    ).rejects.toThrow(/unreachable/);
  });

  /// A hung Hermes would otherwise hold a cycle open past the next one, and two overlapping cycles
  /// share a nonce.
  it("gives up when Hermes does not answer", async () => {
    const hanging = ((_url: string, init?: {signal?: AbortSignal}) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () =>
          reject(Object.assign(new Error("aborted"), {name: "AbortError"})),
        );
      })) as unknown as typeof fetch;

    await expect(fetchLatest("key", [BTC], hanging, 10)).rejects.toThrow(/within 10ms/);
    expect(new HermesError("x", null).status).toBeNull();
  });

  it("treats an answer with no parsed prices as empty rather than failing", async () => {
    const prices = await fetchLatest(
      "key",
      [BTC],
      stubFetch(() => Response.json({})),
    );
    expect(prices).toEqual([]);
  });
});
