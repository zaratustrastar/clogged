import type { Address } from "viem";
import { env } from "@/lib/web3/env";

/**
 * The identity of one specific protocol deployment: which chain, and which
 * TickerRegistry on that chain. A bare tokenId is only meaningful relative
 * to one of these - two different deployments both start tokenId numbering
 * at 1, and the two must never be confused with each other (see migration
 * 002 and the ticker-metadata deployment-scoping work).
 */
export interface DeploymentIdentity {
  chainId: number;
  tickerRegistryAddress: Address;
}

/**
 * The legacy HOOD deployment - the one the app has always pointed at before
 * the canary work. Deliberately a FIXED CONSTANT, never derived from the
 * dynamic NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS env var: HOOD's own
 * TickerNFT already has this exact address baked into already-minted NFT
 * metadata's immutable base URI
 * (https://clog.run/api/ticker-metadata/<tokenId>), and once clog.run's own
 * active env config is switched to point at the canary (or any future
 * deployment), that dynamic env var will no longer refer to HOOD at all -
 * the legacy route must keep resolving HOOD regardless of what the active
 * deployment currently is.
 */
export const LEGACY_HOOD_DEPLOYMENT: DeploymentIdentity = {
  chainId: 4663,
  tickerRegistryAddress: "0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33",
};

/**
 * Fixed, server-side mapping from a short, URL-safe deploymentId to its
 * real deployment identity. This is the ONLY way a deploymentId in a URL
 * path (e.g. /api/ticker-metadata/canary-v1/1) ever resolves to a real
 * chain/registry pair - a client can never supply an arbitrary registry
 * address directly, only pick from this fixed list by its short id, which
 * closes off any possibility of a request being served against a
 * caller-chosen contract. Add a new entry here for each future deployment;
 * never remove or repurpose an existing entry once it has been used in a
 * live base URI, for the same reason LEGACY_HOOD_DEPLOYMENT itself is
 * never repurposed.
 */
const KNOWN_DEPLOYMENTS: Record<string, DeploymentIdentity> = {
  "canary-v1": {
    chainId: 4663,
    // Placeholder until the fresh canary TickerRegistry is actually
    // deployed - see the deployment runbook. Update this one line, and
    // only this line, once the real address is known; nothing else in
    // this file or its callers needs to change.
    tickerRegistryAddress: "0x0000000000000000000000000000000000000000",
  },
};

export function getKnownDeploymentById(deploymentId: string): DeploymentIdentity | null {
  return KNOWN_DEPLOYMENTS[deploymentId] ?? null;
}

/**
 * The deployment the app's own dynamic env config currently points at -
 * what the main trading/discovery UI (TradeWidget, token discovery, round
 * history) should use, since those follow whatever clog.run is presently
 * configured to serve. Distinct from LEGACY_HOOD_DEPLOYMENT and from any
 * getKnownDeploymentById lookup, both of which are fixed regardless of the
 * active config. Returns null if the app isn't fully configured yet.
 */
export function getActiveDeployment(): DeploymentIdentity | null {
  if (!env.chainId || !env.tickerRegistry) return null;
  const chainId = Number(env.chainId);
  if (!Number.isInteger(chainId)) return null;
  return { chainId, tickerRegistryAddress: env.tickerRegistry as Address };
}
