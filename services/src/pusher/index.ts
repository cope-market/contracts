#!/usr/bin/env node
import {mkdirSync, rmSync, writeFileSync} from "node:fs";
import {dirname, join} from "node:path";
import {formatUnits} from "viem";
import type {Hex} from "viem";
import {VAULT_ABI} from "../abi.js";
import {createClients} from "../chain.js";
import {loadConfig, loadDotEnv, runsOnce} from "../config.js";
import {createLogger} from "../keeper.js";
import {acquireLock} from "./lock.js";
import {maxSafeInterval} from "./plan.js";
import {cycle} from "./service.js";

/// Feeds prices to PushOracle on Arc.
///
/// This exists only because Pyth's pull path does not work on Arc: the chain's Wormhole receiver
/// holds Wormhole's guardian set rather than Pythnet's. With a working Pyth, each trade would carry
/// its own price update and nothing would need to run. PushOracle stores whatever was last written,
/// so without this the vault has no prices and nothing can open or close.
///
///   npm run pusher -- --once
///   npm run pusher -- --interval 60
///   npm run pusher -- --interval 60 --stamp-now
loadDotEnv();

const argv = process.argv.slice(2);
const config = loadConfig(process.env, argv);
const clients = createClients(config);
const log = createLogger("pusher");

/// Only feeds this Hermes key is entitled to. AAPL, SPY and NVDA return 403, and one unentitled
/// feed fails the whole request — so they cannot simply be added. See the contracts repo SPIKE.md.
const ENTITLED: Hex[] = [
  "0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b", // FX.EUR/USD
  "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2", // Metal.XAU/USD
  "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43", // Crypto.BTC/USD
  "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1", // Equity.US.TSLA/USD
];

function option(name: string): string | null {
  const at = argv.indexOf(name);
  return at === -1 ? null : (argv[at + 1] ?? null);
}

const apiKey = process.env["PYTH_API_KEY"];
if (!apiKey) {
  throw new Error("PYTH_API_KEY is not set. The pusher cannot fetch prices without it.");
}

const oracle = process.env["ORACLE_ADDRESS"] ?? process.env["ORACLE"];
if (!oracle) {
  throw new Error("ORACLE_ADDRESS is not set.");
}

const stampNow = argv.includes("--stamp-now");
const once = runsOnce(argv) || option("--interval") === null;
const requested = Number(option("--interval") ?? 60);

/// One instance only.
const lockPath = process.env["PUSHER_LOCK"] ?? join("/tmp", "cope-pusher.lock");

if (!once) {
  mkdirSync(dirname(lockPath), {recursive: true});
  const lock = acquireLock(lockPath, process.pid);
  if (!lock.acquired) {
    log.error(
      `another pusher (pid ${lock.heldBy ?? "unknown"}) holds ${lockPath}. Two pushers share a ` +
        `key and race nonces. Stop the other one, or delete the lock if it is stale.`,
    );
    process.exit(1);
  }
  // Removed rather than emptied. An emptied lock still exists, so the next start would be refused
  // by a process that had already exited — a clean shutdown becoming an outage.
  process.on("exit", () => {
    try {
      rmSync(lockPath, {force: true});
    } catch {
      // An orphaned lock is recoverable by hand, and by the stale-pid check on the next start.
      // Throwing here would replace a tidy-up failure with a crash.
    }
  });
}

const pusherConfig = {
  vault: config.vault,
  oracle: oracle as `0x${string}`,
  apiKey,
  entitledFeeds: ENTITLED,
  stampNow,
  minMaxFeePerGasWei: config.minMaxFeePerGasWei,
};

const balance = await clients.publicClient.getBalance({address: clients.account.address});
log.info(`oracle    ${pusherConfig.oracle} on chain ${config.chainId}`);
log.info(`pusher    ${clients.account.address}, ${formatUnits(balance, 18)} USDC for gas`);

// The interval has to leave room to miss a cycle. The old script documented this and enforced
// nothing, which is how an interval equal to maxAgeSec would look fine until one cycle failed.
const enabled = (await clients.publicClient.readContract({
  address: config.vault,
  abi: VAULT_ABI,
  functionName: "enabledFeeds",
})) as readonly Hex[];

let tightest = Number.POSITIVE_INFINITY;
for (const feedId of enabled) {
  const assetConfig = (await clients.publicClient.readContract({
    address: config.vault,
    abi: VAULT_ABI,
    functionName: "assetConfig",
    args: [feedId],
  })) as readonly [boolean, number, number, number, number, bigint, bigint];
  tightest = Math.min(tightest, Number(assetConfig[1]));
}

const safest = Number.isFinite(tightest) ? maxSafeInterval(tightest) : requested;
let interval = requested;
if (!once && requested > safest) {
  log.warn(
    `--interval ${requested}s is too slow for a ${tightest}s maxAgeSec. Using ${safest}s, ` +
      `which leaves room to miss a cycle without every price going stale.`,
  );
  interval = safest;
}

if (stampNow) {
  log.warn(
    "--stamp-now: publishing under chain time rather than the real market time. Prices will " +
      "look fresh that are not. Demo only.",
  );
}
log.info(once ? "mode      one cycle" : `mode      every ${interval}s`);

let consecutiveFailures = 0;
let stopping = false;
let wake: (() => void) | null = null;

function stop(): void {
  stopping = true;
  // Waking the sleep rather than waiting it out. systemd sends SIGTERM and kills after its
  // timeout, so a service that sleeps through the signal gets killed mid-cycle instead of
  // finishing tidily.
  wake?.();
}

process.on("SIGINT", stop);
process.on("SIGTERM", stop);

/// Sleeps, but returns early when a signal arrives.
function sleep(seconds: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(finish, seconds * 1000);
    function finish(): void {
      clearTimeout(timer);
      wake = null;
      resolve();
    }
    wake = finish;
  });
}

/// A heartbeat, so the failure that matters is visible without reading logs.
///
/// The dangerous failure here is silence: the process dies, prices go stale, and the first symptom
/// is a trade reverting during a demo. A file with a timestamp in it answers "is the pusher alive
/// and are prices usable" from a shell, a cron check or a browser.
const heartbeatPath = process.env["PUSHER_HEARTBEAT"] ?? join("/tmp", "cope-pusher-status.json");

function heartbeat(status: Record<string, unknown>): void {
  try {
    writeFileSync(
      heartbeatPath,
      JSON.stringify({at: new Date().toISOString(), ...status}, null, 2),
    );
  } catch (error) {
    // Never fatal. A pusher that stopped pushing prices because it could not write a status file
    // would have turned its own health check into the outage.
    log.warn(`could not write ${heartbeatPath}: ${error instanceof Error ? error.message : error}`);
  }
}

do {
  try {
    const result = await cycle(clients, pusherConfig, log);
    consecutiveFailures = 0;
    log.info(
      `cycle: ${result.pushed} pushed, ${result.skipped} skipped, ` +
        `${result.healthy ? "all feeds usable" : "SOME FEEDS UNUSABLE"}`,
    );
    heartbeat({
      ok: true,
      healthy: result.healthy,
      pushed: result.pushed,
      skipped: result.skipped,
      unentitled: result.unentitled,
      feeds: result.freshness.map((feed) => ({
        feedId: feed.feedId,
        ageSec: Number.isFinite(feed.ageSec) ? feed.ageSec : null,
        maxAgeSec: feed.maxAgeSec,
        fresh: feed.fresh,
      })),
    });
  } catch (error) {
    consecutiveFailures += 1;
    const message = error instanceof Error ? error.message.split("\n")[0] : String(error);
    // One failure is noise: Hermes rate-limits and RPCs blink. Sustained failure is an outage, and
    // repeating the same line at the same volume forever is the same as no alerting at all.
    if (consecutiveFailures >= 3) {
      log.error(
        `cycle failed ${consecutiveFailures} times in a row — prices are going stale. ${message}`,
      );
    } else {
      log.warn(`cycle failed (${consecutiveFailures}): ${message}`);
    }
    heartbeat({ok: false, consecutiveFailures, error: message});
  }

  if (once || stopping) break;
  await sleep(interval);
} while (!stopping);

if (!once) log.info("stopped");
