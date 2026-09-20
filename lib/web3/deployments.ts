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
 * The canary deployment, frozen to its own real, already-deployed chain +
 * TickerRegistry - a fixed constant, deliberately NEVER derived from
 * env.chainId/env.tickerRegistry (which is what getActiveDeployment() reads
 * and which changes the moment the app's active manifest is switched to
 * point at V2 or any future deployment).
 *
 * This was previously resolved dynamically via getActiveDeployment() - safe
 * only for as long as the canary WAS the active deployment, and silently
 * wrong the instant it stopped being one: the canary TickerNFT's own
 * immutable base URI (https://clog.run/api/ticker-metadata/canary-v1/) is
 * permanent, on-chain, and can never be changed, so "canary-v1" must
 * permanently resolve to the canary's own real chain/registry regardless of
 * whatever the app is actively configured to point at later. Values below
 * are the canary's actual, already-deployed, already-verified identity -
 * read directly from deployments/robinhood-mainnet.json at the time V2 work
 * began (chainId 4663, tickerRegistry
 * 0xE631ed6E9E6FEAce145a0ab01cbd2BB947a4a2B2 - the same address documented
 * throughout this repo's own deployment records), not guessed or derived.
 */
export const FROZEN_CANARY_V1_DEPLOYMENT: DeploymentIdentity = {
  chainId: 4663,
  tickerRegistryAddress: "0xE631ed6E9E6FEAce145a0ab01cbd2BB947a4a2B2",
};

/**
 * The V2 deployment, frozen to the real production registry deployed on
 * Robinhood Chain. Like canary-v1, this must never follow the active
 * manifest dynamically: the V2 TickerNFT uses the immutable
 * /api/ticker-metadata/v2/ base URI, so deploymentId "v2" must always
 * resolve to this exact chain + registry even after a future deployment
 * becomes active.
 */
export const FROZEN_V2_DEPLOYMENT: DeploymentIdentity = {
  chainId: 4663,
  tickerRegistryAddress: "0xb2026829151d1f4E1B35a4A7F9DA6afCFa3351C3",
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
 *
 * "canary-v1" resolves to FROZEN_CANARY_V1_DEPLOYMENT above - a fixed
 * constant, not the active deployment - so it keeps resolving to the real
 * canary contracts forever, including after "v2" becomes the app's active
 * deployment (see FROZEN_CANARY_V1_DEPLOYMENT's own docs for why this
 * matters and what used to be wrong here).
 *
 * "v2" now resolves to FROZEN_V2_DEPLOYMENT above. V2 has been deployed,
 * verified and assigned its permanent deployment identity, so this resolver
 * must never again depend on getActiveDeployment(). A future V3 or other
 * deployment may replace V2 as the active manifest without changing what
 * /api/ticker-metadata/v2/... means.
 */
const KNOWN_DEPLOYMENTS: Record<string, () => DeploymentIdentity | null> = {
  "canary-v1": () => FROZEN_CANARY_V1_DEPLOYMENT,
  v2: () => FROZEN_V2_DEPLOYMENT,
};

export function getKnownDeploymentById(deploymentId: string): DeploymentIdentity | null {
  const resolver = KNOWN_DEPLOYMENTS[deploymentId];
  return resolver ? resolver() : null;
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
