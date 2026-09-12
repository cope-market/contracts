import {existsSync} from "node:fs";
import {getAddress, isHex} from "viem";
import type {Address, Hex} from "viem";

/// Configuration, read once at startup so a missing value fails before the first transaction rather
/// than in the middle of one.

export interface KeeperConfig {
  rpcUrl: string;
  chainId: number;
  vault: Address;
  privateKey: Hex;
  /// Seconds between sweeps. One sweep and exit when running with `--once`.
  intervalSeconds: number;
  /// Simulate and report without sending. The default, so the first thing anyone runs cannot
  /// spend money.
  dryRun: boolean;
  /// `maxFeePerGas` floor, in wei. Arc rejects anything under 20 gwei, and a transaction priced
  /// below the floor is not slow — it is refused.
  minMaxFeePerGasWei: bigint;
}

const ARC_TESTNET_CHAIN_ID = 5042002;
const ARC_GAS_FLOOR_WEI = 20_000_000_000n;

export function loadDotEnv(path = ".env"): void {
  // The contracts repo keeps PRIVATE_KEY, the RPC and the deployed addresses in its own .env, and
  // the keeper reuses that rather than asking anyone to copy a key to a second place.
  for (const candidate of [path, `../${path}`]) {
    if (existsSync(candidate)) {
      process.loadEnvFile(candidate);
    }
  }
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) {
    throw new Error(`${name} is not set. The keeper reads contracts/.env; see keeper/README.md.`);
  }
  return value;
}

export function loadConfig(
  env: NodeJS.ProcessEnv = process.env,
  argv: string[] = [],
): KeeperConfig {
  const privateKey = required(env, "PRIVATE_KEY");
  if (!isHex(privateKey) || privateKey.length !== 66) {
    throw new Error("PRIVATE_KEY must be a 0x-prefixed 32-byte hex string.");
  }

  const interval = Number(env["KEEPER_INTERVAL_SECONDS"] ?? 60);
  if (!Number.isFinite(interval) || interval < 1) {
    throw new Error("KEEPER_INTERVAL_SECONDS must be a positive number of seconds.");
  }

  return {
    rpcUrl: env["RPC_URL"] ?? env["ARC_RPC_URL"] ?? "https://rpc.testnet.arc.io",
    chainId: Number(env["ARC_CHAIN_ID"] ?? ARC_TESTNET_CHAIN_ID),
    vault: getAddress(required(env, "SYNTHETIC_VAULT_ADDRESS")),
    privateKey,
    intervalSeconds: interval,
    // Sending is opt-in. A keeper that spent money the first time someone ran it to see what it
    // did would be a bad way to learn what it does.
    dryRun: !argv.includes("--send"),
    minMaxFeePerGasWei: BigInt(env["ARC_MIN_MAX_FEE_WEI"] ?? ARC_GAS_FLOOR_WEI),
  };
}

export function runsOnce(argv: string[]): boolean {
  return argv.includes("--once");
}
