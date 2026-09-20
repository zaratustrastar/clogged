"use client";

import { MachineHero } from "@/components/landing/MachineHero";
import { LoopStrip } from "@/components/landing/LoopStrip";
import { PrizeTable } from "@/components/landing/PrizeTable";
import { TrustPlates, ClosingCTA } from "@/components/landing/TrustPlates";
import { useRoundStatus, useRecentDraws } from "@/lib/hooks/useTokenData";
import { useTokenDiscovery } from "@/lib/hooks/useTokenDiscovery";
import { useReadContract } from "wagmi";
import { useNow } from "@/lib/hooks/useNow";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { formatEthPrecise } from "@/lib/format";
import { formatCountdown } from "@/lib/format";
import type { EligibilityStage } from "@/lib/types";
import type { PrizeRow } from "@/components/landing/PrizeTable";
import type { HeroRound } from "@/components/landing/MachineHero";
import type { LastDraw } from "@/components/landing/TrustPlates";

/* DATA WIRING - lifted from the current app/page.tsx + components/landing/
 * Hero.tsx + DrawChamber.tsx (useRoundStatus/useTokenDiscovery/useRecentDraws),
 * exactly as the handoff's own placeholder comment asked. No new protocol
 * read added beyond what DrawChamber already made (RewardVault's
 * unallocatedPool for the jackpot - RoundStatus itself carries no jackpot
 * field). Formatting happens here, at the edge - presentational components
 * take strings, never a raw float (see lib/format.ts formatEthPrecise, fix
 * F1) and never round anything themselves. */

/** Maps the real 5-stage EligibilityStage to PrizeTable's 3-lamp status.
 * "ready" (streak + progress met, not yet confirmed by qualify()) reads as
 * QUALIFYING - still in progress, not yet locked in on-chain. "drawn"
 * tokens (from an already-resolved round) are filtered out below rather
 * than mapped here - "in the machine now" is a live-round table, not a
 * history of every token that has ever existed. */
function toPrizeStatus(stage: EligibilityStage): "QUALIFIED" | "QUALIFYING" | "BUILDING" {
  if (stage === "qualified") return "QUALIFIED";
  if (stage === "qualifying" || stage === "ready") return "QUALIFYING";
  return "BUILDING";
}

export default function LandingPage() {
  const now = useNow(1000);
  const roundStatus = useRoundStatus();
  const discovery = useTokenDiscovery();
  const draws = useRecentDraws(1);

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });

  const tokens = discovery.data ?? [];
  const qualifiedCount = tokens.filter((t) => t.eligibility === "qualified").length;

  const round: HeroRound = {
    roundNumber: roundStatus.data?.roundId ?? null,
    countdown: roundStatus.data ? formatCountdown(roundStatus.data.closesAt, now) : null,
    jackpotEth: unallocatedPool !== undefined ? `${formatEthPrecise(unallocatedPool)} ETH` : null,
    qualifiedCount: discovery.data ? qualifiedCount : null,
    // No hook currently exposes "randomness requested but not yet settled"
    // on the landing page's own data (RoundStatus has no such field, and
    // adding a new read here to drive this lamp would violate "add no
    // protocol reads") - left undefined, which MachineHero already treats
    // as the default "CLAW ARMED" state rather than a guess.
  };

  const prizes = tokens
    .filter((t) => t.eligibility !== "drawn")
    .slice(0, 4)
    .map((t) => ({ ticker: t.ticker }));

  const rows: PrizeRow[] = tokens
    .filter((t) => t.eligibility !== "drawn")
    .sort((a, b) => b.marketCapEth - a.marketCapEth)
    .slice(0, 6)
    .map((t) => ({
      ticker: t.ticker,
      name: t.name,
      imageUrl: t.imageUrl,
      priceEth: `${formatEthPrecise(t.priceEth)} ETH`,
      change24h: t.change24hPct,
      curvePct: t.curveProgressPct,
      status: toPrizeStatus(t.eligibility),
    }));

  const latestDraw = draws.data?.[0];
  // LastDraw requires a real randomWord/settlementTxUrl that no existing
  // hook exposes (DrawResult carries roundId/resolvedAt/winningTicker/
  // candidateCount/jackpotEth/yourShareEth - neither field). Rather than
  // invent either value, this always passes null until a real source for
  // them exists - TrustPlates' own "honest empty state" is the correct
  // rendering of "we don't have this data", not a fabricated placeholder.
  const lastDraw: LastDraw = null;
  void latestDraw; // real settled-round data is available (winningTicker etc.) once randomWord/settlementTxUrl have a real source

  return (
    <div className="mx-auto max-w-[1240px] px-5 pb-24">
      <MachineHero round={round} prizes={prizes} />
      <LoopStrip />
      <PrizeTable rows={rows} />
      <TrustPlates lastDraw={lastDraw} />
      <ClosingCTA />
    </div>
  );
}

/* Loading: every block above renders an honest "—" placeholder rather than
 * a zero (MachineHero/PrizeTable's own null-handling), and the marquee/
 * glass labels read "LOADING" until real values arrive - never a plausible-
 * looking number.
 *
 * Errors: roundStatus.error/discovery.error/draws.error are intentionally
 * not yet surfaced as a distinct error+retry state on this page - none of
 * the three patches in patches/README.md name the landing hero/prize table
 * as a P0/P1 (the P0s are dashboard claimable winnings and DrawPanel
 * qualification). Flagged in the PR description as an observation, not
 * fixed here, since presentational components were not to be rewritten
 * beyond what the runbook/patches explicitly call for. */
