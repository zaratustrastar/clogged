"use client";

import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { EligibilityBadge } from "@/components/ui/EligibilityBadge";
import { CountdownClock } from "@/components/ui/CountdownClock";
import { Skeleton } from "@/components/ui/Skeleton";
import { useTokenList, useRoundStatus } from "@/lib/hooks/useTokenData";
import { formatCompact } from "@/lib/format";

export function Hero() {
  const { data: tokens } = useTokenList();
  const { data: round } = useRoundStatus();
  const allQualified = (tokens ?? []).filter((t) => t.eligibility === "qualified");
  const preview = allQualified.slice(0, 4);

  return (
    <section className="border-b border-border bg-surface/40">
      <div className="content-container grid gap-10 py-14 lg:grid-cols-[1.1fr_0.9fr] lg:gap-16 lg:py-20">
        <div className="flex flex-col justify-center">
          <h1 className="font-display text-4xl font-semibold leading-[1.08] tracking-tight text-ink sm:text-5xl">
            Launch a meme.
            <br />
            Own the ticker.
            <br />
            Win the hour.
          </h1>
          <p className="mt-5 max-w-md text-base leading-relaxed text-ink-dim">
            Claim one of 7,777 unique CLOG tickers. Reach 5% curve progress and keep at least 0.229
            ETH of real reserve for 30 minutes to enter the hourly draw. Every qualified meme gets one
            equal chance — winning holders split the ETH jackpot.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link href="/launch">
              <Button size="lg">Launch token</Button>
            </Link>
            <Link href="/explore">
              <Button size="lg" variant="secondary">
                Explore tokens →
              </Button>
            </Link>
          </div>
        </div>

        <div>
          <div className="mb-3 flex items-center justify-between">
            <span className="text-xs font-medium tracking-wide text-ink-dim">IN THE NEXT DRAW</span>
            <Link href="/explore?tab=next-draw" className="text-xs font-medium text-cyan hover:underline">
              See all
            </Link>
          </div>

          <div className="rounded-md border border-border bg-surface">
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
              <span className="text-sm text-ink-dim">
                <span className="font-mono tabular text-ink">{tokens ? allQualified.length : "—"}</span> memes
                qualified
              </span>
              {round ? (
                <CountdownClock targetIso={round.closesAt} size="md" />
              ) : (
                <Skeleton className="h-6 w-16" />
              )}
            </div>

            <ul className="divide-y divide-border">
              {tokens && preview.length === 0 && (
                <li className="px-4 py-6 text-center text-sm text-ink-dim">
                  No tokens have qualified yet this round.
                </li>
              )}
              {preview.map((t) => (
                <li key={t.tokenId}>
                  <Link
                    href={`/token/${t.ticker.toLowerCase()}`}
                    className="flex items-center gap-3 px-4 py-3 hover:bg-surface-raised"
                  >
                    <TokenIcon ticker={t.ticker} />
                    <div className="min-w-0 flex-1">
                      <div className="flex items-baseline gap-1.5">
                        <span className="truncate text-sm font-medium text-ink">{t.name}</span>
                        <span className="text-xs text-ink-faint">{t.ticker}</span>
                      </div>
                      <span className="text-xs text-ink-dim">{formatCompact(t.marketCapEth)} ETH mcap</span>
                    </div>
                    <EligibilityBadge stage={t.eligibility} compact />
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>
    </section>
  );
}
