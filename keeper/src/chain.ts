import {createPublicClient, createWalletClient, defineChain, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import type {Account, PublicClient, WalletClient} from "viem";
import type {KeeperConfig} from "./config.js";

/// Arc's native currency is USDC with 18 decimals, while its ERC-20 view uses 6. Nothing here adds
/// the two, but the definition has to be right or viem formats gas costs as though they were
/// ether.
export function arcChain(config: KeeperConfig) {
  return defineChain({
    id: config.chainId,
    name: "Arc",
    nativeCurrency: {name: "USD Coin", symbol: "USDC", decimals: 18},
    rpcUrls: {default: {http: [config.rpcUrl]}},
  });
}

export interface Clients {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Account;
}

export function createClients(config: KeeperConfig): Clients {
  const chain = arcChain(config);
  const account = privateKeyToAccount(config.privateKey);

  return {
    publicClient: createPublicClient({chain, transport: http(config.rpcUrl)}) as PublicClient,
    walletClient: createWalletClient({account, chain, transport: http(config.rpcUrl)}),
    account,
  };
}

/// Arc refuses a transaction priced below 20 gwei outright — it is not slow, it is rejected — so
/// whatever the node suggests is raised to the floor rather than trusted.
export function withGasFloor(
  suggested: {maxFeePerGas?: bigint | undefined; maxPriorityFeePerGas?: bigint | undefined},
  floorWei: bigint,
): {maxFeePerGas: bigint; maxPriorityFeePerGas: bigint} {
  const maxFeePerGas =
    suggested.maxFeePerGas !== undefined && suggested.maxFeePerGas > floorWei
      ? suggested.maxFeePerGas
      : floorWei;

  // The priority fee can never exceed the max fee, and a node that suggests one above our raised
  // floor would produce a transaction the chain rejects for a different reason.
  const suggestedPriority = suggested.maxPriorityFeePerGas ?? 0n;
  const maxPriorityFeePerGas = suggestedPriority > maxFeePerGas ? maxFeePerGas : suggestedPriority;

  return {maxFeePerGas, maxPriorityFeePerGas};
}
