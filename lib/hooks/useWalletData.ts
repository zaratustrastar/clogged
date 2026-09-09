"use client";

import { useEffect, useState } from "react";
import type { UserPosition, TokenSummary, ClaimableReward, OwnedTickerNFT } from "@/lib/types";
import {
  MOCK_USER_POSITIONS,
  MOCK_LAUNCHED,
  MOCK_CLAIMABLE,
  MOCK_CLAIM_HISTORY,
  MOCK_OWNED_TICKERS,
} from "@/lib/mockData";
import { useWalletAccount } from "./useWalletAccount";

interface AsyncState<T> {
  data: T | null;
  isLoading: boolean;
  error: string | null;
}

// TODO (live wiring): every hook below should key off `useWalletAccount()`'s
// real connected address and:
//   - useHeldTokens: read ERC20 balances for every MemeToken the indexer has
//     seen the wallet interact with (a balance-of sweep across an indexer's
//     known token list, same pattern as any portfolio view).
//   - useLaunchedTokens: indexer query on TickerRegistry's `Launched` event
//     filtered by `sender == address`.
//   - useClaimableRewards: for each round where the wallet held the winning
///     token, call RewardVault.previewClaim(roundId, address) — nonzero
//     results are claimable.
//   - useOwnedTickerNFTs: TickerNFT.balanceOf/tokenOfOwnerByIndex, or an
//     indexer sweep of Transfer events to the connected address.
function useMockWalletAsync<T>(value: T, delayMs = 350): AsyncState<T> {
  const { address } = useWalletAccount();
  const [state, setState] = useState<AsyncState<T>>({ data: null, isLoading: true, error: null });

  useEffect(() => {
    if (!address) {
      setState({ data: null, isLoading: false, error: null });
      return;
    }
    let cancelled = false;
    setState({ data: null, isLoading: true, error: null });
    const t = setTimeout(() => {
      if (!cancelled) setState({ data: value, isLoading: false, error: null });
    }, delayMs);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [address]);

  return state;
}

export function useHeldTokens(): AsyncState<UserPosition[]> {
  return useMockWalletAsync(MOCK_USER_POSITIONS);
}

export function useLaunchedTokens(): AsyncState<TokenSummary[]> {
  return useMockWalletAsync(MOCK_LAUNCHED);
}

export function useClaimableRewards(): AsyncState<ClaimableReward[]> {
  return useMockWalletAsync(MOCK_CLAIMABLE);
}

export function useClaimHistory(): AsyncState<ClaimableReward[]> {
  return useMockWalletAsync(MOCK_CLAIM_HISTORY);
}

export function useOwnedTickerNFTs(): AsyncState<OwnedTickerNFT[]> {
  return useMockWalletAsync(MOCK_OWNED_TICKERS);
}
