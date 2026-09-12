import type {Hex} from "viem";

/// Fetching prices from Pyth's Hermes API and scaling them to the vault's units.
///
/// This whole service exists because Pyth's pull path does not work on Arc: the chain's Wormhole
/// receiver holds Wormhole's guardian set rather than Pythnet's, so a perfectly valid update blob is
/// rejected. Only the parsed prices are used here — the binary VAA, which is the part Arc cannot
/// verify, is ignored.

const HERMES = "https://hermes.pyth.network/v2/updates/price/latest";

export class HermesError extends Error {
  constructor(
    message: string,
    readonly status: number | null,
  ) {
    super(message);
    this.name = "HermesError";
  }
}

export interface HermesPrice {
  feedId: Hex;
  /// 18 decimals, like everything the vault stores.
  priceWad: bigint;
  confWad: bigint;
  publishTime: number;
}

interface HermesResponse {
  parsed?: {
    id: string;
    price: {price: string; conf: string; expo: number; publish_time: number};
  }[];
}

/// Rescales a Pyth integer-and-exponent price to 18 decimals.
///
/// The real price is `value * 10^expo`, so in WAD it is `value * 10^(18 + expo)`. Every exponent
/// Pyth actually uses is between -3 and -8, which multiplies. Division happens only for an exponent
/// finer than eighteen decimals, where it truncates toward zero — a rounding the vault already
/// tolerates on a price, and one that errs narrow rather than wide on a confidence interval.
///
/// No float anywhere: a BTC price in WAD is past 2^53, so a double would lose its low digits.
export function toWad(value: bigint, expo: number): bigint {
  const shift = 18 + expo;
  if (shift >= 0) return value * 10n ** BigInt(shift);
  return value / 10n ** BigInt(-shift);
}

export async function fetchLatest(
  apiKey: string,
  feedIds: Hex[],
  fetchImpl: typeof fetch = fetch,
  timeoutMs = 30_000,
): Promise<HermesPrice[]> {
  if (feedIds.length === 0) return [];

  const query = feedIds.map((id) => `ids[]=${id.replace(/^0x/, "")}`).join("&");
  const url = `${HERMES}?${query}&parsed=true&encoding=hex`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetchImpl(url, {
      headers: {authorization: `Bearer ${apiKey}`},
      signal: controller.signal,
    });
  } catch (error) {
    const aborted = error instanceof Error && error.name === "AbortError";
    throw new HermesError(
      aborted ? `Hermes did not answer within ${timeoutMs}ms.` : `Hermes is unreachable: ${error}`,
      null,
    );
  } finally {
    clearTimeout(timer);
  }

  if (response.status === 403) {
    // One unentitled feed fails the whole request, so this is never about the batch being too
    // large — it is about the key not covering something in it.
    throw new HermesError(
      "Hermes refused the request: the API key is not entitled to one of these feeds. " +
        "The request fails as a whole, so the unentitled feed has to be removed, not retried.",
      403,
    );
  }

  if (!response.ok) {
    throw new HermesError(`Hermes answered HTTP ${response.status}.`, response.status);
  }

  let body: HermesResponse;
  try {
    body = (await response.json()) as HermesResponse;
  } catch {
    throw new HermesError("Hermes answered with something that is not JSON.", response.status);
  }

  return (body.parsed ?? []).map((entry) => ({
    feedId: `0x${entry.id.toLowerCase().replace(/^0x/, "")}` as Hex,
    priceWad: toWad(BigInt(entry.price.price), entry.price.expo),
    confWad: toWad(BigInt(entry.price.conf), entry.price.expo),
    publishTime: entry.price.publish_time,
  }));
}
