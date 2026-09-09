import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { DrawChamber } from "@/components/landing/DrawChamber";

export function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-border">
      <div className="content-container relative grid gap-14 py-16 lg:grid-cols-[1.05fr_0.95fr] lg:gap-10 lg:py-24">
        <div className="flex flex-col justify-center">
          <span className="mb-5 inline-flex w-fit items-center gap-1.5 text-xs font-medium tracking-[0.14em] text-cyan">
            <span className="h-1.5 w-1.5 animate-glow-pulse rounded-full bg-cyan" />
            ONE DRAW EVERY HOUR
          </span>
          <h1 className="font-display text-4xl font-semibold leading-[1.08] tracking-tight text-ink sm:text-5xl lg:text-[3.3rem]">
            Launch one.
            <br />
            Back one.
            <br />
            One draw every hour.
          </h1>
          <div className="mt-6 flex max-w-md flex-col gap-1.5 text-base leading-relaxed text-ink-dim">
            <p>Qualified memes enter with equal odds.</p>
            <p>If one wins, its holders split the ETH jackpot.</p>
          </div>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link href="/launch">
              <Button size="lg">Launch a meme</Button>
            </Link>
            <Link href="/explore">
              <Button size="lg" variant="secondary">
                Explore memes
              </Button>
            </Link>
          </div>
          <p className="mt-6 text-xs text-ink-faint">Tickers are unique inside CLOG.</p>
        </div>

        <DrawChamber />
      </div>
    </section>
  );
}
