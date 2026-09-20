"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { addresses } from "@/lib/web3/addresses";
import { deploymentBlockBigInt, isProtocolConfigured } from "@/lib/web3/env";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { eligibilityRegistryAbi } from "@/lib/web3/abis/eligibilityRegistry";
import {
  MIN_PROGRESS_BPS,
  MIN_RESERVE_THRESHOLD_ETH,
  REQUIRED_STREAK_SECONDS,
} from "@/lib/constants";
import type { EligibilityStage, TokenSummary } from "@/lib/types";
import { tokenProfileStore, type TokenProfile } from "@/lib/metadata/TokenProfileStore";

/** Every launched token's real on-chain state, discovered from
 * TickerRegistry's `Launched` events (per section 4: no indexer/subgraph -
 * direct event reads + batched reads, cached via React Query). This is the
 * one place that talks to the chain for "which tokens exist"; every other
 * read hook derives from this query's cached result. */
export function useTokenDiscovery() {
  const publicClient = usePublicClient();

  return useQuery({
    queryKey: ["clog-token-discovery", addresses.tickerRegistry],
    enabled: isProtocolConfigured && Boolean(publicClient),
    staleTime: 15_000,
    refetchInterval: 20_000,
    queryFn: async (): Promise<TokenSummary[]> => {
      if (!publicClient || !addresses.tickerRegistry || !addresses.eligibilityRegistry) return [];
      const eligibilityRegistry = addresses.eligibilityRegistry;

      const launches = await publicClient.getContractEvents({
        address: addresses.tickerRegistry,
        abi: tickerRegistryAbi,
        eventName: "Launched",
        fromBlock: deploymentBlockBigInt,
        toBlock: "latest",
      });

      if (launches.length === 0) return [];

      const currentRoundId = await publicClient.readContract({
        address: eligibilityRegistry,
        abi: eligibilityRegistryAbi,
        functionName: "currentRoundId",
      });

      const blockNumbersByHash = new Map<string, bigint>();
      for (const log of launches) {
        if (log.blockHash && log.blockNumber !== undefined) {
          blockNumbersByHash.set(log.blockHash, log.blockNumber);
        }
      }
      const blockTimestamps = new Map<string, bigint>();
      await Promise.all(
        [...blockNumbersByHash.entries()].map(async ([hash, blockNumber]) => {
          const block = await publicClient.getBlock({ blockNumber });
          blockTimestamps.set(hash, block.timestamp);
        })
      );

      const tokens = await Promise.all(
        launches.map(async (log) => {
          const { tokenId, ticker, market } = log.args as {
            tokenId: bigint;
            ticker: string;
            market: Address;
            token: Address;
            sender: Address;
          };
          const token = (log.args as { token: Address }).token;
          const sender = (log.args as { sender: Address }).sender;

          const [currentPrice, realReserve, progressBps, aboveThresholdSince, isCandidate] = await Promise.all([
            publicClient.readContract({ address: market, abi: bondingCurveClogAbi, functionName: "currentPrice" }),
            publicClient.readContract({ address: market, abi: bondingCurveClogAbi, functionName: "realReserve" }),
            publicClient.readContract({ address: market, abi: bondingCurveClogAbi, functionName: "progressBps" }),
            publicClient.readContract({
              address: eligibilityRegistry,
              abi: eligibilityRegistryAbi,
              functionName: "aboveThresholdSince",
              args: [tokenId],
            }),
            publicClient.readContract({
              address: eligibilityRegistry,
              abi: eligibilityRegistryAbi,
              functionName: "isCandidate",
              args: [currentRoundId, tokenId],
            }),
          ]);

          const createdAt = log.blockHash ? blockTimestamps.get(log.blockHash) : undefined;

          const priceEth = Number(currentPrice) / 1e18;
          const reserveEth = Number(realReserve) / 1e18;
          const progressPct = Number(progressBps) / 100;

          const eligibility = deriveEligibilityStage({
            progressPct,
            reserveEth,
            aboveThresholdSince: Number(aboveThresholdSince),
            isCandidate,
          });

          const summary: TokenSummary = {
            tokenId: Number(tokenId),
            ticker,
            name: ticker, // onchain fallback only - overwritten below with the persisted
                          // displayName when one exists (see the getMany enrichment step
                          // at the end of this queryFn)
            imageUrl: null, // onchain fallback only - overwritten below with the persisted
                             // imageUrl when one exists (same enrichment step)
            marketAddress: market,
            tokenAddress: token,
            creator: sender,
            createdAt: createdAt ? new Date(Number(createdAt) * 1000).toISOString() : new Date(0).toISOString(),
            priceEth,
            marketCapEth: priceEth * 1_000_000_000, // spot price x fixed 1B supply
            volume24hEth: 0, // TODO: requires log-scanning Bought/Sold events over a time window,
                             // or an indexer, to compute safely - rendered as "—" (see format.ts)
            change1hPct: null, // requires historical price snapshots - not derivable from current state
            change24hPct: null,
            curveProgressPct: Math.min(100, progressPct),
            eligibility,
            eligibleSinceSeconds: Number(aboveThresholdSince) > 0 ? Number(aboveThresholdSince) : null,
          };
          return summary;
        })
      );

      // Enrich with persisted off-chain profile data (imageUrl, a real
      // display name) in exactly ONE additional round trip for the whole
      // discovered set - never one request per token. A profile-fetch
      // failure (DB down, network error) never breaks discovery itself:
      // tokenProfileStore.getMany already swallows its own errors and
      // returns an empty map, so every token simply keeps its onchain-only
      // fallback (imageUrl: null, name: ticker) in that case, exactly as
      // it did before this enrichment step existed.
      const profiles = await tokenProfileStore.getMany(tokens.map((t) => t.tokenId));
      const enriched = enrichTokensWithProfiles(tokens, profiles);

      return enriched.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    },
  });
}

function deriveEligibilityStage(params: {
  progressPct: number;
  reserveEth: number;
  aboveThresholdSince: number;
  isCandidate: boolean;
}): EligibilityStage {
  const { progressPct, reserveEth, aboveThresholdSince, isCandidate } = params;
  if (isCandidate) return "qualified";

  if (aboveThresholdSince > 0) {
    const elapsedSeconds = Math.floor(Date.now() / 1000) - aboveThresholdSince;
    const streakComplete = elapsedSeconds >= REQUIRED_STREAK_SECONDS;
    const progressMet = progressPct >= MIN_PROGRESS_BPS / 100;
    if (streakComplete && progressMet) return "ready"; // both gates met, awaiting a confirming touch
    return "qualifying"; // streak running, not yet 30 minutes (or progress not yet at 5%)
  }

  return "building"; // reserve currently below MIN_RESERVE_THRESHOLD, no streak running
}

/** The actual merge decision for enriching discovered on-chain tokens with
 *  their persisted off-chain profile data - extracted as a pure function,
 *  the same way isStillResolvingTokenExistence is in useTokenData.ts,
 *  specifically so this decision is directly testable without mocking
 *  react-query/wagmi/fetch. A tokenId with no entry in `profiles` (no
 *  saved profile, or the whole batch fetch failed and returned an empty
 *  map) keeps its onchain-only fallback fields completely unchanged -
 *  every field on `token` other than imageUrl/name is always passed
 *  through untouched, never recomputed here. */
export function enrichTokensWithProfiles(tokens: TokenSummary[], profiles: Map<number, TokenProfile>): TokenSummary[] {
  return tokens.map((t) => {
    const profile = profiles.get(t.tokenId);
    return {
      ...t,
      imageUrl: profile?.imageUrl ?? t.imageUrl,
      name: profile?.displayName ?? t.name,
    };
  });
}
