import { createPublicClient, http } from "viem";
import { robinhoodChain } from "@/lib/web3/chain";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured, env } from "@/lib/web3/env";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";

export type TickerLookupResult =
  | { status: "ok"; ticker: string }
  | { status: "not_configured" }
  | { status: "rpc_error" }
  | { status: "not_found" };

/**
 * The single, authoritative "does this tokenId exist" check, shared by
 * GET /api/ticker-metadata/[tokenId] and GET /api/ticker-image/[tokenId] so
 * the two routes can never disagree about it. tickerOf() returning "" is
 * Solidity's zero-value for a string mapping entry that was never written -
 * the real signal that a tokenId was never actually launched, not a guess.
 */
export async function lookupTickerForTokenId(tokenId: number): Promise<TickerLookupResult> {
  if (!isProtocolConfigured || !addresses.tickerRegistry) {
    return { status: "not_configured" };
  }

  const client = createPublicClient({ chain: robinhoodChain, transport: http(env.rpcUrl) });

  let ticker: string;
  try {
    ticker = await client.readContract({
      address: addresses.tickerRegistry,
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
