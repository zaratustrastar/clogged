import Link from "next/link";
import { prizeSkin } from "@/components/machine/Claw";

/** Token header. PATCH P1-1 APPLIED: the OpenSea link uses the real TickerNFT contract
 *  address (the current TokenHeader passes the literal string "ticker-nft", producing a
 *  dead URL). Pass openSeaUrl in already-built, from addresses.tickerNFT. */
export function TokenHeader({
  ticker,
  name,
  creator,
  ageLabel,
  qualified,
  openSeaUrl,
  contractUrl,
}: {
  ticker: string;
  name: string;
  creator: string;
  ageLabel: string;
  qualified: boolean;
  openSeaUrl: string | null;
  contractUrl: string;
}) {
  return (
    <div className="flex flex-wrap items-center gap-4 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 px-5 py-[18px]">
      <span aria-hidden className="h-[62px] w-[62px] flex-none rounded-2xl shadow-prize" style={{ background: prizeSkin(ticker) }} />
      <div className="min-w-0 flex-[1_1_200px]">
        <div className="flex flex-wrap items-baseline gap-2.5">
          <h1 className="m-0 font-display text-[30px] tracking-[-0.02em]">{ticker}</h1>
          <span className="text-sm text-ink-400">{name}</span>
        </div>
        <p className="mt-1 font-mono text-meta text-ink-500">CREATOR {creator} · LAUNCHED {ageLabel}</p>
      </div>

      {qualified ? (
        <div className="flex items-center gap-2 border border-ok/35 bg-ok/[0.06] px-3.5 py-2.5">
          <span aria-hidden className="h-2.5 w-2.5 rounded-full bg-ok shadow-[0_0_9px_#7FD6A0]" />
          <span className="whitespace-nowrap font-mono text-meta text-ok">QUALIFIED · IN THE POOL</span>
        </div>
      ) : null}

      <div className="flex flex-wrap gap-2">
        {openSeaUrl ? (
          <Link href={openSeaUrl} target="_blank" rel="noreferrer" className="border border-edge-hard bg-chassis-600 px-3 py-2.5 font-mono text-[10.5px] tracking-[0.08em] text-ink-100 no-underline">
            TICKER NFT ↗
          </Link>
        ) : null}
        <Link href={contractUrl} target="_blank" rel="noreferrer" className="border border-edge-hard bg-chassis-600 px-3 py-2.5 font-mono text-[10.5px] tracking-[0.08em] text-ink-100 no-underline">
          CONTRACT ↗
        </Link>
      </div>
    </div>
  );
}

/** Market panel. Chart stays an honest placeholder until an indexer exists (P2) —
 *  it is labelled as awaiting data rather than drawn as a decorative fake. */
export function MarketPanel({
  priceEth,
  change1h,
  change24h,
  marketCapEth,
  holders,
  curvePct,
  reserveLabel,
}: {
  priceEth: string;
  change1h: string;
  change24h: string;
  marketCapEth: string;
  holders: string;
  curvePct: number;
  reserveLabel: string;
}) {
  const stats = [
    { k: "1H", v: change1h },
    { k: "24H", v: change24h },
    { k: "MARKET CAP", v: marketCapEth },
    { k: "HOLDERS", v: holders },
  ];
  return (
    <div className="flex flex-col gap-4 border border-edge-soft bg-chassis-800 p-[18px]">
      <div className="flex flex-wrap items-end gap-[18px]">
        <div>
          <p className="m-0 font-mono text-label text-ink-500">PRICE</p>
          <p className="clog-fig m-0 mt-1 whitespace-nowrap text-[32px] text-ink-100">{priceEth}</p>
        </div>
        <div className="flex flex-wrap gap-2.5">
          {stats.map((s) => (
            <div key={s.k} className="border border-edge-hair bg-chassis-900 px-3.5 py-2.5">
              <p className="m-0 font-mono text-label text-ink-500">{s.k}</p>
              <p className="clog-fig m-0 mt-1 whitespace-nowrap text-[15px] text-ink-100">{s.v}</p>
            </div>
          ))}
        </div>
      </div>

      <div className="flex h-[190px] items-center justify-center border border-dashed border-edge-hard bg-glass-scan">
        <p className="m-0 font-mono text-meta text-ink-600">PRICE CHART · AWAITING INDEXER</p>
      </div>

      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between gap-3">
          <span className="font-mono text-label text-ink-500">CURVE PROGRESS</span>
          <span className="clog-fig whitespace-nowrap text-xs text-amber">{curvePct}% · {reserveLabel}</span>
        </div>
        <div className="h-[7px] overflow-hidden bg-edge-inner">
          <div className="h-full bg-amber" style={{ width: `${curvePct}%` }} />
        </div>
      </div>
    </div>
  );
}

export type ActivityEvent = {
  kind: "BUY" | "SELL" | "QUAL";
  detail: string;
  who: string;
  ago: string;
};

export function ActivityFeed({ events }: { events: ActivityEvent[] }) {
  const color = { BUY: "text-ok", SELL: "text-bad", QUAL: "text-amber" };
  return (
    <div className="overflow-hidden border border-edge-soft bg-chassis-800">
      <div className="flex items-center justify-between gap-3 border-b border-edge-inner bg-chassis-600 px-4 py-2.5">
        <span className="font-mono text-label text-ink-500">ACTIVITY</span>
        <span className="font-mono text-label text-ink-600">ONCHAIN EVENTS</span>
      </div>
      {events.map((e, i) => (
        <div key={i} className="flex items-center gap-3 border-b border-[#131317] px-4 py-2.5">
          <span className={`w-11 flex-none font-mono text-[11.5px] ${color[e.kind]}`}>{e.kind}</span>
          <span className="clog-fig min-w-0 flex-1 truncate text-[11.5px] text-ink-100">{e.detail}</span>
          <span className="whitespace-nowrap font-mono text-[11px] text-ink-500">{e.who}</span>
          <span className="whitespace-nowrap font-mono text-[11px] text-ink-600">{e.ago}</span>
        </div>
      ))}
    </div>
  );
}

/** The label panel — keeps TickerNFT ownership visibly distinct from holding the ERC-20. */
export function LabelPanel({ ticker, tokenId, openSeaUrl }: { ticker: string; tokenId: string; openSeaUrl: string | null }) {
  return (
    <div className="flex flex-col gap-2.5 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-[18px]">
      <span className="font-mono text-label text-ink-500">THE LABEL</span>
      <p className="m-0 text-[13px] leading-[1.55] text-ink-400 text-pretty">
        TickerNFT {tokenId} owns the <span className="clog-fig text-ink-100">{ticker}</span> label and its
        creator economics. Holding this token does not include the NFT — they trade separately.
      </p>
      {openSeaUrl ? (
        <Link href={openSeaUrl} target="_blank" rel="noreferrer" className="self-start border border-edge-hard bg-chassis-600 px-3 py-2.5 font-mono text-[10.5px] text-ink-100 no-underline">
          VIEW ON OPENSEA ↗
        </Link>
      ) : null}
    </div>
  );
}
