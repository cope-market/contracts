import {BaseError, ContractFunctionRevertedError} from "viem";

/// What a simulation of `liquidate` told us.
///
/// The keeper never recomputes the health check. `eth_call` runs the contract's real logic against
/// real state, so it succeeds exactly when a transaction would, and when it fails it fails with the
/// contract's own error. There is no second implementation to keep in step with the first.
export type Health =
  | {kind: "liquidatable"; tokenId: bigint}
  /// The normal outcome. Not underwater enough yet.
  | {kind: "healthy"; tokenId: bigint; lossWad: bigint; thresholdWad: bigint}
  /// Closed or liquidated between discovery and simulation. Someone else got there, or the owner
  /// closed it themselves.
  | {kind: "gone"; tokenId: bigint}
  /// Something outside the keeper's control. Retrying now will not help and the operator needs to
  /// know: a stale price means trading is broken too, not just liquidation.
  | {kind: "blocked"; tokenId: bigint; errorName: string; detail: string}
  /// A revert nobody predicted. Loud on purpose — treating this as "not liquidatable" is how a
  /// keeper silently stops working.
  | {kind: "unknown"; tokenId: bigint; detail: string};

/// Errors that mean the position is no longer there to liquidate.
const GONE = new Set(["UnknownPosition", "ERC721NonexistentToken"]);

/// Errors that are real conditions rather than surprises, but that the keeper cannot act on.
const BLOCKED: Record<string, string> = {
  StalePrice: "the oracle has not been pushed recently enough; trading is blocked too",
  PriceUnavailable: "the oracle has no price for this feed",
  InvalidPrice: "the oracle reported a price the vault rejects",
  ConfidenceTooWide: "the oracle's confidence interval is wider than the asset allows",
  AssetDisabled: "the asset has been disabled",
};

/// Pulls the decoded custom error out of whatever viem threw.
///
/// viem wraps a revert several layers deep, and `walk` is the documented way through. A decoded
/// name only appears when the ABI declares that error, which is why the ABI is generated from the
/// artifact rather than hand-written.
export function revertedError(error: unknown): {name: string; args: readonly unknown[]} | null {
  if (!(error instanceof BaseError)) return null;

  const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError)) return null;

  const name = reverted.data?.errorName;
  if (name === undefined) return null;

  return {name, args: reverted.data?.args ?? []};
}

export function classify(tokenId: bigint, error: unknown): Health {
  const decoded = revertedError(error);

  if (decoded === null) {
    return {
      kind: "unknown",
      tokenId,
      detail: error instanceof Error ? error.message : String(error),
    };
  }

  if (decoded.name === "PositionHealthy") {
    const [, lossWad, thresholdWad] = decoded.args as [bigint, bigint, bigint];
    return {kind: "healthy", tokenId, lossWad, thresholdWad};
  }

  if (GONE.has(decoded.name)) return {kind: "gone", tokenId};

  const blocked = BLOCKED[decoded.name];
  if (blocked !== undefined) {
    return {kind: "blocked", tokenId, errorName: decoded.name, detail: blocked};
  }

  return {
    kind: "unknown",
    tokenId,
    detail: `${decoded.name}(${decoded.args.map(String).join(", ")})`,
  };
}

/// How far underwater a position is, as a share of the threshold. Purely for the log line: it turns
/// "not liquidatable" into "83% of the way there", which is the difference between a keeper you can
/// watch and one you can only trust.
export function progressToThreshold(lossWad: bigint, thresholdWad: bigint): number | null {
  if (thresholdWad <= 0n) return null;
  return Number((lossWad * 10_000n) / thresholdWad) / 100;
}
