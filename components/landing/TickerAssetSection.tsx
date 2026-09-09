import { TICKER_OWNER_FEE_PCT_OF_TRADE, PROTOCOL_FEE_PCT_OF_TRADE, WINNER_POT_FEE_PCT_OF_TRADE, TRADE_TAX_PCT } from "@/lib/constants";

const FLOW = ["$CAT", "Unique inside CLOG", "Minted as a TickerNFT", "Tradable on OpenSea", "Earns fees on every trade"];

export function TickerAssetSection() {
  return (
    <section className="border-t border-border bg-surface/40 py-16">
      <div className="content-container grid gap-10 lg:grid-cols-2 lg:items-center">
        <div>
          <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">The ticker is the asset</h2>
          <p className="mt-2 text-sm text-ink-dim">
            Own the ticker, own the flow. Not just a memecoin launch — a claimable piece of that
            meme&apos;s trading activity, forever.
          </p>

          <div className="mt-6 flex flex-col gap-2">
            {FLOW.map((step, i) => (
              <div key={step} className="flex items-center gap-2 text-sm">
                {i > 0 && <span className="text-ink-faint">↓</span>}
                <span className={i === 0 ? "font-mono text-lg text-gold" : "text-ink-dim"}>{step}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-lg border border-border bg-surface p-6">
          <p className="text-xs uppercase tracking-wide text-ink-faint">Trading fee split</p>
          <p className="mt-1 font-mono text-3xl font-semibold text-ink">{TRADE_TAX_PCT}%</p>
          <p className="text-xs text-ink-faint">total trading fee, every buy and sell</p>

          <div className="mt-5 flex flex-col gap-3">
            <FeeRow label="TickerNFT owner" pct={TICKER_OWNER_FEE_PCT_OF_TRADE} tone="gold" />
            <FeeRow label="Protocol" pct={PROTOCOL_FEE_PCT_OF_TRADE} tone="ink" />
            <FeeRow label="WinnerPot" pct={WINNER_POT_FEE_PCT_OF_TRADE} tone="cyan" />
          </div>
        </div>
      </div>
    </section>
  );
}

function FeeRow({ label, pct, tone }: { label: string; pct: number; tone: "gold" | "cyan" | "ink" }) {
  const barColor = tone === "gold" ? "bg-gold" : tone === "cyan" ? "bg-cyan" : "bg-ink-faint";
  const textColor = tone === "gold" ? "text-gold" : tone === "cyan" ? "text-cyan" : "text-ink";
  return (
    <div>
      <div className="flex items-center justify-between text-xs">
        <span className="text-ink-dim">{label}</span>
        <span className={`font-mono font-medium ${textColor}`}>{pct}%</span>
      </div>
      <div className="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-border">
        <div className={`h-full rounded-full ${barColor}`} style={{ width: `${(pct / TRADE_TAX_PCT) * 100}%` }} />
      </div>
    </div>
  );
}
