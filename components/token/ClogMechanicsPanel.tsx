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
        100M of the 1B supply sits in reserve. A share of every trade tops it up, and CLOG only
        releases new tokens when the curve reaches genuinely new territory — not just any trade.
      </p>

      <div className="mt-3 rounded border border-border bg-surface-raised px-3 py-2 text-xs text-ink-dim">
        <div className="flex items-center gap-1.5">
          <span className="text-ink">Previous high: 20%</span>
          <span className="text-ink-faint">→</span>
          <span>Falls to 14%</span>
        </div>
        <div className="mt-1 flex items-center gap-1.5">
          <span>14% → 20%</span>
          <span className="text-ink-faint">·</span>
          <span className="text-ink-faint">No new CLOG (already-reached territory)</span>
        </div>
        <div className="mt-1 flex items-center gap-1.5">
          <span className="text-cyan">20% → 21%</span>
          <span className="text-ink-faint">·</span>
          <span className="text-cyan">New territory — CLOG activates</span>
        </div>
      </div>

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
        <span>Curve progress</span>
        <span className="font-mono text-ink">{token.curveProgressPct.toFixed(1)}%</span>
      </div>
      <div className="mt-2">
        <ProgressBar pct={token.curveProgressPct} />
      </div>
    </div>
  );
}
