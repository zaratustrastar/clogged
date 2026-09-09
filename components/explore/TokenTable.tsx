"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState } from "@/components/ui/EmptyState";
import { useTokenList } from "@/lib/hooks/useTokenData";
import { formatAddress, formatCompact, formatDate, formatPct } from "@/lib/format";
import { REQUIRED_STREAK_SECONDS } from "@/lib/constants";
import type { TokenSummary } from "@/lib/types";
import clsx from "clsx";

type Tab = "trending" | "next-draw" | "new";

const TABS: { id: Tab; label: string }[] = [
  { id: "trending", label: "Trending" },
  { id: "next-draw", label: "Next draw" },
  { id: "new", label: "New" },
];

function sortForTab(tokens: TokenSummary[], tab: Tab): TokenSummary[] {
  const copy = [...tokens];
  // Real, derivable ranking only: market cap. 24h volume isn't safely
  // derivable yet (see useTokenDiscovery), so "Trending" ranks by market
  // cap rather than a field that's currently always zero for every token.
  if (tab === "trending") return copy.sort((a, b) => b.marketCapEth - a.marketCapEth);
  if (tab === "next-draw")
    return copy
      .filter((t) => t.eligibility === "qualified" || t.eligibility === "qualifying" || t.eligibility === "ready")
      .sort((a, b) => (b.eligibleSinceSeconds ?? 0) - (a.eligibleSinceSeconds ?? 0));
  return copy.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
}

function PctCell({ value }: { value: number | null }) {
  if (value === null) return <span className="text-ink-faint">—</span>;
  return (
    <span className={value > 0 ? "text-cyan" : value < 0 ? "text-danger" : "text-ink-dim"}>
      {formatPct(value)}
    </span>
  );
}

function DrawCell({ token }: { token: TokenSummary }) {
  if (token.eligibility === "qualified") {
    return <span className="text-xs font-medium text-cyan">Qualified</span>;
  }
  if (token.eligibility === "ready") {
    return <span className="text-xs font-medium text-gold">Ready</span>;
  }
  if (token.eligibility === "qualifying" && token.eligibleSinceSeconds !== null) {
    const elapsed = Math.floor(Date.now() / 1000) - token.eligibleSinceSeconds;
    const remaining = Math.max(0, REQUIRED_STREAK_SECONDS - elapsed);
    const m = Math.floor(remaining / 60);
    return <span className="text-xs text-ink-dim">{m}m left</span>;
  }
  if (token.eligibility === "drawn") {
    return <span className="text-xs text-ink-faint">Past draw</span>;
  }
  return (
    <span className="text-xs text-ink-faint">
      {token.curveProgressPct.toFixed(1)} / 5%
    </span>
  );
}

export function TokenTable({
  initialTab = "trending",
  searchQuery = "",
  showTabs = true,
  limit,
}: {
  initialTab?: Tab;
  searchQuery?: string;
  showTabs?: boolean;
  limit?: number;
}) {
  const [tab, setTab] = useState<Tab>(initialTab);
  const { data: tokens, isLoading } = useTokenList();

  const rows = useMemo(() => {
    if (!tokens) return [];
    const q = searchQuery.trim().toLowerCase();
    const filtered = q
      ? tokens.filter((t) => t.ticker.toLowerCase().includes(q) || t.name.toLowerCase().includes(q))
      : tokens;
    const sorted = sortForTab(filtered, tab);
    return limit ? sorted.slice(0, limit) : sorted;
  }, [tokens, tab, searchQuery, limit]);

  return (
    <div>
      {showTabs && (
        <div className="mb-4 flex items-center gap-2">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={clsx(
                "rounded px-3 py-1.5 text-sm font-medium transition-colors",
                tab === t.id ? "bg-cyan/15 text-cyan" : "text-ink-dim hover:text-ink"
              )}
            >
              {t.label}
            </button>
          ))}
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-border">
        <table className="w-full min-w-[760px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-ink-faint">
              <th className="px-4 py-3 font-medium">Token</th>
              <th className="px-4 py-3 font-medium">Creator</th>
              <th className="px-4 py-3 font-medium">Created</th>
              <th className="px-4 py-3 text-right font-medium">1H</th>
              <th className="px-4 py-3 text-right font-medium">24H</th>
              <th className="px-4 py-3 font-medium">Curve</th>
              <th className="px-4 py-3 text-right font-medium">Volume</th>
              <th className="px-4 py-3 text-right font-medium">Mcap</th>
              <th className="px-4 py-3 text-right font-medium">Draw</th>
            </tr>
          </thead>
          <tbody>
            {isLoading &&
              Array.from({ length: 5 }).map((_, i) => (
                <tr key={i} className="border-b border-border last:border-0">
                  <td className="px-4 py-3" colSpan={9}>
                    <Skeleton className="h-6 w-full" />
                  </td>
                </tr>
              ))}

            {!isLoading &&
              rows.map((t) => (
                <tr
                  key={t.tokenId}
                  className="cursor-pointer border-b border-border last:border-0 hover:bg-surface"
                  onClick={() => (window.location.href = `/token/${t.ticker.toLowerCase()}`)}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/token/${t.ticker.toLowerCase()}`}
                      className="flex items-center gap-2.5"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <TokenIcon ticker={t.ticker} size={28} />
                      <div className="min-w-0">
                        <div className="truncate text-sm font-medium text-ink">{t.name}</div>
                        <div className="text-xs text-ink-faint">{t.ticker}</div>
                      </div>
                    </Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs text-ink-dim">{formatAddress(t.creator)}</td>
                  <td className="px-4 py-3 text-xs text-ink-dim">{formatDate(t.createdAt)}</td>
                  <td className="px-4 py-3 text-right font-mono tabular text-xs">
                    <PctCell value={t.change1hPct} />
                  </td>
                  <td className="px-4 py-3 text-right font-mono tabular text-xs">
                    <PctCell value={t.change24hPct} />
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex w-24 items-center gap-2">
                      <ProgressBar pct={t.curveProgressPct} />
                      <span className="font-mono text-xs text-ink-faint">{t.curveProgressPct.toFixed(1)}%</span>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                    {t.volume24hEth > 0 ? `${formatCompact(t.volume24hEth)} ETH` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-mono tabular text-xs font-medium text-ink">
                    {formatCompact(t.marketCapEth)} ETH
                  </td>
                  <td className="px-4 py-3 text-right">
                    <DrawCell token={t} />
                  </td>
                </tr>
              ))}
          </tbody>
        </table>

        {!isLoading && rows.length === 0 && (
          <EmptyState
            title="No tokens match"
            description={
              searchQuery
                ? `Nothing found for "${searchQuery}". Try a different ticker or name.`
                : "No tokens in this view yet."
            }
          />
        )}
      </div>
    </div>
  );
}
