"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address, Log } from "viem";
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

/** "How far have we already scanned" + "every settled round found so far"
 * for one RoundManager address - NOT react-query's own cache (which only
 * stores the query's *return value*, not an intermediate scan cursor).
 * Without this, every refetch (the 30s refetchInterval below, or an
 * explicit retry) re-ran scanBlockRangeInChunks from deploymentBlock all
 * the way to latest again - correct, but wasteful and exactly the kind of
 * repeated full-history load the RPC's own rate limiting reacts badly to,
 * especially once real settled-round history is long. Rounds are keyed by
 * roundId (RoundSettled fires at most once per round, so this also
 * naturally de-duplicates if a chunk were ever re-scanned). */
export interface RoundHistoryScanState {
  lastScannedBlock: bigint;
  roundsById: Map<number, SettledRound>;
}

export function createInitialScanState(fromBlock: bigint): RoundHistoryScanState {
  return { lastScannedBlock: fromBlock, roundsById: new Map() };
}

/** Minimal shape of a viem PublicClient this function actually calls -
 * kept narrow specifically so a test can pass a plain fake object with
 * just these two methods, without needing to construct or mock a real
 * wagmi/viem client at all. */
export interface RoundScanClient {
  getBlockNumber(): Promise<bigint>;
  getContractEvents(args: {
    address: Address;
    abi: typeof roundManagerAbi;
    eventName: "RoundSettled";
    fromBlock: bigint;
    toBlock: bigint;
  }): Promise<Log[]>;
}

/** The actual incremental scan: mutates `scanState` in place (advancing
 * lastScannedBlock and merging in newly found rounds) and returns the
 * full, current settled-round list, sorted newest-first. Extracted as a
 * plain, framework-free function - no react-query, no wagmi - specifically
 * so this, the highest-risk part of the whole fix (get the incremental
 * range wrong and either blocks are skipped or the same range is scanned
 * forever), is directly unit-testable against a fake client.
 *
 * INCREMENTAL, NOT A FULL RESCAN EVERY CALL: only [scanState.
 * lastScannedBlock, latest] is ever requested, never deploymentBlock again.
 * lastScannedBlock only advances after the chunked scan below resolves
 * successfully - a thrown error (e.g. a chunk's retries exhausted) leaves
 * scanState completely unmodified, so the NEXT call (the next scheduled
 * refetch, or an explicit retry) re-requests the exact same range rather
 * than losing progress or silently skipping the blocks that failed. */
export async function scanRoundHistoryIncremental(
  client: RoundScanClient,
  roundManager: Address,
  scanState: RoundHistoryScanState,
  chunkSizeBlocks: bigint = LOG_CHUNK_SIZE_BLOCKS
): Promise<SettledRound[]> {
  const latest = await retryTransient(() => client.getBlockNumber());

  if (latest >= scanState.lastScannedBlock) {
    const logs = await scanBlockRangeInChunks(scanState.lastScannedBlock, latest, chunkSizeBlocks, (chunkFrom, chunkTo) =>
      retryTransient(() =>
        client.getContractEvents({
          address: roundManager,
          abi: roundManagerAbi,
          eventName: "RoundSettled",
          fromBlock: chunkFrom,
          toBlock: chunkTo,
        })
      )
    );

    for (const log of logs) {
      const args = (log as Log & { args?: { roundId?: bigint; winnerTokenId?: bigint } }).args ?? {};
      if (args.roundId === undefined || args.winnerTokenId === undefined) continue;
      const roundId = Number(args.roundId);
      scanState.roundsById.set(roundId, { roundId, winnerTokenId: Number(args.winnerTokenId) });
    }

    // Only advance the cursor after the scan above has genuinely succeeded
    // end to end - see this function's own docs above.
    scanState.lastScannedBlock = latest + 1n;
  }

  return Array.from(scanState.roundsById.values()).sort((a, b) => b.roundId - a.roundId);
}

/** Module-level, per-RoundManager-address scan state - deliberately a
 * plain module-level Map, not React state: this needs to survive across
 * every remount of every component that calls this hook (dashboard,
 * landing, round page), not just one component's lifetime, and it is
 * never meant to trigger a re-render by itself - react-query's own query
 * result (returned by the hook below) is what components actually
 * observe. */
const scanStateByRoundManager = new Map<string, RoundHistoryScanState>();

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
 *
 * The actual scan logic lives in scanRoundHistoryIncremental above (see its
 * own docs for the incremental/cache-aware behavior) - this hook is a thin
 * wrapper that owns the module-level scan-state Map and wires it into
 * react-query.
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

      const scanState = scanStateByRoundManager.get(roundManager) ?? createInitialScanState(deploymentBlockBigInt);
      const result = await scanRoundHistoryIncremental(publicClient, roundManager, scanState, LOG_CHUNK_SIZE_BLOCKS);
      scanStateByRoundManager.set(roundManager, scanState);
      return result;
    },
  });
}
