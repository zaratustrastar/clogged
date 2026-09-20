"use client";

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import { useMemo, useState } from "react";
import { ExploreTable, type ExploreRow } from "@/components/explore/ExploreTable";
import { ErrorPlate } from "@/components/machine/States";
import { useTokenDiscovery } from "@/lib/hooks/useTokenDiscovery";
import { formatEthPrecise } from "@/lib/format";
import type { EligibilityStage } from "@/lib/types";

const TABS = [
  { id: "trending", label: "TRENDING", note: "SORTED BY MARKET CAP" },
  { id: "next", label: "NEXT DRAW", note: "QUALIFIED + QUALIFYING ONLY" },
  { id: "new", label: "NEW", note: "NEWEST FIRST" },
] as const;

/* Same reads as today. Changes are presentational + honesty:
 *  - "Trending" states that it sorts by market cap instead of implying momentum (P2)
 *  - the always-zero Volume column is gone until it is indexable (P2)
 *  - rows are Links, keyboard reachable (P2/F3)
 *  - a failed read renders an error plate, never an empty table
 *
 * Runbook §0: useTokenDiscovery's import path/name both match reality exactly.
 * Its real return (a plain react-query result: {data: TokenSummary[] | undefined,
 * isLoading, error, refetch}) is NOT the same shape as ExploreRow at all - the
 * handoff's own `discovery.data as ExploreRow[]` cast would have compiled (an
 * unsafe `as`) but rendered wrong/undefined fields for every row. Mapped for
 * real below, at this page's edge - see toExploreStatus, matching the same
 * 5-stage EligibilityStage -> 3-lamp collapse used on the landing page
 * (app/page.tsx's toPrizeStatus), documented there. */
function toExploreStatus(stage: EligibilityStage): "QUALIFIED" | "QUALIFYING" | "BUILDING" {
  if (stage === "qualified") return "QUALIFIED";
  if (stage === "qualifying" || stage === "ready") return "QUALIFYING";
  return "BUILDING";
}

function ExploreContent() {
  const params = useSearchParams();
  const [tab, setTab] = useState<(typeof TABS)[number]["id"]>("trending");
  const [query, setQuery] = useState(params.get("q") ?? "");

  const discovery = useTokenDiscovery();

  const rows: ExploreRow[] = useMemo(() => {
    const all: ExploreRow[] = (discovery.data ?? []).map((t) => ({
      ticker: `$${t.ticker}`,
      name: t.name,
      imageUrl: t.imageUrl,
      priceEth: `${formatEthPrecise(t.priceEth)} ETH`,
      change1h: t.change1hPct,
      change24h: t.change24hPct,
      curvePct: t.curveProgressPct,
      marketCapEth: `${formatEthPrecise(t.marketCapEth)} ETH`,
      status: toExploreStatus(t.eligibility),
    }));
    const q = query.trim().toUpperCase();
    let out = q
      ? all.filter((r) => r.ticker.toUpperCase().includes(q) || r.name.toUpperCase().includes(q))
      : all.slice();
    if (tab === "next") out = out.filter((r) => r.status !== "BUILDING");
    if (tab === "new") out.reverse();
    return out;
  }, [discovery.data, query, tab]);

  const note = TABS.find((t) => t.id === tab)!.note;

  return (
    <div className="mx-auto flex max-w-[1240px] flex-col gap-[18px] px-5 pb-24 pt-7">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="m-0 font-display text-[clamp(26px,3.6vw,38px)] tracking-[-0.025em]">
            Everything in the machine
          </h1>
          <p className="mt-1.5 text-[14.5px] text-ink-400">
            {discovery.data ? `${discovery.data.length} live tickers` : "Loading tickers"}
          </p>
        </div>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="search ticker or name"
          aria-label="Search tickers"
          className="min-w-0 flex-[0_1_280px] border border-edge-hair bg-chassis-800 px-3.5 py-3 text-[13px] text-ink-100 outline-none placeholder:text-ink-600"
        />
      </header>

      <div className="flex flex-wrap items-center gap-1.5 border-b border-edge-hair pb-0.5">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            aria-pressed={tab === t.id}
            className={`border-0 bg-transparent px-3 py-2.5 font-mono text-meta ${
              tab === t.id ? "border-b-2 border-amber text-amber" : "text-ink-500"
            }`}
          >
            {t.label}
          </button>
        ))}
        <div className="flex-1 basis-5" />
        <span className="self-center font-mono text-label text-ink-600">{note}</span>
      </div>

      {discovery.error ? (
        <ErrorPlate
          title="Could not load tickers"
          detail={discovery.error.message}
          onRetry={() => discovery.refetch()}
        />
      ) : (
        <ExploreTable rows={rows} isLoading={discovery.isLoading} query={query} />
      )}
    </div>
  );
}

// Next.js 14 requires any component calling useSearchParams() to be wrapped
// in a Suspense boundary (confirmed directly: `next build` fails
// prerendering this page outright without it - "useSearchParams() should be
// wrapped in a suspense boundary"). The fallback below has no protocol data
// of its own to show, so it renders the same honest, empty-content shell
// the real page would show while discovery is still loading - never a
// placeholder number.
export default function ExplorePage() {
  return (
    <Suspense fallback={<div className="mx-auto max-w-[1240px] px-5 pb-24 pt-7" />}>
      <ExploreContent />
    </Suspense>
  );
}
