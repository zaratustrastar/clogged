import { createPublicClient, http } from "viem";
import { robinhoodChain } from "@/lib/web3/chain";
import { env } from "@/lib/web3/env";
import { getActiveDeployment, type DeploymentIdentity } from "@/lib/web3/deployments";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";

export type TickerLookupResult =
  | { status: "ok"; ticker: string }
  | { status: "not_configured" }
  | { status: "rpc_error" }
  | { status: "not_found" };

/**
 * The single, authoritative "does this tokenId exist" check, shared by
 * GET /api/ticker-metadata/[...slug] and GET /api/ticker-image/[...slug] so
 * the two routes can never disagree about it. tickerOf() returning "" is
 * Solidity's zero-value for a string mapping entry that was never written -
 * the real signal that a tokenId was never actually launched, not a guess.
 *
 * DEPLOYMENT-SCOPED: takes an explicit DeploymentIdentity (chainId +
 * TickerRegistry address) rather than always reading the app's current
 * active env config, so a caller bound to a FIXED deployment (the legacy
 * HOOD route, or a specific deploymentId route) always queries that exact
 * registry regardless of what the active deployment currently is. Defaults
 * to the active deployment (getActiveDeployment()) when no explicit
 * identity is given, preserving the exact previous behavior for every
 * existing caller that doesn't need deployment-pinning.
 */
export async function lookupTickerForTokenId(
  tokenId: number,
  deployment?: DeploymentIdentity
): Promise<TickerLookupResult> {
  const target = deployment ?? getActiveDeployment();
  // The RPC endpoint/chain config is separate from which deployment's
  // registry is being queried - both HOOD and any future deployment need
  // it, and its absence is "not configured" regardless of whether an
  // explicit (always-present) deployment identity like LEGACY_HOOD_DEPLOYMENT
  // was passed in.
  if (!target || !env.chainId || !env.rpcUrl) {
    return { status: "not_configured" };
  }

  // Both HOOD and any future deployment live on the same chain (Robinhood
  // Chain) - only the TickerRegistry address differs between them, so the
  // same RPC endpoint/chain config is correct for any deployment identity.
  const client = createPublicClient({ chain: robinhoodChain, transport: http(env.rpcUrl) });

  let ticker: string;
  try {
    ticker = await client.readContract({
      address: target.tickerRegistryAddress,
      abi: tickerRegistryAbi,
      functionName: "tickerOf",
      args: [BigInt(tokenId)],
    });
  } catch {
    return { status: "rpc_error" };
  }

  if (!ticker) {
    return { status: "not_found" };
  }
  return { status: "ok", ticker };
}
