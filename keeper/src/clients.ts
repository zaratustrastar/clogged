import { createPublicClient, createWalletClient, http, defineChain, type Chain, type PublicClient, type WalletClient, type HttpTransport } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import type { KeeperConfig } from "./config.js";

/** Robinhood Chain Mainnet - not in viem's built-in chain list, defined
 * here directly from the same values the frontend's own lib/web3/chain.ts
 * uses (chain id 4663, native ETH). */
export function robinhoodChain(config: KeeperConfig): Chain {
  return defineChain({
    id: config.chainId,
    name: "Robinhood Chain",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [config.robinhoodRpcUrl] } },
  });
}

export interface Clients {
  robinhoodPublic: PublicClient<HttpTransport, Chain>;
  robinhoodWallet: WalletClient<HttpTransport, Chain, PrivateKeyAccount>;
  arbitrumPublic: PublicClient<HttpTransport, Chain>;
  arbitrumWallet: WalletClient<HttpTransport, Chain, PrivateKeyAccount>;
  keeperAddress: `0x${string}`;
}

export function createClients(config: KeeperConfig): Clients {
  // A single dedicated keeper EOA, derived from KEEPER_PRIVATE_KEY, used as
  // the signer on BOTH chains - never the deployer, Safe, or governance
  // wallet (see config.ts's own docs and README.md's security assumptions
  // section for why this is safe: every action this account ever signs is
  // permissionless by contract design, so it needs no elevated permission
  // on either chain).
  const account = privateKeyToAccount(config.keeperPrivateKey);

  const rhChain = robinhoodChain(config);
  const robinhoodPublic = createPublicClient({ chain: rhChain, transport: http(config.robinhoodRpcUrl) });
  const robinhoodWallet = createWalletClient({ account, chain: rhChain, transport: http(config.robinhoodRpcUrl) });

  const arbitrumPublic = createPublicClient({ chain: arbitrum, transport: http(config.arbitrumRpcUrl) });
  const arbitrumWallet = createWalletClient({ account, chain: arbitrum, transport: http(config.arbitrumRpcUrl) });

  return { robinhoodPublic, robinhoodWallet, arbitrumPublic, arbitrumWallet, keeperAddress: account.address };
}
