"use client";

import { useMemo } from "react";
import { usePublicClient } from "wagmi";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useWalletAccount } from "./useWalletAccount";
import { useTokenDiscovery } from "./useTokenDiscovery";
import { useRoundHistory, type SettledRound } from "./useRoundHistory";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { memeTokenAbi } from "@/lib/web3/abis/memeToken";
import { tickerNFTAbi } from "@/lib/web3/abis/tickerNFT";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { mapWithConcurrencyLimit, retryTransient } from "@/lib/onchain/blockRangeChunker";
import { CLAIM_WINDOW_DAYS } from "@/lib/constants";
import type { UserPosition, TokenSummary, ClaimableReward, OwnedTickerNFT } from "@/lib/types";

interface AsyncState<T> {
  data: T | null;
  isLoading: boolean;
  error: string | null;
}

function toAsyncState<T>(q: { data: T | undefined; isLoading: boolean; error: unknown }, gate: boolean): AsyncState<T> {
  if (!gate) return { data: null, isLoading: false, error: null };
  return { data: q.data ?? null, isLoading: q.isLoading, error: q.error ? String(q.error) : null };
}

/** Holdings: iterates discovered tokens and reads each MemeToken's
 * balanceOf(wallet) directly. Acceptable at the current, small scale per
 * the reuse-first/no-indexer-yet instruction; revisit if the discovered
 * token count grows large enough that this becomes slow. */
export function useHeldTokens(): AsyncState<UserPosition[]> {
  const { address, isConnected } = useWalletAccount();
  const discovery = useTokenDiscovery();
  const publicClient = usePublicClient();

  const q = useQuery({
    queryKey: ["clog-held-tokens", address, discovery.data?.map((t) => t.tokenId).join(",")],
    enabled: isConnected && Boolean(address) && Boolean(discovery.data) && Boolean(publicClient),
    queryFn: async (): Promise<UserPosition[]> => {
      if (!publicClient || !address || !discovery.data) return [];

      const balances = await Promise.all(
        discovery.data.map((token) =>
          publicClient.readContract({
            address: token.tokenAddress,
            abi: memeTokenAbi,
            functionName: "balanceOf",
            args: [address],
          })
        )
      );

      return discovery.data
        .map((token, i) => ({
          token,
          balanceTokens: Number(balances[i]) / 1e18,
          balancePctOfSupply: (Number(balances[i]) / 1e18 / 1_000_000_000) * 100,
        }))
        .filter((p) => p.balanceTokens > 0);
    },
  });

  return toAsyncState(q, isConnected);
}

export function useLaunchedTokens(): AsyncState<TokenSummary[]> {
  const { address, isConnected } = useWalletAccount();
  const discovery = useTokenDiscovery();

  const filtered = useMemo(() => {
    if (!address || !discovery.data) return undefined;
    return discovery.data.filter((t) => t.creator.toLowerCase() === address.toLowerCase());
  }, [address, discovery.data]);

  return toAsyncState(
    { data: filtered, isLoading: discovery.isLoading, error: discovery.error },
    isConnected
  );
}

/** TickerNFT ownership: since each launched token's TickerNFT id equals its
 * tokenId (TickerRegistry mints them 1:1 at launch - see _launchMeme), this
 * checks ownerOf(tokenId) for each discovered token directly rather than
 * scanning Transfer events - simpler and correct at the current scale. */
export function useOwnedTickerNFTs(): AsyncState<OwnedTickerNFT[]> {
  const { address, isConnected } = useWalletAccount();
  const discovery = useTokenDiscovery();
  const publicClient = usePublicClient();

  const q = useQuery({
    queryKey: ["clog-owned-ticker-nfts", address, discovery.data?.map((t) => t.tokenId).join(",")],
    enabled: isConnected && Boolean(address) && Boolean(discovery.data) && Boolean(publicClient) && Boolean(addresses.tickerNFT),
    queryFn: async (): Promise<OwnedTickerNFT[]> => {
      if (!publicClient || !address || !discovery.data || !addresses.tickerNFT) return [];
      const tickerNFT = addresses.tickerNFT;

      const owners = await Promise.all(
        discovery.data.map((token) =>
          publicClient
            .readContract({
              address: tickerNFT,
              abi: tickerNFTAbi,
              functionName: "ownerOf",
              args: [BigInt(token.tokenId)],
            })
            .catch(() => null)
        )
      );

      return discovery.data
        .map((token, i) => ({ token, owner: owners[i] }))
        .filter((x) => x.owner && x.owner.toLowerCase() === address.toLowerCase())
        .map((x) => ({
          tokenId: x.token.tokenId,
          ticker: x.token.ticker,
          openSeaUrl: `https://opensea.io/assets/${tickerNFT}/${x.token.tokenId}`,
        }));
    },
  });

  return toAsyncState(q, isConnected);
}

/** At most this many RewardVault RPC reads (previewClaim + getAllocation,
 * so 2x this many actual requests) in flight at once - see
 * mapWithConcurrencyLimit's own docs for why an unbounded Promise.all over
 * every settled round in history is exactly the kind of load the
 * Robinhood public RPC has already demonstrated it rate-limits. */
const CLAIMABLE_READ_CONCURRENCY = 5;

/** Claimable rewards: for every round that has ever settled (useRoundHistory,
 * from RoundManager's RoundSettled events), calls RewardVault.previewClaim
 * for the connected wallet - the real, authoritative view function, not an
 * invented calculation. A nonzero result means real, claimable ETH.
 *
 * If useRoundHistory itself failed (e.g. a non-transient RPC error that
 * survived its own internal retries - see useRoundHistory.ts), that
 * failure is explicitly re-thrown here rather than left to silently look
 * like "round history is simply empty, so there's nothing to claim". The
 * `enabled` gate below no longer requires roundHistory.data to be present -
 * only that roundHistory has finished (successfully or not) - specifically
 * so an upstream error reaches this query's own `error` field instead of
 * leaving this query permanently disabled (and therefore reporting neither
 * loading nor error, which is exactly what let a real RPC failure render as
 * "no winnings" with no indication anything went wrong).
 *
 * This query's own queryFn reads round-history's data/error DIRECTLY FROM
 * THE QUERY CLIENT'S CACHE (queryClient.getQueryData/getQueryState on
 * useRoundHistory's own query key) rather than closing over the
 * `roundHistory` variable below. This matters specifically for retry (see
 * `refetch` at the bottom of this hook): a React hook's queryFn closure is
 * only refreshed on the NEXT RENDER of the component calling this hook, but
 * `await roundHistory.refetch(); q.refetch();` runs both calls before any
 * such re-render has necessarily happened - reading the closure-captured
 * `roundHistory.data` inside q's own queryFn would still see the PRE-retry
 * value at that moment, racing exactly as before. Reading straight from the
 * query client's cache instead is always current the instant
 * roundHistory's own refetch has resolved, regardless of React's own
 * render timing. */
export function useClaimableRewards(): AsyncState<ClaimableReward[]> & { refetch: () => Promise<void> } {
  const { address, isConnected } = useWalletAccount();
  const roundHistory = useRoundHistory();
  const discovery = useTokenDiscovery();
  const publicClient = usePublicClient();
  const queryClient = useQueryClient();
  const roundHistoryQueryKey = ["clog-round-history", addresses.roundManager];

  const q = useQuery({
    queryKey: ["clog-claimable", address, roundHistory.data?.map((r) => r.roundId).join(","), roundHistory.isError],
    enabled:
      isConnected &&
      Boolean(address) &&
      Boolean(publicClient) &&
      Boolean(addresses.rewardVault) &&
      !roundHistory.isLoading,
    retry: false,
    queryFn: async (): Promise<ClaimableReward[]> => {
      const roundHistoryState = queryClient.getQueryState<SettledRound[]>(roundHistoryQueryKey);
      if (roundHistoryState?.status === "error") {
        const upstreamError = roundHistoryState.error;
        throw upstreamError instanceof Error ? upstreamError : new Error(String(upstreamError ?? "Failed to load round history"));
      }
      const settledRounds = queryClient.getQueryData<SettledRound[]>(roundHistoryQueryKey) ?? roundHistory.data;
      if (!publicClient || !address || !settledRounds || !addresses.rewardVault) return [];
      const rewardVault = addresses.rewardVault;

      // Bounded concurrency (CLAIMABLE_READ_CONCURRENCY workers at a time),
      // never Promise.all across every settled round in history - see
      // mapWithConcurrencyLimit's own docs. Each individual read also
      // retries a transient failure (429/timeout/etc.) with backoff, same
      // as useRoundHistory's own chunk reads.
      const results = await mapWithConcurrencyLimit(settledRounds, CLAIMABLE_READ_CONCURRENCY, async (round) => {
        const [claimable, allocation] = await Promise.all([
          retryTransient(() =>
            publicClient.readContract({
              address: rewardVault,
              abi: rewardVaultAbi,
              functionName: "previewClaim",
              args: [BigInt(round.roundId), address],
            })
          ),
          retryTransient(() =>
            publicClient.readContract({
              address: rewardVault,
              abi: rewardVaultAbi,
              functionName: "getAllocation",
              args: [BigInt(round.roundId)],
            })
          ),
        ]);
        return { round, claimable, allocation };
      });

      return results
        .filter((r) => r.claimable > 0n)
        .map((r) => {
          const ticker = discovery.data?.find((t) => t.tokenId === r.round.winnerTokenId)?.ticker ?? `#${r.round.winnerTokenId}`;
          const windowCloses = new Date(
            (Number(r.allocation.allocatedAt) + CLAIM_WINDOW_DAYS * 86_400) * 1000
          ).toISOString();
          return {
            roundId: r.round.roundId,
            ticker,
            tokenId: r.round.winnerTokenId,
            // The authoritative previewClaim bigint, carried through exactly
            // as the contract returned it - never round-tripped through a
            // JS float. formatEthPrecise (and PrizeChute, on the redesigned
            // dashboard) both accept a bigint directly and format it
            // without ever passing through a lossy intermediate Number.
            amountWei: r.claimable,
            windowClosesAt: windowCloses,
          };
        });
    },
  });

  return {
    ...toAsyncState(q, isConnected),
    // Retries the whole chain from its own root cause, WITHOUT the race
    // the previous version had (roundHistory.refetch() and q.refetch()
    // fired independently, neither awaited, so q's own queryFn could run
    // against roundHistory's PRE-retry state): awaits roundHistory's own
    // refetch to completion first - by the time that promise resolves,
    // roundHistory's real result is already in the query client's cache -
    // and only then refetches this query, whose own queryFn (see above)
    // reads that same cache directly rather than a closure-captured value,
    // so it is guaranteed to see the just-refreshed round history, never
    // the stale pre-retry state.
    refetch: async () => {
      await roundHistory.refetch();
      await q.refetch();
    },
  };
}

export function useClaimHistory(): AsyncState<ClaimableReward[]> {
  // TODO: requires scanning RewardVault's `Claimed` events for this wallet -
  // not yet implemented. Returns an explicit empty state rather than
  // fabricated history.
  const { isConnected } = useWalletAccount();
  return { data: isConnected && isProtocolConfigured ? [] : null, isLoading: false, error: null };
}
