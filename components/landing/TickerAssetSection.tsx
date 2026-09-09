import { TICKER_OWNER_FEE_PCT_OF_TRADE, PROTOCOL_FEE_PCT_OF_TRADE, WINNER_POT_FEE_PCT_OF_TRADE, TRADE_TAX_PCT } from "@/lib/constants";

const FLOW = ["$CAT", "UNIQUE IN CLOG", "TICKERNFT", "TRANSFERABLE", "EARNS FEES"];

export function TickerAssetSection() {
  return (
    <section className="border-t border-border bg-surface/40 py-16">
      <div className="content-container grid gap-10 lg:grid-cols-2 lg:items-center">
        <div>
          <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">The ticker is an asset.</h2>
          <p className="mt-2 text-sm text-ink-dim">
            Once $CAT is claimed, another CLOG launch cannot use $CAT.
          </p>

          <div className="mt-6 flex flex-wrap items-center gap-2 font-mono text-xs">
            {FLOW.map((step, i) => (
              <span key={step} className="flex items-center gap-2">
                {i > 0 && <span className="text-ink-faint">→</span>}
                <span
                  className={
                    i === 0
                      ? "rounded border border-gold/30 bg-gold/10 px-2.5 py-1 text-sm text-gold"
                      : "rounded border border-border bg-surface px-2.5 py-1 text-ink-dim"
                  }
                >
                  {step}
                </span>
              </span>
            ))}
          </div>

          <p className="mt-6 text-xs text-ink-faint">Unique inside CLOG — not globally unique.</p>
        </div>

        <div className="rounded-lg border border-border bg-surface p-6">
          <p className="text-xs uppercase tracking-wide text-ink-faint">Ticker owner fee</p>
          <p className="mt-1 font-mono text-2xl font-semibold text-ink">
            {TICKER_OWNER_FEE_PCT_OF_TRADE}% of every CAT buy and sell
          </p>

          <div className="mt-5">
            <p className="text-xs text-ink-faint">{TRADE_TAX_PCT}% trade fee</p>
            <div className="mt-2 flex h-3 w-full overflow-hidden rounded-full bg-border">
              <div className="h-full bg-gold" style={{ width: `${(TICKER_OWNER_FEE_PCT_OF_TRADE / TRADE_TAX_PCT) * 100}%` }} />
              <div className="h-full bg-ink-faint" style={{ width: `${(PROTOCOL_FEE_PCT_OF_TRADE / TRADE_TAX_PCT) * 100}%` }} />
              <div className="h-full bg-cyan" style={{ width: `${(WINNER_POT_FEE_PCT_OF_TRADE / TRADE_TAX_PCT) * 100}%` }} />
            </div>
            <div className="mt-3 flex flex-col gap-1.5 font-mono text-xs">
              <div className="flex justify-between">
                <span className="text-ink-dim">TickerNFT owner</span>
                <span className="text-gold">{TICKER_OWNER_FEE_PCT_OF_TRADE}%</span>
              </div>
              <div className="flex justify-between">
                <span className="text-ink-dim">Protocol</span>
                <span className="text-ink">{PROTOCOL_FEE_PCT_OF_TRADE}%</span>
              </div>
              <div className="flex justify-between">
                <span className="text-ink-dim">Jackpot</span>
                <span className="text-cyan">{WINNER_POT_FEE_PCT_OF_TRADE}%</span>
              </div>
            </div>
          </div>

          <p className="mt-5 text-xs text-ink-faint">Ticker fee rights move with the TickerNFT.</p>
        </div>
      </div>
    </section>
  );
}
