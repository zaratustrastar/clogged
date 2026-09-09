"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { addresses } from "@/lib/web3/addresses";
import { deploymentBlockBigInt, isProtocolConfigured } from "@/lib/web3/env";
import { roundManagerAbi } from "@/lib/web3/abis/roundManager";

export interface SettledRound {
  roundId: number;
  winnerTokenId: number;
}

/** Every round that has ever settled with a winner, from RoundManager's
 * `RoundSettled` event. Shared by useRecentDraws (dashboard/landing "recent
 * draws" list) and useClaimableRewards (which needs to know which rounds to
 * call RewardVault.previewClaim against) so the log scan only happens once. */
export function useRoundHistory() {
  const publicClient = usePublicClient();

  return useQuery({
    queryKey: ["clog-round-history", addresses.roundManager],
    enabled: isProtocolConfigured && Boolean(publicClient),
    staleTime: 30_000,
    refetchInterval: 30_000,
    queryFn: async (): Promise<SettledRound[]> => {
      if (!publicClient || !addresses.roundManager) return [];

      const logs = await publicClient.getContractEvents({
        address: addresses.roundManager,
        abi: roundManagerAbi,
        eventName: "RoundSettled",
        fromBlock: deploymentBlockBigInt,
        toBlock: "latest",
      });

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
