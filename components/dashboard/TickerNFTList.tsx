import { TokenIcon } from "@/components/ui/TokenIcon";
import { Button } from "@/components/ui/Button";
import { EmptyState } from "@/components/ui/EmptyState";
import type { OwnedTickerNFT } from "@/lib/types";

export function TickerNFTList({ nfts }: { nfts: OwnedTickerNFT[] }) {
  if (nfts.length === 0) {
    return <EmptyState title="No ticker NFTs" description="Launching a token mints you its TickerNFT." />;
  }

  return (
    <div className="flex flex-col gap-2">
      {nfts.map((nft) => (
        <div
          key={nft.tokenId}
          className="flex items-center justify-between rounded border border-border bg-surface px-4 py-3"
        >
          <div className="flex items-center gap-3">
            <TokenIcon ticker={nft.ticker} size={30} />
            <div>
              <p className="text-sm font-medium text-ink">{nft.ticker}</p>
              <p className="text-xs text-ink-dim">Earns 20% of trading fees</p>
            </div>
          </div>
          <a href={nft.openSeaUrl} target="_blank" rel="noreferrer">
            <Button variant="secondary" size="sm">
              View / trade on OpenSea ↗
            </Button>
          </a>
        </div>
      ))}
    </div>
  );
}
