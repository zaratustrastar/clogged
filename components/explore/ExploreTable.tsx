"use client";

import Link from "next/link";
import { prizeSkin } from "@/components/machine/Claw";
import { NoSignal, EmptyChute } from "@/components/machine/States";

export type ExploreRow = {
  ticker: string;          // with leading $
  name: string;
  priceEth: string;        // pre-formatted, unit included
  change1h: number | null;
  change24h: number | null;
  curvePct: number;
  marketCapEth: string;    // pre-formatted
  status: "QUALIFIED" | "QUALIFYING" | "BUILDING";
};

const LAMP = { QUALIFIED: "#7FD6A0", QUALIFYING: "#FFC61A", BUILDING: "#8F8C85" } as const;

/* Figure columns carry explicit px floors and nowrap: a price string must never break
 * across two lines or clip mid-glyph, at any container width. Under 768px the table
 * becomes prize cards rather than a horizontally-scrolling grid.
 * Rows are real Links (fix F3). Volume is omitted entirely until it is indexed. */
const COLS =
  "grid grid-cols-[minmax(0,2fr)_minmax(136px,1fr)_minmax(80px,0.6fr)_minmax(80px,0.6fr)_minmax(124px,1.2fr)_minmax(124px,1fr)_minmax(124px,1fr)] gap-px";

const FIG = "clog-fig whitespace-nowrap bg-chassis-800 px-3.5 py-3.5 text-right text-[12.5px]";

function pct(v: number | null) {
  return v == null ? "—" : `${v > 0 ? "+" : ""}${v.toFixed(1)}%`;
}
function pctClass(v: number | null) {
  return v == null ? "text-ink-500" : v < 0 ? "text-bad" : "text-ok";
}
function href(ticker: string) {
  return `/token/${ticker.replace(/^\$/, "")}`;
}

export function ExploreTable({
  rows,
  isLoading,
  query,
}: {
  rows: ExploreRow[];
  isLoading?: boolean;
  query?: string;
}) {
  if (isLoading) return <NoSignal lines={6} />;

  if (!rows.length) {
    return (
      <div className="border border-dashed border-edge-hard bg-chassis-800 p-11">
        <EmptyChute
          label={query ? `NOTHING MATCHES "${query.toUpperCase()}"` : "NO TICKERS YET"}
          body="The slot is empty. Launch it before someone else does."
        >
          <Link href="/launch" className="mt-1 font-mono text-meta text-amber">LAUNCH THIS TICKER →</Link>
        </EmptyChute>
      </div>
    );
  }

  return (
    <>
      <div className="hidden overflow-hidden border border-edge-soft bg-chassis-800 md:block">
        <div className={`${COLS} bg-edge-inner font-mono text-label text-ink-500`}>
          <div className="bg-chassis-600 px-3.5 py-2.5">TICKER</div>
          <div className="bg-chassis-600 px-3.5 py-2.5 text-right">PRICE</div>
          <div className="bg-chassis-600 px-3.5 py-2.5 text-right">1H</div>
          <div className="bg-chassis-600 px-3.5 py-2.5 text-right">24H</div>
          <div className="bg-chassis-600 px-3.5 py-2.5">CURVE</div>
          <div className="bg-chassis-600 px-3.5 py-2.5 text-right">MARKET CAP</div>
          <div className="bg-chassis-600 px-3.5 py-2.5">DRAW STATUS</div>
        </div>
        {rows.map((r) => (
          <Link key={r.ticker} href={href(r.ticker)} className={`${COLS} bg-edge-inner no-underline hover:bg-edge-hard`}>
            <span className="flex min-w-0 items-center gap-3 bg-chassis-800 px-3.5 py-3.5">
              <span aria-hidden className="h-[30px] w-[30px] flex-none rounded-lg" style={{ background: prizeSkin(r.ticker) }} />
              <span className="min-w-0">
                <span className="clog-fig block text-[13.5px] text-ink-100">{r.ticker}</span>
                <span className="block truncate text-[11.5px] text-ink-500">{r.name}</span>
              </span>
            </span>
            <span className={`${FIG} text-ink-100`}>{r.priceEth}</span>
            <span className={`${FIG} ${pctClass(r.change1h)}`}>{pct(r.change1h)}</span>
            <span className={`${FIG} ${pctClass(r.change24h)}`}>{pct(r.change24h)}</span>
            <span className="flex min-w-0 items-center gap-2.5 bg-chassis-800 px-3.5 py-3.5">
              <span className="h-[5px] min-w-0 flex-1 overflow-hidden bg-edge-inner">
                <span className="block h-full bg-amber" style={{ width: `${r.curvePct}%` }} />
              </span>
              <span className="clog-fig whitespace-nowrap text-[11px] text-ink-400">{r.curvePct}%</span>
            </span>
            <span className={`${FIG} text-ink-100`}>{r.marketCapEth}</span>
            <span className="flex min-w-0 items-center gap-2 bg-chassis-800 px-3.5 py-3.5">
              <span aria-hidden className="h-2.5 w-2.5 flex-none rounded-full" style={{ background: LAMP[r.status], boxShadow: `0 0 8px ${LAMP[r.status]}` }} />
              <span className="whitespace-nowrap font-mono text-[10.5px]" style={{ color: LAMP[r.status] }}>{r.status}</span>
            </span>
          </Link>
        ))}
      </div>

      <div className="flex flex-col gap-2 md:hidden">
        {rows.map((r) => (
          <Link key={r.ticker} href={href(r.ticker)} className="flex items-center gap-3 border border-edge-soft bg-chassis-800 p-3.5 no-underline">
            <span aria-hidden className="h-11 w-11 flex-none rounded-xl" style={{ background: prizeSkin(r.ticker) }} />
            <span className="flex min-w-0 flex-1 flex-col gap-1.5">
              <span className="flex items-baseline justify-between gap-2.5">
                <span className="clog-fig text-sm text-ink-100">{r.ticker}</span>
                <span className="clog-fig whitespace-nowrap text-[13.5px] text-ink-100">{r.priceEth}</span>
              </span>
              <span className="flex items-center justify-between gap-2.5">
                <span className="flex min-w-0 items-center gap-1.5 whitespace-nowrap font-mono text-[10.5px]" style={{ color: LAMP[r.status] }}>
                  <span aria-hidden className="h-2 w-2 flex-none rounded-full" style={{ background: LAMP[r.status] }} />
                  {r.status} · {r.curvePct}%
                </span>
                <span className={`clog-fig whitespace-nowrap text-xs ${pctClass(r.change24h)}`}>{pct(r.change24h)}</span>
              </span>
            </span>
          </Link>
        ))}
      </div>
    </>
  );
}
