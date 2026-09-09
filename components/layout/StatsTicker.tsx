"use client";

import { useRoundStatus } from "@/lib/hooks/useTokenData";
import { useNow } from "@/lib/hooks/useNow";
import { formatCountdown, formatEth, formatCompact } from "@/lib/format";
import { MAX_PUBLIC_TICKERS } from "@/lib/constants";

// Mock aggregate figures. TODO (live wiring): these should come from an
// indexer's rollup (total volume, total launched) plus direct reads
// (RewardVault's unallocated pool balance for "jackpot", EligibilityRegistry
// candidate count for "qualified", TickerRegistry.publicTickerCount for
// "launched").
const MOCK_JACKPOT_ETH = 4.28;
const MOCK_TOTAL_VOLUME_ETH = 1284;
const MOCK_LAUNCHED_COUNT = 1348;

function StatItems({ closesAt, qualified, now }: { closesAt: string; qualified: number; now: number }) {
  return (
    <>
      <StatItem label="Jackpot" value={`${formatEth(MOCK_JACKPOT_ETH, { decimals: 2 })}`} tone="gold" />
      <StatItem label="Qualified" value={String(qualified)} tone="cyan" />
      <StatItem label="Next draw" value={formatCountdown(closesAt, now)} tone="cyan" mono />
      <StatItem label="Volume" value={`${formatCompact(MOCK_TOTAL_VOLUME_ETH)} ETH`} />
      <StatItem
        label="Launched"
        value={`${formatCompact(MOCK_LAUNCHED_COUNT)} / ${formatCompact(MAX_PUBLIC_TICKERS)}`}
      />
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
  const now = useNow();

  if (!round) {
    return <div className="h-9 border-b border-border bg-surface/60" />;
  }

  return (
    <div className="overflow-hidden border-b border-border bg-surface/60">
      <div className="flex w-max animate-[marquee_38s_linear_infinite] divide-x divide-border py-2 hover:[animation-play-state:paused]">
        <StatItems closesAt={round.closesAt} qualified={round.candidateCount} now={now} />
        <StatItems closesAt={round.closesAt} qualified={round.candidateCount} now={now} />
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
