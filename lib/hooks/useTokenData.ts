"use client";

import { useMemo } from "react";
import { usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { useTokenDiscovery } from "./useTokenDiscovery";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { roundManagerAbi } from "@/lib/web3/abis/roundManager";
import { eligibilityRegistryAbi } from "@/lib/web3/abis/eligibilityRegistry";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { ROUND_DURATION_SECONDS, MIN_DRAW_CANDIDATES } from "@/lib/constants";
import type { TokenDetail, DrawResult, RoundStatus, TokenSummary } from "@/lib/types";

interface AsyncState<T> {
  data: T | null;
  isLoading: boolean;
  error: string | null;
}

function toAsyncState<T>(q: { data: T | undefined; isLoading: boolean; error: unknown }): AsyncState<T> {
  return {
    data: q.data ?? null,
    isLoading: q.isLoading,
    error: q.error ? String(q.error) : null,
  };
}

export function useTokenList(): AsyncState<TokenSummary[]> {
  const q = useTokenDiscovery();
  return toAsyncState(q);
}

export function useTrendingTokens(limit = 4): AsyncState<TokenSummary[]> {
  const q = useTokenDiscovery();
  const sorted = useMemo(() => {
    if (!q.data) return undefined;
    // Real, derivable ranking only: market cap (spot price x fixed supply).
    // 24h volume isn't safely derivable yet (see useTokenDiscovery), so it
    // isn't used for ranking here to avoid implying a metric that's really
    // just zero for every token right now.
    return [...q.data].sort((a, b) => b.marketCapEth - a.marketCapEth).slice(0, limit);
  }, [q.data, limit]);
  return { data: sorted ?? null, isLoading: q.isLoading, error: q.error ? String(q.error) : null };
}

export function useTokenDetail(ticker: string): AsyncState<TokenDetail> {
  const discovery = useTokenDiscovery();
  const publicClient = usePublicClient();
  const base = discovery.data?.find((t) => t.ticker.toUpperCase() === ticker.toUpperCase());

  const detailQuery = useQuery({
    queryKey: ["clog-token-detail", base?.tokenId],
    enabled: Boolean(base) && Boolean(publicClient) && isProtocolConfigured,
    refetchInterval: 10_000,
    queryFn: async (): Promise<TokenDetail> => {
      if (!base || !publicClient) throw new Error("token not found");

      const [clogRemaining, tickerOwner, realReserve] = await Promise.all([
        publicClient.readContract({ address: base.marketAddress, abi: bondingCurveClogAbi, functionName: "clogRemaining" }),
        publicClient.readContract({ address: base.marketAddress, abi: bondingCurveClogAbi, functionName: "ticketOwnerRecipient" }),
        publicClient.readContract({ address: base.marketAddress, abi: bondingCurveClogAbi, functionName: "realReserve" }),
      ]);

      const detail: TokenDetail = {
        ...base,
        tickerOwner,
        // tickerTokenId equals tokenId by construction - TickerRegistry mints
        // the TickerNFT with the same id EligibilityRegistry registered (see
        // TickerRegistry.sol's _launchMeme).
        tickerTokenId: base.tokenId,
        realReserveEth: Number(realReserve) / 1e18,
        clogRemainingTokens: Number(clogRemaining) / 1e18,
        totalSupply: 1_000_000_000,
        curveAllocation: 900_000_000,
        clogAllocation: 100_000_000,
        recentActivity: [], // TODO: requires log-scanning Bought/Sold/Qualified events - see report
        drawHistory: [], // TODO: requires scanning RoundSettled events per token - see report
      };
      return detail;
    },
  });

  return toAsyncState(detailQuery);
}

export function useRoundStatus(): AsyncState<RoundStatus> {
  const publicClient = usePublicClient();

  const q = useQuery({
    queryKey: ["clog-round-status", addresses.roundManager],
    enabled: isProtocolConfigured && Boolean(publicClient),
    refetchInterval: 5_000,
    queryFn: async (): Promise<RoundStatus> => {
      if (!publicClient || !addresses.roundManager || !addresses.eligibilityRegistry) {
        throw new Error("not configured");
      }
      const roundManager = addresses.roundManager;
      const eligibilityRegistry = addresses.eligibilityRegistry;

      const currentRoundId = await publicClient.readContract({
        address: roundManager,
        abi: roundManagerAbi,
        functionName: "currentRoundId",
      });

      const [currentRoundOpenTime, candidateCount] = await Promise.all([
        publicClient.readContract({ address: roundManager, abi: roundManagerAbi, functionName: "currentRoundOpenTime" }),
        publicClient.readContract({
          address: eligibilityRegistry,
          abi: eligibilityRegistryAbi,
          functionName: "candidateCount",
          args: [currentRoundId],
        }),
      ]);

      return {
        roundId: Number(currentRoundId),
        opensAt: new Date(Number(currentRoundOpenTime) * 1000).toISOString(),
        closesAt: new Date((Number(currentRoundOpenTime) + ROUND_DURATION_SECONDS) * 1000).toISOString(),
        candidateCount: Number(candidateCount),
        minCandidatesToDraw: MIN_DRAW_CANDIDATES,
      };
    },
  });

  return toAsyncState(q);
}

export function useRecentDraws(limit = 10): AsyncState<DrawResult[]> {
  // TODO: requires scanning RoundManager's RoundSettled/RoundClosed events
  // across a block range - not yet implemented (see final report). Returns
  // an empty list (rendered as a real "no recent draws yet" state) rather
  // than fabricated history.
  void limit;
  return { data: isProtocolConfigured ? [] : null, isLoading: false, error: null };
}
