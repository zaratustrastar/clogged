import { TokenIcon } from "@/components/ui/TokenIcon";
import { Button } from "@/components/ui/Button";
import { formatAddress, formatTimeAgo } from "@/lib/format";
import { openSeaTickerUrl } from "@/lib/constants";
import type { TokenDetail } from "@/lib/types";

export function TokenHeader({ token }: { token: TokenDetail }) {
  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-center gap-3">
        <TokenIcon ticker={token.ticker} size={44} />
        <div>
          <div className="flex items-baseline gap-2">
            <h1 className="font-display text-xl font-semibold text-ink">{token.name}</h1>
            <span className="text-sm text-ink-faint">{token.ticker}</span>
          </div>
          <div className="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-ink-dim">
            <span>
              by <span className="font-mono">{formatAddress(token.creator)}</span>
            </span>
            <span>·</span>
            <span>Created {formatTimeAgo(token.createdAt)}</span>
            <span>·</span>
            <span>
              Ticker owner <span className="font-mono">{formatAddress(token.tickerOwner)}</span>
            </span>
          </div>
        </div>
      </div>

      <a href={openSeaTickerUrl("ticker-nft", token.tickerTokenId)} target="_blank" rel="noreferrer">
        <Button variant="secondary">Trade ticker on OpenSea ↗</Button>
      </a>
    </div>
  );
}
