#!/usr/bin/env node
import {formatUnits} from "viem";
import {VAULT_ABI} from "./abi.js";
import {createClients} from "./chain.js";
import {loadConfig, loadDotEnv, runsOnce} from "./config.js";
import {ClosedSet, consoleLogger, sweep} from "./keeper.js";

/// Liquidates underwater SyntheticVault positions.
///
///   npm run keeper -- --once            one sweep, reports only
///   npm run keeper -- --once --send     one sweep, sends transactions
///   npm run keeper -- --send            runs until stopped
loadDotEnv();

const config = loadConfig(process.env, process.argv.slice(2));
const clients = createClients(config);
const log = consoleLogger;

const [threshold, reward, balance] = await Promise.all([
  clients.publicClient.readContract({
    address: config.vault,
    abi: VAULT_ABI,
    functionName: "liquidationThresholdBps",
  }),
  clients.publicClient.readContract({
    address: config.vault,
    abi: VAULT_ABI,
    functionName: "liquidationRewardBps",
  }),
  clients.publicClient.getBalance({address: clients.account.address}),
]);

log.info(`vault     ${config.vault} on chain ${config.chainId}`);
log.info(`keeper    ${clients.account.address}, ${formatUnits(balance, 18)} USDC for gas`);
log.info(`threshold ${threshold / 100}% of collateral lost; reward ${reward / 100}% of collateral`);
log.info(config.dryRun ? "mode      DRY RUN — pass --send to act" : "mode      SENDING");
if (config.onlyToken !== null) {
  log.info(`scope     position ${config.onlyToken} only`);
}

if (balance === 0n && !config.dryRun) {
  // Every simulation would still pass and every send would fail, which reads in the logs as a
  // broken keeper rather than an unfunded one.
  log.error(
    "the keeper has no balance and cannot pay for gas. Fund it before running with --send.",
  );
  process.exit(1);
}

const closed = new ClosedSet();
let stopping = false;

process.on("SIGINT", () => {
  // Mid-sweep, a liquidation is already in flight and killing the process would lose the receipt
  // rather than the transaction. Finishing the sweep is the only way to report what happened.
  log.info("stopping after this sweep");
  stopping = true;
});
process.on("SIGTERM", () => {
  stopping = true;
});

const once = runsOnce(process.argv.slice(2));

do {
  const started = Date.now();
  try {
    const result = await sweep(clients, config, closed, log);
    log.info(
      `sweep: ${result.checked} open, ${result.liquidatable.length} liquidatable, ` +
        `${result.liquidated.length} liquidated, ${result.blocked.length} blocked, ` +
        `${result.unknown.length} unrecognised (${Date.now() - started}ms)`,
    );
    if (result.unknown.length > 0) {
      log.error("unrecognised reverts above need a human. The keeper is not doing its job.");
    }
  } catch (error) {
    // A sweep that throws is usually the RPC being unreachable. Keep going: the next sweep is the
    // cheapest place to find out it came back.
    log.error(`sweep failed: ${error instanceof Error ? error.message.split("\n")[0] : error}`);
  }

  if (once || stopping) break;
  await new Promise((resolve) => setTimeout(resolve, config.intervalSeconds * 1000));
} while (!stopping);
