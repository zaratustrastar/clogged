import { defineChain } from "@reown/appkit/networks";
import { env } from "./env";

// TODO (deployment): every value here comes from env vars set at deploy time
// (see lib/web3/env.ts) - nothing is a real Robinhood Chain value invented by
// this codebase. Until NEXT_PUBLIC_ROBINHOOD_CHAIN_ID / _RPC_URL are set,
// this resolves to a harmless placeholder chain id (0) that no real wallet
// will ever be connected to; `isProtocolConfigured` (env.ts) is what pages
// should actually check before trusting any read from this chain.
export const robinhoodChain = defineChain({
  id: env.chainId ? Number(env.chainId) : 0,
  caipNetworkId: `eip155:${env.chainId ?? 0}`,
  chainNamespace: "eip155",
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [env.rpcUrl ?? ""] },
  },
  blockExplorers: env.explorerUrl
    ? { default: { name: "Explorer", url: env.explorerUrl } }
    : undefined,
});
