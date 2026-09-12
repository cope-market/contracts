import {BaseError, ContractFunctionRevertedError} from "viem";
import {describe, expect, it} from "vitest";
import {classify, progressToThreshold, revertedError} from "../src/health.js";

const WAD = 10n ** 18n;

/// Builds the shape viem actually throws: a wrapping BaseError whose cause chain contains a
/// decoded ContractFunctionRevertedError. Constructing it by hand is the only way to test the
/// classifier without a chain.
function reverted(errorName: string, args: unknown[] = []): BaseError {
  const inner = new ContractFunctionRevertedError({
    abi: [],
    functionName: "liquidate",
    message: errorName,
  });
  // viem populates `data` from the ABI when it can decode; this is what that looks like.
  (inner as unknown as {data: unknown}).data = {errorName, args};
  return new BaseError("reverted", {cause: inner});
}

describe("decoding a revert", () => {
  it("finds the decoded error through viem's wrapping", () => {
    expect(revertedError(reverted("PositionHealthy", [1n, 2n, 3n]))).toEqual({
      name: "PositionHealthy",
      args: [1n, 2n, 3n],
    });
  });

  it("returns null for something that is not a contract revert", () => {
    expect(revertedError(new Error("socket hang up"))).toBeNull();
  });

  /// A revert the ABI cannot decode has no error name. That must not read as "no revert".
  it("returns null when the revert could not be decoded", () => {
    const inner = new ContractFunctionRevertedError({
      abi: [],
      functionName: "liquidate",
      message: "unknown",
    });
    expect(revertedError(new BaseError("reverted", {cause: inner}))).toBeNull();
  });
});

describe("classifying a simulation failure", () => {
  /// The normal outcome, and the one the keeper sees on nearly every position on nearly every
  /// sweep.
  it("reads PositionHealthy as healthy, with the numbers", () => {
    const health = classify(7n, reverted("PositionHealthy", [7n, 5n * WAD, 9n * WAD]));
    expect(health).toEqual({
      kind: "healthy",
      tokenId: 7n,
      lossWad: 5n * WAD,
      thresholdWad: 9n * WAD,
    });
  });

  it("reads a missing position as gone", () => {
    expect(classify(7n, reverted("UnknownPosition", [7n])).kind).toBe("gone");
    expect(classify(7n, reverted("ERC721NonexistentToken", [7n])).kind).toBe("gone");
  });

  /// The error is `StalePrice`. A hand-written ABI called it `PriceStale`, which viem could not
  /// decode, so the revert arrived as opaque hex and would have been classified as unknown forever.
  it("reads a stale price as blocked and names it", () => {
    const health = classify(7n, reverted("StalePrice", ["0xfeed", 1n, 600n]));
    expect(health.kind).toBe("blocked");
    if (health.kind === "blocked") {
      expect(health.errorName).toBe("StalePrice");
      expect(health.detail).toContain("trading is blocked too");
    }
  });

  it("reads the other oracle conditions as blocked", () => {
    for (const name of ["PriceUnavailable", "InvalidPrice", "ConfidenceTooWide", "AssetDisabled"]) {
      expect(classify(7n, reverted(name, ["0xfeed"])).kind, name).toBe("blocked");
    }
  });

  /// The important one. Treating an unrecognised revert as "not liquidatable" is how a keeper stops
  /// working while continuing to report that everything is fine.
  it("never treats an unrecognised revert as healthy", () => {
    const health = classify(7n, reverted("SomethingNobodyPredicted", [1n]));
    expect(health.kind).toBe("unknown");
    if (health.kind === "unknown") {
      expect(health.detail).toContain("SomethingNobodyPredicted");
    }
  });

  it("reports a non-revert failure as unknown rather than swallowing it", () => {
    const health = classify(7n, new Error("connect ECONNREFUSED"));
    expect(health.kind).toBe("unknown");
    if (health.kind === "unknown") {
      expect(health.detail).toContain("ECONNREFUSED");
    }
  });
});

describe("progress to the threshold", () => {
  it("says how far underwater a position is", () => {
    expect(progressToThreshold(45n * WAD, 90n * WAD)).toBe(50);
    expect(progressToThreshold(89n * WAD, 90n * WAD)).toBeCloseTo(98.88, 1);
  });

  it("is zero for a position at no loss", () => {
    expect(progressToThreshold(0n, 90n * WAD)).toBe(0);
  });

  /// A threshold of zero would divide by nothing. It is reachable: the owner can set the threshold
  /// bps to zero, which is what the verification step does deliberately.
  it("is unknown rather than infinite when the threshold is zero", () => {
    expect(progressToThreshold(5n * WAD, 0n)).toBeNull();
  });
});
