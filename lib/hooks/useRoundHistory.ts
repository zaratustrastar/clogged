"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { addresses } from "@/lib/web3/addresses";
import { deploymentBlockBigInt, isProtocolConfigured } from "@/lib/web3/env";
import { roundManagerAbi } from "@/lib/web3/abis/roundManager";
import { scanBlockRangeInChunks, retryTransient } from "@/lib/onchain/blockRangeChunker";

export interface SettledRound {
  roundId: number;
  winnerTokenId: number;
}

/** Blocks per getContractEvents call. The Robinhood public RPC has
 * demonstrated real rate limiting (429 Too Many Requests) on an unbounded
 * single call spanning the entire deploymentBlock -> latest range once
 * protocol history is long enough - see blockRangeChunker.ts and, for the
 * same problem observed independently on the keeper side,
 * keeper/src/blockRangeChunker.ts's own docs. Conservative default well
 * under common provider caps. */
const LOG_CHUNK_SIZE_BLOCKS = 2000n;

/** Every round that has ever settled with a winner, from RoundManager's
 * `RoundSettled` event. Shared by useRecentDraws (dashboard/landing "recent
 * draws" list) and useClaimableRewards (which needs to know which rounds to
 * call RewardVault.previewClaim against) so the log scan only happens once.
 *
 * Scans in bounded, contiguous chunks (never one unbounded call for the
 * full history) and retries each chunk's request on a transient failure
 * (429, a dropped connection, a gateway timeout) with exponential
 * backoff - a real, non-transient error (e.g. a malformed request) still
 * surfaces immediately as this query's own error, rather than being
 * silently swallowed or retried forever. See useClaimableRewards and the
 * Dashboard's own handling of `isError`/`error` for how that failure is
 * actually surfaced to the person, rather than looking exactly like "you
 * have no winnings".
 */
export function useRoundHistory() {
  const publicClient = usePublicClient();

  return useQuery({
    queryKey: ["clog-round-history", addresses.roundManager],
    enabled: isProtocolConfigured && Boolean(publicClient),
    staleTime: 30_000,
    refetchInterval: 30_000,
    // retryTransient (above) already retries every transient failure per
    // chunk with backoff - a non-transient failure that still reaches here
    // should surface to the Dashboard's own error/Retry UI immediately,
    // not be silently retried again by react-query's own default retry
    // behavior first.
    retry: false,
    queryFn: async (): Promise<SettledRound[]> => {
      if (!publicClient || !addresses.roundManager) return [];
      const roundManager = addresses.roundManager;

      const latest = await retryTransient(() => publicClient.getBlockNumber());

      const logs = await scanBlockRangeInChunks(deploymentBlockBigInt, latest, LOG_CHUNK_SIZE_BLOCKS, (chunkFrom, chunkTo) =>
        retryTransient(() =>
          publicClient.getContractEvents({
            address: roundManager,
            abi: roundManagerAbi,
            eventName: "RoundSettled",
            fromBlock: chunkFrom,
            toBlock: chunkTo,
          })
        )
      );

      return logs
        .map((log) => {
          const args = log.args as { roundId?: bigint; winnerTokenId?: bigint };
          if (args.roundId === undefined || args.winnerTokenId === undefined) return null;
          return { roundId: Number(args.roundId), winnerTokenId: Number(args.winnerTokenId) };
        })
        .filter((x): x is SettledRound => x !== null)
        .sort((a, b) => b.roundId - a.roundId);
    },
  });
}
