"use client";

import { useMemo } from "react";
import { usePublicClient } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { useWalletAccount } from "./useWalletAccount";
import { useTokenDiscovery } from "./useTokenDiscovery";
import { useRoundHistory } from "./useRoundHistory";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { memeTokenAbi } from "@/lib/web3/abis/memeToken";
import { tickerNFTAbi } from "@/lib/web3/abis/tickerNFT";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
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

/** Claimable rewards: for every round that has ever settled (useRoundHistory,
 * from RoundManager's RoundSettled events), calls RewardVault.previewClaim
 * for the connected wallet - the real, authoritative view function, not an
 * invented calculation. A nonzero result means real, claimable ETH. */
export function useClaimableRewards(): AsyncState<ClaimableReward[]> {
  const { address, isConnected } = useWalletAccount();
  const roundHistory = useRoundHistory();
  const discovery = useTokenDiscovery();
  const publicClient = usePublicClient();

  const q = useQuery({
    queryKey: ["clog-claimable", address, roundHistory.data?.map((r) => r.roundId).join(",")],
    enabled: isConnected && Boolean(address) && Boolean(roundHistory.data) && Boolean(publicClient) && Boolean(addresses.rewardVault),
    queryFn: async (): Promise<ClaimableReward[]> => {
      if (!publicClient || !address || !roundHistory.data || !addresses.rewardVault) return [];
      const rewardVault = addresses.rewardVault;

      const results = await Promise.all(
        roundHistory.data.map(async (round) => {
          const [claimable, allocation] = await Promise.all([
            publicClient.readContract({
              address: rewardVault,
              abi: rewardVaultAbi,
              functionName: "previewClaim",
              args: [BigInt(round.roundId), address],
            }),
            publicClient.readContract({
              address: rewardVault,
              abi: rewardVaultAbi,
              functionName: "getAllocation",
              args: [BigInt(round.roundId)],
            }),
          ]);
          return { round, claimable, allocation };
        })
      );

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
            amountEth: Number(r.claimable) / 1e18,
            windowClosesAt: windowCloses,
          };
        });
    },
  });

  return toAsyncState(q, isConnected);
}

export function useClaimHistory(): AsyncState<ClaimableReward[]> {
  // TODO: requires scanning RewardVault's `Claimed` events for this wallet -
  // not yet implemented. Returns an explicit empty state rather than
  // fabricated history.
  const { isConnected } = useWalletAccount();
  return { data: isConnected && isProtocolConfigured ? [] : null, isLoading: false, error: null };
}
