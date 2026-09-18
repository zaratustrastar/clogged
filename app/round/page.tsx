"use client";

import { RoundStage, RecentDraws, type RoundView, type Draw } from "@/components/round/RoundStage";
import { NoSignal, ErrorPlate } from "@/components/machine/States";
import { useRoundStatus, useRecentDraws } from "@/lib/hooks/useTokenData";
import { useTokenDiscovery } from "@/lib/hooks/useTokenDiscovery";
import { useReadContract } from "wagmi";
import { addresses } from "@/lib/web3/addresses";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { isProtocolConfigured } from "@/lib/web3/env";
import { formatEthPrecise, formatCountdown } from "@/lib/format";
import { useNow } from "@/lib/hooks/useNow";

/* NEW ROUTE - the protocol's most cinematic moment finally has an address.
 * It adds NO new protocol reads beyond RewardVault.unallocatedPool (the same
 * jackpot read the landing page/DrawChamber already make) - everything else
 * comes from useRoundStatus and useRecentDraws, which already exist.
 *
 * Runbook §0 mismatches found and fixed here (both file paths wrong, same
 * pattern as the landing page - confirmed directly against
 * lib/hooks/useTokenData.ts, not assumed):
 *   - useRoundStatus  @/lib/hooks/useRoundStatus  -> @/lib/hooks/useTokenData
 *   - useRecentDraws  @/lib/hooks/useRoundHistory -> @/lib/hooks/useTokenData
 *
 * The real RoundStatus type (lib/types.ts) carries none of the handoff's
 * assumed fields (winner/randomnessRequested/countdown/jackpotEth/
 * qualifiedCount/candidates/vrf) - only roundId/opensAt/closesAt/
 * candidateCount/minCandidatesToDraw. No hook anywhere exposes "randomness
 * requested" or per-round VRF state at all (confirmed by grepping every
 * hook file), and adding a new raw contract read for it would violate this
 * task's own "add no protocol reads" constraint. Phase derivation below is
 * therefore built ONLY from data these two hooks and the existing
 * unallocatedPool read (already made elsewhere) actually provide:
 *   - a matching DrawResult (useRecentDraws, keyed by roundId) with a real
 *     winningTicker -> "settled" - the only real winner source anywhere.
 *   - closesAt already passed, no matching settled draw yet -> collapsed
 *     into "randomness-pending" (this page cannot distinguish "just closed,
 *     not yet requested" from "requested, awaiting VRF" without a read this
 *     task doesn't allow adding - both states correctly show no winner,
 *     which is the one guarantee RoundStage itself enforces).
 *   - otherwise (closesAt still in the future) -> "open".
 * vrf is always null (no hook exposes VRF state/detail at all - honest
 * absence, never fabricated). winner.holders has no real source either
 * (no holder-count field anywhere, same gap as the dashboard) - "—".
 * candidates comes from useTokenDiscovery filtered to eligibility ===
 * "qualified", same as the landing page's own prizes computation. */

export default function RoundPage() {
  const now = useNow(1000);
  const round = useRoundStatus();
  const draws = useRecentDraws(10);
  const discovery = useTokenDiscovery();

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });

  if (round.error) {
    return (
      <div className="mx-auto max-w-[1240px] px-5 py-7">
        <ErrorPlate title="Could not read the round" detail={round.error} onRetry={() => window.location.reload()} />
      </div>
    );
  }

  if (!round.data) {
    return (
      <div className="mx-auto max-w-[1240px] px-5 py-7">
        <NoSignal lines={6} />
      </div>
    );
  }

  const r = round.data;
  const settledDraw = draws.data?.find((d) => d.roundId === r.roundId);
  const hasClosed = new Date(r.closesAt).getTime() <= now;

  const view: RoundView = {
    phase: settledDraw?.winningTicker ? "settled" : hasClosed ? "randomness-pending" : "open",
    roundNumber: r.roundId,
    countdown: hasClosed ? null : formatCountdown(r.closesAt, now),
    jackpotEth: unallocatedPool !== undefined ? formatEthPrecise(unallocatedPool) : "—",
    qualifiedCount: r.candidateCount,
    candidates: (discovery.data ?? []).filter((t) => t.eligibility === "qualified").map((t) => ({ ticker: t.ticker })),
    winner: settledDraw?.winningTicker
      ? { ticker: settledDraw.winningTicker, holders: "—", potEth: settledDraw.jackpotEth !== null ? formatEthPrecise(settledDraw.jackpotEth) : "—" }
      : null,
    vrf: null,
  };

  const recentDraws: Draw[] = (draws.data ?? [])
    .filter((d) => d.winningTicker !== null)
    .map((d) => ({
      roundNumber: d.roundId,
      ticker: d.winningTicker as string,
      potEth: d.jackpotEth !== null ? formatEthPrecise(d.jackpotEth) : "—",
      holders: "—",
      vrfUrl: null,
    }));

  return (
    <div className="mx-auto flex max-w-[1240px] flex-col gap-[18px] px-5 pb-24 pt-7">
      <header className="flex flex-col gap-1.5">
        <span className="font-mono text-label text-amber">THE DRAW</span>
        <h1 className="m-0 font-display text-[clamp(26px,3.6vw,38px)] tracking-[-0.025em]">
          Round #{r.roundId}
        </h1>
      </header>

      <RoundStage view={view} />
      {recentDraws.length ? <RecentDraws draws={recentDraws} /> : null}
    </div>
  );
}
