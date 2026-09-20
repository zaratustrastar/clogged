import "server-only";
import { createPublicClient, http, type Address } from "viem";
import { robinhoodChain } from "@/lib/web3/chain";
import { env } from "@/lib/web3/env";
import { tickerNFTAbi } from "@/lib/web3/abis/tickerNFT";

export type TickerNftOwnerResult = { status: "ok"; owner: Address } | { status: "not_configured" } | { status: "rpc_error" };

/**
 * The single, authoritative "who currently owns this ticker" read for
 * authorizing POST /api/token-profile writes (see
 * lib/metadata/tokenProfileAuth.ts for the signature-verification half of
 * that check). Mirrors lib/onchain/tickerLookup.ts's own
 * lookupTickerForTokenId exactly - same client construction, same
 * not_configured/rpc_error shape - since both are one-off, read-only
 * contract calls against the app's active deployment.
 *
 * Deliberately takes the TickerNFT address as an explicit parameter rather
 * than reading `addresses.tickerNFT` itself: the caller (the API route)
 * is what decides which deployment's TickerNFT this check is scoped to,
 * the same separation of concerns tickerLookup.ts's own
 * DeploymentIdentity parameter already establishes for TickerRegistry
 * reads - this function has no opinion about which deployment is active,
 * only how to read ownerOf once it's told where to look.
 *
 * A revert (nonexistent tokenId - TickerNFT was never actually minted for
 * it) surfaces as rpc_error here, the same as any other read failure -
 * callers must treat "could not determine the owner" as authorization
 * denied, never as an implicit allow.
 */
export async function readTickerNftOwner(tokenId: number, tickerNFTAddress: Address): Promise<TickerNftOwnerResult> {
  if (!env.rpcUrl) {
    return { status: "not_configured" };
  }

  const client = createPublicClient({ chain: robinhoodChain, transport: http(env.rpcUrl) });

  try {
    const owner = await client.readContract({
      address: tickerNFTAddress,
      abi: tickerNFTAbi,
      functionName: "ownerOf",
      args: [BigInt(tokenId)],
    });
    return { status: "ok", owner };
  } catch {
    return { status: "rpc_error" };
  }
}
