import {formatUnits} from "viem";
import type {Address, PublicClient, WalletClient} from "viem";
import {VAULT_ABI} from "./abi.js";
import {withGasFloor} from "./chain.js";
import type {Clients} from "./chain.js";
import type {KeeperConfig} from "./config.js";
import {classify, progressToThreshold} from "./health.js";
import type {Health} from "./health.js";

export interface Logger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

export const consoleLogger: Logger = {
  info: (message) => console.log(`[keeper] ${message}`),
  warn: (message) => console.warn(`[keeper] WARN  ${message}`),
  error: (message) => console.error(`[keeper] ERROR ${message}`),
};

/// Token ids known to be gone, so a burned position is not re-checked on every sweep forever.
///
/// Ids are never reused — `nextTokenId` only increments — so a token that is gone stays gone and
/// this can be remembered without a staleness problem.
export class ClosedSet {
  private readonly closed = new Set<string>();

  has(tokenId: bigint): boolean {
    return this.closed.has(tokenId.toString());
  }

  add(tokenId: bigint): void {
    this.closed.add(tokenId.toString());
  }

  get size(): number {
    return this.closed.size;
  }
}

/// Reads the open position set from the chain.
///
/// Not from the subgraph. An index is behind by design, and for a keeper that means positions it
/// cannot see. `nextTokenId` is public and `ownerOf` reverts for a burned token, so the chain
/// answers this on its own.
export async function discoverOpen(
  publicClient: PublicClient,
  vault: Address,
  closed: ClosedSet,
  onlyToken: bigint | null = null,
): Promise<bigint[]> {
  const next = await publicClient.readContract({
    address: vault,
    abi: VAULT_ABI,
    functionName: "nextTokenId",
  });

  const open: bigint[] = [];
  for (let tokenId = 1n; tokenId < next; tokenId++) {
    if (closed.has(tokenId)) continue;
    if (onlyToken !== null && tokenId !== onlyToken) continue;
    try {
      await publicClient.readContract({
        address: vault,
        abi: VAULT_ABI,
        functionName: "ownerOf",
        args: [tokenId],
      });
      open.push(tokenId);
    } catch {
      // `ownerOf` reverts for a burned token, which is how a closed position looks from here.
      closed.add(tokenId);
    }
  }

  return open;
}

export async function checkHealth(
  clients: Clients,
  vault: Address,
  tokenId: bigint,
): Promise<Health> {
  try {
    await clients.publicClient.simulateContract({
      address: vault,
      abi: VAULT_ABI,
      functionName: "liquidate",
      // Empty update data and zero value: the push oracle has nothing to post and rejects value
      // outright rather than stranding it.
      args: [tokenId, []],
      value: 0n,
      account: clients.account,
    });
    return {kind: "liquidatable", tokenId};
  } catch (error) {
    return classify(tokenId, error);
  }
}

export interface Liquidation {
  tokenId: bigint;
  hash: `0x${string}`;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  succeeded: boolean;
}

export async function liquidate(
  clients: Clients,
  config: KeeperConfig,
  tokenId: bigint,
): Promise<Liquidation> {
  // Simulated again immediately before sending. Between the sweep's check and here another
  // liquidator may have taken it, and finding that out for the cost of a call beats finding it out
  // for the cost of a reverted transaction.
  const {request} = await clients.publicClient.simulateContract({
    address: config.vault,
    abi: VAULT_ABI,
    functionName: "liquidate",
    args: [tokenId, []],
    value: 0n,
    account: clients.account,
  });

  const fees = await clients.publicClient.estimateFeesPerGas();
  const priced = withGasFloor(fees, config.minMaxFeePerGasWei);

  // The call is rebuilt rather than spread from `request`. That object carries a legacy `gasPrice`
  // slot which cannot coexist with the EIP-1559 fields, and the only part worth keeping is the gas
  // estimate the simulation produced.
  const hash = await clients.walletClient.writeContract({
    address: config.vault,
    abi: VAULT_ABI,
    functionName: "liquidate",
    args: [tokenId, []],
    value: 0n,
    ...(request.gas === undefined ? {} : {gas: request.gas}),
    ...priced,
    account: clients.account,
    chain: clients.walletClient.chain ?? null,
  });

  const receipt = await clients.publicClient.waitForTransactionReceipt({hash});

  return {
    tokenId,
    hash,
    gasUsed: receipt.gasUsed,
    effectiveGasPrice: receipt.effectiveGasPrice,
    succeeded: receipt.status === "success",
  };
}

export interface SweepResult {
  checked: number;
  liquidatable: bigint[];
  liquidated: Liquidation[];
  blocked: Health[];
  unknown: Health[];
}

/// One pass over every open position.
///
/// Liquidations are sent one at a time. Several liquidatable positions in a single sweep would
/// otherwise be a nonce race against itself: parallel is faster and occasionally drops
/// transactions, sequential is slower and correct.
export async function sweep(
  clients: Clients,
  config: KeeperConfig,
  closed: ClosedSet,
  log: Logger,
): Promise<SweepResult> {
  const open = await discoverOpen(clients.publicClient, config.vault, closed, config.onlyToken);
  const result: SweepResult = {
    checked: open.length,
    liquidatable: [],
    liquidated: [],
    blocked: [],
    unknown: [],
  };

  for (const tokenId of open) {
    const health = await checkHealth(clients, config.vault, tokenId);

    switch (health.kind) {
      case "healthy": {
        const progress = progressToThreshold(health.lossWad, health.thresholdWad);
        log.info(
          `position ${tokenId}: healthy` +
            (progress === null ? "" : ` (${progress.toFixed(1)}% of the way to liquidation)`),
        );
        break;
      }

      case "gone":
        // It closed between discovery and simulation. Ordinary, and the reason the two steps are
        // not assumed to see the same world.
        closed.add(tokenId);
        log.info(`position ${tokenId}: closed before it could be checked`);
        break;

      case "blocked":
        result.blocked.push(health);
        log.warn(`position ${tokenId}: cannot act — ${health.detail} (${health.errorName})`);
        break;

      case "unknown":
        // Never treated as "not liquidatable". A keeper that swallows an unrecognised revert stops
        // working and goes on reporting that everything is fine.
        result.unknown.push(health);
        log.error(`position ${tokenId}: unrecognised revert — ${health.detail}`);
        break;

      case "liquidatable": {
        result.liquidatable.push(tokenId);
        if (config.dryRun) {
          log.info(`position ${tokenId}: LIQUIDATABLE (dry run, nothing sent)`);
          break;
        }

        try {
          const done = await liquidate(clients, config, tokenId);
          result.liquidated.push(done);
          closed.add(tokenId);
          const cost = done.gasUsed * done.effectiveGasPrice;
          log.info(
            `position ${tokenId}: liquidated in ${done.hash}, ` +
              `gas ${done.gasUsed} at ${done.effectiveGasPrice} wei ` +
              `(${formatUnits(cost, 18)} USDC)`,
          );
        } catch (error) {
          // Losing the race to another liquidator is a success for the protocol and a non-event
          // for us, so it is reported as such rather than as a failure.
          const after = classify(tokenId, error);
          if (after.kind === "gone" || after.kind === "healthy") {
            closed.add(tokenId);
            log.info(`position ${tokenId}: someone else liquidated it first`);
          } else {
            log.error(
              `position ${tokenId}: liquidation failed — ` +
                `${error instanceof Error ? error.message.split("\n")[0] : String(error)}`,
            );
          }
        }
        break;
      }
    }
  }

  return result;
}
