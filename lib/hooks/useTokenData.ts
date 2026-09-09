"use client";

import { useEffect, useState } from "react";
import type { TokenDetail, TokenSummary, RoundStatus, DrawResult } from "@/lib/types";
import {
  MOCK_TOKENS,
  MOCK_ROUND_STATUS,
  MOCK_RECENT_DRAWS,
  findTokenByTicker,
} from "@/lib/mockData";

// ---------------------------------------------------------------------------
// READ HOOKS
//
// Every hook here returns { data, isLoading, error } and is called exactly
// the way a real data hook would be, so swapping the implementation later
// never touches a calling component.
//
// TODO (live wiring): these should become a thin layer over:
//   - an indexer (subgraph-equivalent or direct event log queries) for
//     anything list-shaped: token feed, activity, draw history. Reading
//     "all tokens ever launched" directly from contract storage does not
//     scale; TickerRegistry only exposes per-tokenId lookups on-chain.
//   - direct `useReadContract` (wagmi) calls for anything single-value and
//     current: a specific token's live price/curve state from
//     BondingCurveClog, round status from RoundManager, eligibility from
//     EligibilityRegistry.
// ---------------------------------------------------------------------------

interface AsyncState<T> {
  data: T | null;
  isLoading: boolean;
  error: string | null;
}

function useMockAsync<T>(value: T, delayMs = 300): AsyncState<T> {
  const [state, setState] = useState<AsyncState<T>>({
    data: null,
    isLoading: true,
    error: null,
  });

  useEffect(() => {
    let cancelled = false;
    setState({ data: null, isLoading: true, error: null });
    const t = setTimeout(() => {
      if (!cancelled) setState({ data: value, isLoading: false, error: null });
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, delayMs);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(value)]);

  return state;
}

export function useTokenList(): AsyncState<TokenSummary[]> {
  return useMockAsync(MOCK_TOKENS);
}

export function useTrendingTokens(limit = 4): AsyncState<TokenSummary[]> {
  const sorted = [...MOCK_TOKENS].sort((a, b) => b.volume24hEth - a.volume24hEth).slice(0, limit);
  return useMockAsync(sorted);
}

export function useTokenDetail(ticker: string): AsyncState<TokenDetail | null> {
  return useMockAsync(findTokenByTicker(ticker), 250);
}

export function useRoundStatus(): AsyncState<RoundStatus> {
  return useMockAsync(MOCK_ROUND_STATUS, 150);
}

export function useRecentDraws(limit = 10): AsyncState<DrawResult[]> {
  return useMockAsync(MOCK_RECENT_DRAWS.slice(0, limit), 200);
}
