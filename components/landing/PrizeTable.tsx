import Link from "next/link";
import { prizeSkin } from "@/components/machine/Claw";

export type PrizeRow = {
  ticker: string;
  name: string;
  priceEth: string;        // pre-formatted
  change24h: number | null;
  curvePct: number;        // 0-100
  status: "QUALIFIED" | "QUALIFYING" | "BUILDING";
};

const LAMP = { QUALIFIED: "#7FD6A0", QUALIFYING: "#FFC61A", BUILDING: "#8F8C85" } as const;

const COLS = "grid grid-cols-[minmax(0,2.1fr)_minmax(0,1fr)_minmax(0,0.8fr)_minmax(0,1.4fr)_minmax(0,1.2fr)] gap-px";

/** Section 3 of 4. Desktop: 5 legible columns. Under 768px: prize cards, not horizontal scroll.
 *  Rows are real Links (fix F3) — keyboard reachable, middle-clickable, client navigation.
 *  Volume stays out until it is actually indexed (issue P2). */
export function PrizeTable({ rows }: { rows: PrizeRow[] }) {
  return (
    <section id="prizes" className="flex flex-col gap-4 py-11">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="m-0 font-display text-[clamp(24px,3.2vw,34px)] tracking-[-0.02em]">In the machine now</h2>
          <p className="mt-1.5 text-[14.5px] text-ink-400">Live tickers and where each one stands with the round.</p>
        </div>
        <Link href="/explore" className="border border-edge-hard bg-chassis-600 px-3.5 py-2.5 font-mono text-meta text-ink-100">
          ALL TICKERS →
        </Link>
      </div>

      {/* desktop */}
      <div className="hidden overflow-hidden border border-edge-soft bg-chassis-800 md:block">
        <div className={`${COLS} bg-edge-inner font-mono text-label text-ink-500`}>
          <div className="bg-chassis-600 px-4 py-2.5">TICKER</div>
          <div className="bg-chassis-600 px-4 py-2.5 text-right">PRICE</div>
          <div className="bg-chassis-600 px-4 py-2.5 text-right">24H</div>
          <div className="bg-chassis-600 px-4 py-2.5">CURVE PROGRESS</div>
          <div className="bg-chassis-600 px-4 py-2.5">DRAW STATUS</div>
        </div>
        {rows.map((r) => (
          <Link key={r.ticker} href={`/token/${r.ticker.replace(/^\$/, "")}`} className={`${COLS} bg-edge-inner no-underline hover:bg-edge-hard`}>
            <div className="flex min-w-0 items-center gap-3 bg-chassis-800 px-4 py-3.5">
              <span aria-hidden className="h-[30px] w-[30px] flex-none rounded-lg" style={{ background: prizeSkin(r.ticker) }} />
              <span className="min-w-0">
                <span className="clog-fig block text-[13.5px] text-ink-100">{r.ticker}</span>
                <span className="block truncate text-[11.5px] text-ink-500">{r.name}</span>
              </span>
            </div>
            <div className="clog-fig bg-chassis-800 px-4 py-3.5 text-right text-[13px] text-ink-100">{r.priceEth}</div>
            <div className={`clog-fig bg-chassis-800 px-4 py-3.5 text-right text-[13px] ${(r.change24h ?? 0) < 0 ? "text-bad" : "text-ok"}`}>
              {r.change24h == null ? "—" : `${r.change24h > 0 ? "+" : ""}${r.change24h.toFixed(1)}%`}
            </div>
            <div className="flex min-w-0 items-center gap-2.5 bg-chassis-800 px-4 py-3.5">
              <span className="h-[5px] min-w-0 flex-1 overflow-hidden bg-edge-inner">
                <span className="block h-full bg-amber" style={{ width: `${r.curvePct}%` }} />
              </span>
              <span className="clog-fig text-[11.5px] text-ink-400">{r.curvePct}%</span>
            </div>
            <div className="flex min-w-0 items-center gap-2 bg-chassis-800 px-4 py-3.5">
              <span aria-hidden className="h-2.5 w-2.5 flex-none rounded-full" style={{ background: LAMP[r.status], boxShadow: `0 0 8px ${LAMP[r.status]}` }} />
              <span className="font-mono text-meta" style={{ color: LAMP[r.status] }}>{r.status}</span>
            </div>
          </Link>
        ))}
      </div>

      {/* mobile: prize cards */}
      <div className="flex flex-col gap-2 md:hidden">
        {rows.map((r) => (
          <Link key={r.ticker} href={`/token/${r.ticker.replace(/^\$/, "")}`} className="flex items-center gap-3 border border-edge-soft bg-chassis-800 p-3.5 no-underline">
            <span aria-hidden className="h-11 w-11 flex-none rounded-xl" style={{ background: prizeSkin(r.ticker) }} />
            <span className="min-w-0 flex-1">
              <span className="flex items-baseline justify-between gap-2">
                <span className="clog-fig text-[14px] text-ink-100">{r.ticker}</span>
                <span className="clog-fig text-[14px] text-ink-100">{r.priceEth}</span>
              </span>
              <span className="mt-0.5 flex items-center justify-between gap-2">
                <span className="flex items-center gap-1.5 font-mono text-[10px]" style={{ color: LAMP[r.status] }}>
                  <span aria-hidden className="h-2 w-2 rounded-full" style={{ background: LAMP[r.status] }} />
                  {r.status} · {r.curvePct}%
                </span>
                <span className={`clog-fig text-[12px] ${(r.change24h ?? 0) < 0 ? "text-bad" : "text-ok"}`}>
                  {r.change24h == null ? "—" : `${r.change24h > 0 ? "+" : ""}${r.change24h.toFixed(1)}%`}
                </span>
              </span>
            </span>
          </Link>
        ))}
      </div>
    </section>
  );
}
