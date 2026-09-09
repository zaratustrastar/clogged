import { Rocket, ArrowLeftRight } from "lucide-react";
import { LAUNCH_PRICE_ETH, TICKER_OWNER_FEE_PCT_OF_TRADE } from "@/lib/constants";

export function TwoWaysIn() {
  return (
    <section id="how-it-works" className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">
        Two ways in. One draw.
      </h2>

      <div className="mt-10 grid gap-4 lg:grid-cols-2">
        <div className="rounded-lg border border-border bg-surface p-6">
          <div className="flex h-9 w-9 items-center justify-center rounded-md bg-cyan/10 text-cyan">
            <Rocket size={18} strokeWidth={1.75} />
          </div>
          <h3 className="mt-4 font-display text-lg font-semibold text-ink">Launch</h3>
          <p className="mt-1 text-sm text-ink-dim">Create a meme. Claim its unique ticker.</p>
          <ul className="mt-4 flex flex-col gap-1.5 font-mono text-xs text-ink-dim">
            <li>{LAUNCH_PRICE_ETH} ETH launch fee</li>
            <li>0 liquidity required</li>
            <li>TickerNFT included</li>
            <li>{TICKER_OWNER_FEE_PCT_OF_TRADE}% ticker-owner fee</li>
          </ul>
        </div>

        <div className="rounded-lg border border-border bg-surface p-6">
          <div className="flex h-9 w-9 items-center justify-center rounded-md bg-violet/10 text-violet">
            <ArrowLeftRight size={18} strokeWidth={1.75} />
          </div>
          <h3 className="mt-4 font-display text-lg font-semibold text-ink">Trade</h3>
          <p className="mt-1 text-sm text-ink-dim">Buy any live meme. Hold or trade it.</p>
          <ul className="mt-4 flex flex-col gap-1.5 font-mono text-xs text-ink-dim">
            <li>Buying can move qualification</li>
            <li>No need to launch</li>
            <li>Winning holders share ETH</li>
          </ul>
        </div>
      </div>

      <div className="mx-auto mt-4 flex w-fit flex-col items-center">
        <span className="h-6 w-px bg-border" />
        <span className="text-ink-faint">↓</span>
      </div>

      <div className="mx-auto mt-2 flex max-w-md flex-col items-center gap-2">
        {["Qualified", "Hourly draw", "One winning meme", "Holders claim ETH"].map((step, i, arr) => (
          <div key={step} className="flex w-full flex-col items-center">
            <div
              className={`w-full rounded-md border px-4 py-2.5 text-center text-sm font-medium ${
                i === arr.length - 1
                  ? "border-gold/40 bg-gold/10 text-gold"
                  : "border-cyan/30 bg-cyan/5 text-cyan"
              }`}
            >
              {step.toUpperCase()}
            </div>
            {i < arr.length - 1 && <span className="py-1 text-ink-faint">↓</span>}
          </div>
        ))}
      </div>
    </section>
  );
}
