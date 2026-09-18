"use client";

import { Cabinet, Glass, Display } from "@/components/machine/Cabinet";
import { Claw, PrizePuck } from "@/components/machine/Claw";
import { StatusLamp } from "@/components/machine/PhysicalButton";

export type RoundPhase = "open" | "randomness-pending" | "settled";

export type RoundView = {
  phase: RoundPhase;
  roundNumber: number;
  countdown: string | null;        // pre-formatted; null once closed
  jackpotEth: string;
  qualifiedCount: number;
  candidates: { ticker: string }[];
  /** ONLY set when settlement exists onchain */
  winner: { ticker: string; holders: string; potEth: string } | null;
  vrf: { state: string; detail: string } | null;
};

/* THE RULE THIS COMPONENT ENFORCES:
 * the claw searches while randomness is pending and lifts a prize only once the
 * contract has a winner. No animation may anticipate a result. If winner is null,
 * nothing is lifted and nothing is named — regardless of how long we have waited. */
export function RoundStage({ view }: { view: RoundView }) {
  const settled = view.phase === "settled" && view.winner != null;

  /* Claw placement: while no winner exists the claw hangs from the centre of the glass
     and searches. Once settlement exists, the SEARCHING claw is unmounted and the
     grabbing claw renders inside the winning PrizePuck (see PrizePuck `lifted`), so
     claw and prize are one unit. Never centre a claw on a lifted prize — candidates
     sit in a centred row and the winner is almost never the middle card. */

  const head = {
    open: { title: "Round is open", sub: "Candidates can still qualify or drop out until close.", tone: "neutral" as const },
    "randomness-pending": { title: "Randomness pending", sub: "Candidates are frozen. Chainlink has been asked; nothing is decided.", tone: "wait" as const },
    settled: {
      title: view.winner ? `${view.winner.ticker} wins round #${view.roundNumber}` : "Settling",
      sub: view.winner ? "Winner derived from the returned random word. Holders can claim now." : "Awaiting the settlement receipt.",
      tone: "ok" as const,
    },
  }[view.phase];

  return (
    <Cabinet state={settled ? "confirmed" : view.phase === "randomness-pending" ? "pending" : "idle"}>
      <div className="relative flex flex-wrap items-center justify-between gap-4 overflow-hidden rounded-md border border-edge-hard bg-gradient-to-b from-chassis-700 to-chassis-900 px-5 py-4">
        <div aria-hidden className="pointer-events-none absolute inset-0 bg-marquee-glow" />
        <div className="min-w-0">
          <StatusLamp tone={head.tone} label={head.title.toUpperCase()} />
          <p className="mt-1.5 text-[12.5px] text-ink-400">{head.sub}</p>
        </div>
        <div className="flex flex-wrap gap-2.5">
          <Display label={view.countdown ? "CLOSES IN" : "CLOSED"} className="border-edge-hair bg-chassis-800 shadow-none">
            <p className="clog-fig m-0 mt-1 whitespace-nowrap text-[17px] text-bulb">{view.countdown ?? "00:00"}</p>
          </Display>
          <Display label="QUALIFIED" className="border-edge-hair bg-chassis-800 shadow-none">
            <p className="clog-fig m-0 mt-1 text-[17px] text-ink-100">{view.qualifiedCount}</p>
          </Display>
          <Display label="JACKPOT" className="border-amber/40 bg-amber/[0.07] shadow-none">
            <p className="clog-fig m-0 mt-1 whitespace-nowrap text-[17px] text-amber">{view.jackpotEth}</p>
          </Display>
        </div>
      </div>

      <Glass
        className="mt-3.5 h-[clamp(280px,38vw,380px)]"
        label={
          view.phase === "open" ? `QUALIFIED PRIZE POOL · ${view.qualifiedCount} · STILL MOVING`
          : view.phase === "randomness-pending" ? `CANDIDATES FROZEN · ${view.qualifiedCount} · AWAITING VRF`
          : "SETTLED · WINNER LIFTED"
        }
      >
        {settled ? null : <Claw state="idle" />}
        <div className="absolute bottom-4 left-0 flex w-full flex-wrap items-end justify-center gap-2.5 px-4">
          {view.candidates.map((c, i) => {
            const isWinner = settled && c.ticker === view.winner!.ticker;
            return (
              <div key={c.ticker} className={settled && !isWinner ? "opacity-45 transition-opacity duration-500" : ""}>
                <PrizePuck
                  ticker={c.ticker}
                  size={isWinner ? 84 : 56 + ((i * 9) % 18)}
                  tilt={i % 2 ? 5 : -5}
                  lifted={isWinner}
                  sway={view.phase === "open" && i === 0}
                />
              </div>
            );
          })}
        </div>
      </Glass>

      <div className="mt-3.5 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <Display label="RANDOMNESS">
          <p className="clog-fig m-0 mt-1.5 text-[13px] text-ink-100">{view.vrf?.state ?? "NOT REQUESTED"}</p>
          <p className="clog-fig m-0 mt-1 truncate text-[11px] text-ink-500">
            {view.vrf?.detail ?? "Requested automatically at round close"}
          </p>
        </Display>
        <Display label="WINNER">
          <p className={`clog-fig m-0 mt-1.5 text-[13px] ${settled ? "text-ok" : "text-ink-500"}`}>
            {settled ? view.winner!.ticker : "UNDETERMINED"}
          </p>
          <p className="clog-fig m-0 mt-1 text-[11px] text-ink-500">
            {settled ? `${view.winner!.holders} holders share by balance at settlement` : "No winner exists until randomness settles"}
          </p>
        </Display>
        <Display label="PAYOUT">
          <p className={`clog-fig m-0 mt-1.5 text-[13px] ${settled ? "text-ok" : "text-amber"}`}>
            {settled ? `${view.winner!.potEth} ASSIGNED` : view.phase === "open" ? "POT ACCUMULATING" : "LOCKED"}
          </p>
          <p className="clog-fig m-0 mt-1 text-[11px] text-ink-500">
            {settled ? "Claim from your dashboard chute" : `${view.jackpotEth} held by the vault`}
          </p>
        </Display>
      </div>
    </Cabinet>
  );
}

export type Draw = {
  roundNumber: number;
  ticker: string;
  potEth: string;
  holders: string;
  vrfUrl: string | null;
};

export function RecentDraws({ draws }: { draws: Draw[] }) {
  return (
    <div className="overflow-hidden border border-edge-soft bg-chassis-800">
      <div className="flex items-center justify-between gap-2.5 border-b border-edge-inner bg-chassis-600 px-4 py-2.5">
        <span className="font-mono text-label text-ink-500">RECENT DRAWS</span>
        <span className="font-mono text-label text-ink-600">EVERY RESULT VERIFIABLE ONCHAIN</span>
      </div>
      {draws.map((d) => (
        <div key={d.roundNumber} className="flex flex-wrap items-center gap-3 border-b border-[#131317] px-4 py-3.5">
          <span className="clog-fig w-[66px] flex-none text-[11.5px] text-ink-500">#{d.roundNumber}</span>
          <span className="clog-fig min-w-0 flex-[1_1_120px] text-[12.5px] text-ink-100">{d.ticker}</span>
          <span className="clog-fig whitespace-nowrap text-[12.5px] text-amber">{d.potEth}</span>
          <span className="clog-fig whitespace-nowrap text-[11px] text-ink-500">{d.holders} holders paid</span>
          {d.vrfUrl ? (
            <a href={d.vrfUrl} target="_blank" rel="noreferrer" className="whitespace-nowrap font-mono text-[11px] text-amber">
              vrf ↗
            </a>
          ) : null}
        </div>
      ))}
    </div>
  );
}
