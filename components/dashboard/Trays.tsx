import Link from "next/link";
import { prizeSkin } from "@/components/machine/Claw";
import { NoSignal, ErrorPlate, EmptyChute } from "@/components/machine/States";

function Tray({
  title,
  note,
  children,
}: {
  title: string;
  note: string;
  children: React.ReactNode;
}) {
  return (
    <div className="min-w-0 overflow-hidden border border-edge-soft bg-chassis-800">
      <div className="flex items-center justify-between gap-2.5 border-b border-edge-inner bg-chassis-600 px-4 py-2.5">
        <span className="font-mono text-label text-ink-500">{title}</span>
        <span className="font-mono text-label text-ink-600">{note}</span>
      </div>
      {children}
    </div>
  );
}

export type Holding = {
  ticker: string;
  balanceLabel: string;
  valueEthLabel: string;
  shareLabel: string;
  qualified: boolean;
};

export function HoldingsTray({
  holdings,
  isLoading,
  error,
  onRetry,
}: {
  holdings: Holding[];
  isLoading?: boolean;
  error?: { message: string } | null;
  onRetry?: () => void;
}) {
  return (
    <Tray title="YOUR HOLDINGS" note="PRIZE-POOL SHARE">
      <div className="p-4">
        {isLoading ? <NoSignal lines={3} />
        : error ? <ErrorPlate title="Could not read holdings" detail={error.message} onRetry={onRetry} />
        : holdings.length === 0 ? <EmptyChute label="NO POSITIONS" body="Buy a qualified ticker and you are in the pool for the next draw." />
        : null}
      </div>
      {!isLoading && !error && holdings.map((h) => (
        <Link key={h.ticker} href={`/token/${h.ticker.replace(/^\$/, "")}`} className="flex items-center gap-3 border-b border-[#131317] px-4 py-3.5 no-underline">
          <span aria-hidden className="h-8 w-8 flex-none rounded-lg" style={{ background: prizeSkin(h.ticker) }} />
          <span className="min-w-0 flex-1">
            <span className="clog-fig block text-[12.5px] text-ink-100">{h.ticker}</span>
            <span className="clog-fig block text-[10.5px] text-ink-500">{h.balanceLabel}</span>
          </span>
          <span className="text-right">
            <span className="clog-fig block whitespace-nowrap text-[12.5px] text-ink-100">{h.valueEthLabel}</span>
            <span className={`clog-fig block whitespace-nowrap text-[10.5px] ${h.qualified ? "text-ok" : "text-ink-500"}`}>
              {h.shareLabel}
            </span>
          </span>
        </Link>
      ))}
    </Tray>
  );
}

export type TickerNft = { ticker: string; tokenId: string; openSeaUrl: string | null };

export function TickerNftTray({
  nfts,
  isLoading,
  error,
  onRetry,
}: {
  nfts: TickerNft[];
  isLoading?: boolean;
  error?: { message: string } | null;
  onRetry?: () => void;
}) {
  return (
    <Tray title="YOUR TICKER NFTS" note="LABELS YOU OWN">
      <div className="p-4">
        {isLoading ? <NoSignal lines={2} />
        : error ? <ErrorPlate title="Could not read your NFTs" detail={error.message} onRetry={onRetry} />
        : nfts.length === 0 ? <EmptyChute label="NO LABELS" body="Launching a ticker mints the NFT that owns it." />
        : null}
      </div>
      {!isLoading && !error && nfts.map((n) => (
        <div key={n.tokenId} className="flex items-center gap-3 border-b border-[#131317] px-4 py-3.5">
          <span aria-hidden className="h-8 w-8 flex-none rounded-lg border border-edge-hard" style={{ background: prizeSkin(n.ticker) }} />
          <span className="min-w-0 flex-1">
            <span className="clog-fig block text-[12.5px] text-ink-100">{n.ticker}</span>
            <span className="clog-fig block text-[10.5px] text-ink-500">TICKERNFT #{n.tokenId}</span>
          </span>
          {n.openSeaUrl ? (
            <Link href={n.openSeaUrl} target="_blank" rel="noreferrer" className="whitespace-nowrap font-mono text-[10.5px] text-amber">
              OPENSEA ↗
            </Link>
          ) : null}
        </div>
      ))}
      {!isLoading && !error && nfts.length > 0 ? (
        <p className="m-0 px-4 py-3.5 text-xs leading-[1.5] text-ink-500">
          Owning the label is separate from holding the token. Selling the NFT does not sell your position.
        </p>
      ) : null}
    </Tray>
  );
}
