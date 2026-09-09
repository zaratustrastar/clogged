import { ProgressBar } from "@/components/ui/ProgressBar";
import { formatCompact } from "@/lib/format";
import type { TokenDetail } from "@/lib/types";

export function ClogMechanicsPanel({ token }: { token: TokenDetail }) {
  const clogUsedPct =
    ((token.clogAllocation - token.clogRemainingTokens) / token.clogAllocation) * 100;

  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">CLOG reserve</h3>
      <p className="mt-1 text-xs text-ink-dim">
        A share of every trade tops up this token&apos;s reserve, which backs the hourly draw and
        deepens the market over time.
      </p>

      <div className="mt-4 flex justify-between text-xs text-ink-dim">
        <span>Starting reserve</span>
        <span className="font-mono text-ink">
          {formatCompact(token.clogAllocation)} {token.ticker}
        </span>
      </div>
      <div className="mt-1.5 flex justify-between text-xs text-ink-dim">
        <span>Remaining</span>
        <span className="font-mono text-ink">
          {formatCompact(token.clogRemainingTokens)} {token.ticker}
        </span>
      </div>
      <div className="mt-2">
        <ProgressBar pct={clogUsedPct} tone="gold" />
      </div>

      <div className="mt-4 flex justify-between text-xs text-ink-dim">
        <span>Curve progress (high-water mark)</span>
        <span className="font-mono text-ink">{token.curveProgressPct}%</span>
      </div>
      <div className="mt-2">
        <ProgressBar pct={token.curveProgressPct} />
      </div>
    </div>
  );
}
