import { TICKER_OWNER_FEE_PCT_OF_TRADE } from "@/lib/constants";
import { formatAddress } from "@/lib/format";
import { addresses } from "@/lib/web3/addresses";
import type { TokenDetail } from "@/lib/types";

export function TickerInfoPanel({ token }: { token: TokenDetail }) {
  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">TICKER</h3>
      <div className="mt-3 flex justify-between text-sm">
        <span className="text-ink-dim">TickerNFT owner</span>
        <span className="font-mono text-xs text-ink">{formatAddress(token.tickerOwner)}</span>
      </div>
      <div className="mt-1.5 flex justify-between text-sm">
        <span className="text-ink-dim">Owner fee</span>
        <span className="font-mono text-gold">{TICKER_OWNER_FEE_PCT_OF_TRADE}%</span>
      </div>
      {addresses.tickerNFT && (
        <a
          href={`https://opensea.io/assets/${addresses.tickerNFT}/${token.tickerTokenId}`}
          target="_blank"
          rel="noreferrer"
          className="mt-3 inline-block text-xs font-medium text-cyan hover:underline"
        >
          View on OpenSea ↗
        </a>
      )}
    </div>
  );
}
