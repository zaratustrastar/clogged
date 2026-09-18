import Link from "next/link";

export type LastDraw = {
  roundNumber: number;
  winnerTicker: string;
  randomWord: string;      // truncated by the caller
  settlementTxUrl: string;
} | null;

/** Section 4 of 4 — replaces TickerAssetSection + RandomnessTrust + FAQ.
 *  The randomness plate shows real settled data or an honest empty state; it never
 *  illustrates a winner that has not settled. */
export function TrustPlates({ lastDraw }: { lastDraw: LastDraw }) {
  return (
    <section id="trust" className="grid grid-cols-1 gap-3.5 py-11 lg:grid-cols-2">
      <div className="flex min-w-0 flex-col gap-3.5 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-6">
        <span className="font-mono text-label text-amber">THE LABEL IS AN ASSET</span>
        <h3 className="m-0 font-display text-[23px] tracking-[-0.015em]">
          Owning the token is not owning the ticker
        </h3>
        <p className="m-0 text-[14.5px] leading-[1.6] text-ink-400 text-pretty">
          The TickerNFT is the machine slot: one per ticker, transferable, and it carries the creator
          economics for that ticker. Holding the ERC-20 makes you a holder in the prize pool. They are two
          different things and the interface says so everywhere.
        </p>
        <div className="mt-0.5 flex flex-wrap gap-2.5">
          <div className="min-w-0 flex-1 border border-edge-hair bg-chassis-900 px-3.5 py-3">
            <p className="m-0 font-mono text-label text-ink-500">TICKER NFT</p>
            <p className="mt-1.5 text-[13px] text-ink-100">Label · slot · creator economics</p>
          </div>
          <div className="min-w-0 flex-1 border border-edge-hair bg-chassis-900 px-3.5 py-3">
            <p className="m-0 font-mono text-label text-ink-500">ERC-20 HOLDING</p>
            <p className="mt-1.5 text-[13px] text-ink-100">Prize-pool share · round winnings</p>
          </div>
        </div>
      </div>

      <div className="flex min-w-0 flex-col gap-3.5 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-6">
        <span className="font-mono text-label text-ok">VERIFIABLE RANDOMNESS</span>
        <h3 className="m-0 font-display text-[23px] tracking-[-0.015em]">The claw does not decide. Chainlink does.</h3>
        <p className="m-0 text-[14.5px] leading-[1.6] text-ink-400 text-pretty">
          Candidates freeze at round close, randomness is requested onchain, and the winner is derived from
          the returned word. The animation only ever follows settlement — the claw hovers while randomness is
          pending and lifts a prize after the result exists.
        </p>
        {lastDraw ? (
          <dl className="m-0 flex flex-col gap-1.5 font-mono text-[11.5px] text-ink-400">
            <div className="flex justify-between gap-3 border-b border-dashed border-edge-hair pb-1.5">
              <dt>ROUND #{lastDraw.roundNumber} WINNER</dt>
              <dd className="m-0 text-ok">{lastDraw.winnerTicker}</dd>
            </div>
            <div className="flex justify-between gap-3 border-b border-dashed border-edge-hair pb-1.5">
              <dt>RANDOM WORD</dt>
              <dd className="m-0 truncate text-ink-100">{lastDraw.randomWord}</dd>
            </div>
            <div className="flex justify-between gap-3">
              <dt>SETTLEMENT TX</dt>
              <dd className="m-0">
                <Link href={lastDraw.settlementTxUrl} target="_blank" rel="noreferrer" className="text-amber">
                  view onchain ↗
                </Link>
              </dd>
            </div>
          </dl>
        ) : (
          <p className="m-0 font-mono text-[11.5px] text-ink-500">NO SETTLED ROUND YET · FIRST DRAW PENDING</p>
        )}
      </div>
    </section>
  );
}

/** Closing plate. The tear fires on press only; the link still works without JS. */
export function ClosingCTA() {
  return (
    <section
      id="launch"
      className="relative mt-11 flex flex-col items-center gap-[18px] overflow-hidden border border-edge-soft bg-gradient-to-b from-chassis-500 to-chassis-800 p-[clamp(28px,5vw,52px)] text-center"
    >
      <span className="font-mono text-label text-amber">THE MACHINE IS OPEN</span>
      <h2 className="m-0 max-w-[22ch] font-display text-[clamp(26px,4.4vw,44px)] leading-[1.02] tracking-[-0.025em] text-balance">
        Your ticker is not in there yet.
      </h2>
      <p className="m-0 max-w-[52ch] text-[15.5px] leading-[1.6] text-ink-400 text-pretty">
        Two transactions: secure the ticker, then reveal and mint. Costs are shown before you sign, and
        nothing is confirmed until the receipt lands.
      </p>
      <Link
        href="/launch"
        className="rounded-full bg-cap-amber px-[34px] py-[19px] font-display text-[15px] tracking-[0.07em] text-amber-ink shadow-cap transition-transform duration-[80ms] active:translate-y-1.5 active:shadow-cap-down"
      >
        LAUNCH A TICKER
      </Link>
    </section>
  );
}
