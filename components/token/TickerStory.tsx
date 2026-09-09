import { TICKER_OWNER_FEE_PCT_OF_TRADE } from "@/lib/constants";
import type { TokenDetail } from "@/lib/types";

const STEPS = ["Unique inside CLOG", "TickerNFT", "Transferable on OpenSea", "Future ticker fees"];

export function TickerStory({ token }: { token: TokenDetail }) {
  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">THE TICKER BECOMES PROPERTY</h3>

      <div className="mt-4 flex flex-col items-start gap-1.5">
        <span className="font-mono text-lg text-gold">${token.ticker}</span>
        {STEPS.map((step) => (
          <div key={step} className="flex items-center gap-1.5 pl-1 text-xs text-ink-dim">
            <span className="text-ink-faint">↓</span>
            <span>{step}</span>
          </div>
        ))}
      </div>

      <p className="mt-4 text-sm text-ink">
        TickerNFT owner earns {TICKER_OWNER_FEE_PCT_OF_TRADE}% of every {token.ticker} buy and sell.
      </p>
      <p className="mt-2 text-xs text-ink-faint">
        Unique inside CLOG — not globally unique across all crypto.
      </p>
    </div>
  );
}
