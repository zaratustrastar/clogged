import { formatCompact, formatEth, formatPct } from "@/lib/format";
import type { TokenDetail } from "@/lib/types";

export function MarketInfo({ token }: { token: TokenDetail }) {
  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="text-xs text-ink-faint">Price</p>
          <p className="mt-1 font-mono text-2xl tabular text-ink">{token.priceEth.toFixed(7)} ETH</p>
        </div>
        <div className="flex gap-6 text-right">
          <div>
            <p className="text-xs text-ink-faint">1H</p>
            <p
              className={`font-mono text-sm ${
                (token.change1hPct ?? 0) >= 0 ? "text-cyan" : "text-danger"
              }`}
            >
              {formatPct(token.change1hPct)}
            </p>
          </div>
          <div>
            <p className="text-xs text-ink-faint">24H</p>
            <p
              className={`font-mono text-sm ${
                (token.change24hPct ?? 0) >= 0 ? "text-cyan" : "text-danger"
              }`}
            >
              {formatPct(token.change24hPct)}
            </p>
          </div>
        </div>
      </div>

      <div className="mt-5 flex h-56 items-center justify-center rounded border border-dashed border-border text-xs text-ink-faint">
        Price chart — connects once trade history is indexed
      </div>

      <div className="mt-5 grid grid-cols-2 gap-4 border-t border-border pt-4 sm:grid-cols-4">
        <Stat label="Market cap" value={`${formatCompact(token.marketCapEth)} ETH`} />
        <Stat label="24H volume" value={`${formatCompact(token.volume24hEth)} ETH`} />
        <Stat label="Reserve" value={`${formatEth(token.realReserveEth, { decimals: 2 })}`} />
        <Stat label="Curve progress" value={`${token.curveProgressPct}%`} />
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-ink-faint">{label}</p>
      <p className="mt-0.5 font-mono text-sm text-ink">{value}</p>
    </div>
  );
}
