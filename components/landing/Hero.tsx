"use client";

import Link from "next/link";
import { useReadContract } from "wagmi";
import { Button } from "@/components/ui/Button";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { CountdownClock } from "@/components/ui/CountdownClock";
import { Skeleton } from "@/components/ui/Skeleton";
import { useTokenList, useRoundStatus } from "@/lib/hooks/useTokenData";
import { formatEth } from "@/lib/format";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { MIN_DRAW_CANDIDATES } from "@/lib/constants";

export function Hero() {
  const { data: tokens } = useTokenList();
  const { data: round } = useRoundStatus();
  const allQualified = (tokens ?? []).filter((t) => t.eligibility === "qualified");
  const preview = allQualified.slice(0, 4);

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });
  const jackpotEth = unallocatedPool !== undefined ? Number(unallocatedPool) / 1e18 : null;

  const yourOddsIfJoin = allQualified.length + 1;

  return (
    <section className="relative overflow-hidden border-b border-border">
      <div className="content-container relative grid gap-10 py-16 lg:grid-cols-[1.05fr_0.95fr] lg:gap-16 lg:py-24">
        <div className="flex flex-col justify-center">
          <span className="mb-4 inline-flex w-fit items-center gap-1.5 rounded-full border border-cyan/30 bg-cyan/10 px-3 py-1 text-xs font-medium text-cyan">
            <span className="h-1.5 w-1.5 animate-glow-pulse rounded-full bg-cyan" />
            A new round draws every hour
          </span>
          <h1 className="font-display text-4xl font-semibold leading-[1.06] tracking-tight text-ink sm:text-5xl lg:text-[3.4rem]">
            Launch a meme.
            <br />
            Own the ticker.
            <br />
            <span className="text-cyan">Play for the jackpot.</span>
          </h1>
          <div className="mt-5 flex max-w-md flex-col gap-1.5 text-base leading-relaxed text-ink-dim">
            <p>Every hour, qualified memes enter one onchain draw.</p>
            <p>If your meme gets in, it has one equal chance to win.</p>
            <p>
              If it wins, holders split the <span className="text-gold">ETH jackpot</span>.
            </p>
          </div>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link href="/launch">
              <Button size="lg" className="shadow-glow-cyan">
                Launch token
              </Button>
            </Link>
            <a href="#how-it-works">
              <Button size="lg" variant="secondary">
                How it works
              </Button>
            </a>
            <Link href="/explore" className="text-sm font-medium text-ink-dim hover:text-cyan">
              Explore memes →
            </Link>
          </div>
        </div>

        <div className="animate-soft-rise">
          <div className="mb-3 flex items-center justify-between">
            <span className="flex items-center gap-1.5 text-xs font-medium tracking-wide text-ink-dim">
              <span className="h-1.5 w-1.5 animate-glow-pulse rounded-full bg-cyan" />
              NEXT DRAW
            </span>
            <Link href="/explore?tab=next-draw" className="text-xs font-medium text-cyan hover:underline">
              See all
            </Link>
          </div>

          <div className="rounded-lg border border-border bg-surface shadow-glow-cyan/10">
            <div className="flex items-center justify-between border-b border-border px-4 py-3.5">
              <div>
                <p className="text-[11px] uppercase tracking-wide text-ink-faint">Jackpot</p>
                <p className="font-mono text-xl font-semibold text-gold">
                  {jackpotEth === null ? "—" : formatEth(jackpotEth, { decimals: 2 })}
                </p>
              </div>
              <div className="text-right">
                <p className="text-[11px] uppercase tracking-wide text-ink-faint">Closes in</p>
                {round ? (
                  <CountdownClock targetIso={round.closesAt} size="md" />
                ) : (
                  <Skeleton className="h-6 w-16" />
                )}
              </div>
            </div>

            <div className="flex items-center justify-between border-b border-border px-4 py-2.5 text-xs">
              <span className="text-ink-dim">
                <span className="font-mono tabular text-cyan">{tokens ? allQualified.length : "—"}</span> memes
                qualified
              </span>
              <span className="text-ink-faint">min {MIN_DRAW_CANDIDATES} to draw</span>
            </div>

            <ul className="divide-y divide-border">
              {tokens && preview.length === 0 && (
                <li className="px-4 py-6 text-center text-sm text-ink-dim">
                  No memes have qualified yet this round.
                </li>
              )}
              {preview.map((t) => (
                <li key={t.tokenId}>
                  <Link
                    href={`/token/${t.ticker.toLowerCase()}`}
                    className="group flex items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-raised"
                  >
                    <TokenIcon ticker={t.ticker} />
                    <div className="min-w-0 flex-1">
                      <div className="flex items-baseline gap-1.5">
                        <span className="truncate text-sm font-medium text-ink">{t.name}</span>
                        <span className="text-xs text-ink-faint">{t.ticker}</span>
                      </div>
                      <div className="mt-1 flex items-center gap-1.5">
                        <ProgressBar pct={t.curveProgressPct} />
                        <span className="shrink-0 font-mono text-[10px] text-ink-faint">
                          {t.curveProgressPct.toFixed(0)}%
                        </span>
                      </div>
                    </div>
                    <span className="shrink-0 rounded-full bg-cyan/15 px-2 py-1 text-[11px] font-medium text-cyan transition-transform group-hover:scale-105">
                      Qualified
                    </span>
                  </Link>
                </li>
              ))}
            </ul>

            {tokens && (
              <div className="border-t border-border bg-surface-raised/60 px-4 py-3 text-center">
                <p className="text-xs text-ink-dim">
                  Join now:{" "}
                  <span className="font-mono font-semibold text-ink">1 in {yourOddsIfJoin}</span> if
                  your meme qualifies before the draw
                </p>
              </div>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}
