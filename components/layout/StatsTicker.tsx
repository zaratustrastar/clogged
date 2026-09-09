"use client";

import { useReadContract } from "wagmi";
import { useRoundStatus, useTokenList } from "@/lib/hooks/useTokenData";
import { useNow } from "@/lib/hooks/useNow";
import { formatCountdown, formatEth, formatCompact } from "@/lib/format";
import { MAX_PUBLIC_TICKERS } from "@/lib/constants";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";

function StatItems({
  closesAt,
  qualified,
  now,
  jackpotEth,
  launchedCount,
}: {
  closesAt: string;
  qualified: number;
  now: number;
  jackpotEth: number | null;
  launchedCount: number;
}) {
  return (
    <>
      <StatItem label="Jackpot" value={jackpotEth === null ? "—" : formatEth(jackpotEth, { decimals: 2 })} tone="gold" />
      <StatItem label="Qualified" value={String(qualified)} tone="cyan" />
      <StatItem label="Next draw" value={formatCountdown(closesAt, now)} tone="cyan" mono />
      <StatItem label="Volume" value="—" />
      <StatItem label="Launched" value={`${formatCompact(launchedCount)} / ${formatCompact(MAX_PUBLIC_TICKERS)}`} />
    </>
  );
}

function StatItem({
  label,
  value,
  tone,
  mono,
}: {
  label: string;
  value: string;
  tone?: "cyan" | "gold";
  mono?: boolean;
}) {
  return (
    <span className="flex shrink-0 items-center gap-1.5 px-4 text-xs">
      <span className="text-ink-faint">{label}</span>
      <span
        className={`font-medium ${mono ? "font-mono tabular" : ""} ${
          tone === "cyan" ? "text-cyan" : tone === "gold" ? "text-gold" : "text-ink"
        }`}
      >
        {value}
      </span>
    </span>
  );
}

export function StatsTicker() {
  const { data: round } = useRoundStatus();
  const { data: tokens } = useTokenList();
  const now = useNow();

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });

  if (!isProtocolConfigured) {
    return (
      <div className="flex h-9 items-center justify-center border-b border-border bg-surface/60 text-xs text-ink-faint">
        Protocol contracts not configured yet.
      </div>
    );
  }

  if (!round) {
    return <div className="h-9 border-b border-border bg-surface/60" />;
  }

  const jackpotEth = unallocatedPool !== undefined ? Number(unallocatedPool) / 1e18 : null;
  const launchedCount = tokens?.length ?? 0;

  return (
    <div className="overflow-hidden border-b border-border bg-surface/60">
      <div className="flex w-max animate-[marquee_38s_linear_infinite] divide-x divide-border py-2 hover:[animation-play-state:paused]">
        <StatItems closesAt={round.closesAt} qualified={round.candidateCount} now={now} jackpotEth={jackpotEth} launchedCount={launchedCount} />
        <StatItems closesAt={round.closesAt} qualified={round.candidateCount} now={now} jackpotEth={jackpotEth} launchedCount={launchedCount} />
      </div>
      <style jsx>{`
        @keyframes marquee {
          from {
            transform: translateX(0);
          }
          to {
            transform: translateX(-50%);
          }
        }
      `}</style>
    </div>
  );
}
