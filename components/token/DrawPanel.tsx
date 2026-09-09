"use client";

import { CountdownClock } from "@/components/ui/CountdownClock";
import { useRoundStatus, useTokenList } from "@/lib/hooks/useTokenData";
import { REQUIRED_STREAK_SECONDS } from "@/lib/constants";
import type { TokenDetail } from "@/lib/types";

export function DrawPanel({ token }: { token: TokenDetail }) {
  const { data: round } = useRoundStatus();
  const { data: allTokens } = useTokenList();
  const qualifiedCount = allTokens?.filter((t) => t.eligibility === "qualified").length ?? 0;

  if (token.eligibility === "qualified") {
    return (
      <div className="rounded-md border border-cyan/30 bg-cyan/5 p-5">
        <div className="flex items-center gap-2">
          <span className="h-1.5 w-1.5 rounded-full bg-cyan" />
          <h3 className="font-display text-sm font-semibold text-cyan">Qualified for next draw</h3>
        </div>
        <p className="mt-1.5 text-xs text-ink-dim">
          Every qualified meme has equal odds — holding more {token.ticker} does not improve its
          chance of winning.
        </p>

        <div className="mt-4 flex items-center justify-between">
          <div>
            <p className="text-xs text-ink-faint">Next draw</p>
            {round && <CountdownClock targetIso={round.closesAt} size="md" />}
          </div>
          <div className="text-right">
            <p className="text-xs text-ink-faint">{token.ticker} odds</p>
            <p className="font-mono text-lg text-ink">1 / {qualifiedCount || "—"}</p>
          </div>
        </div>
      </div>
    );
  }

  if (token.eligibility === "qualifying" && token.eligibleSinceSeconds !== null) {
    const pct = Math.min(100, (token.eligibleSinceSeconds / REQUIRED_STREAK_SECONDS) * 100);
    const elapsedMin = Math.floor(token.eligibleSinceSeconds / 60);
    const elapsedSec = token.eligibleSinceSeconds % 60;
    const reqMin = REQUIRED_STREAK_SECONDS / 60;

    return (
      <div className="rounded-md border border-border bg-surface p-5">
        <h3 className="font-display text-sm font-semibold text-ink">Building eligibility</h3>
        <p className="mt-1.5 text-xs text-ink-dim">Real reserve above threshold, continuously</p>
        <div className="mt-3 h-1.5 w-full overflow-hidden rounded-full bg-border">
          <div className="h-full rounded-full bg-cyan" style={{ width: `${pct}%` }} />
        </div>
        <p className="mt-2 font-mono text-xs text-ink-dim">
          {String(elapsedMin).padStart(2, "0")}:{String(elapsedSec).padStart(2, "0")} / {reqMin}:00
        </p>
      </div>
    );
  }

  if (token.eligibility === "building") {
    return (
      <div className="rounded-md border border-border bg-surface p-5">
        <h3 className="font-display text-sm font-semibold text-ink">Not yet qualifying</h3>
        <p className="mt-1.5 text-xs text-ink-dim">
          {token.ticker} needs more real trading volume before its reserve crosses the threshold
          that starts the 30-minute qualifying window.
        </p>
      </div>
    );
  }

  if (token.eligibility === "too_new") {
    return (
      <div className="rounded-md border border-border bg-surface p-5">
        <h3 className="font-display text-sm font-semibold text-ink">Too new to qualify</h3>
        <p className="mt-1.5 text-xs text-ink-dim">
          A token becomes eligible to qualify starting the round after it launches.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">Included in a past draw</h3>
      <p className="mt-1.5 text-xs text-ink-dim">
        {token.ticker} must re-qualify through real activity to enter another draw.
      </p>
    </div>
  );
}
