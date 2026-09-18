"use client";

import Link from "next/link";
import { Cabinet, Display, Glass, ControlDeck } from "@/components/machine/Cabinet";
import { Claw, PrizePuck, PrizeSlot } from "@/components/machine/Claw";
import { StatusLamp } from "@/components/machine/PhysicalButton";

export type HeroRound = {
  roundNumber: number | null;
  countdown: string | null;      // pre-formatted by the caller's existing countdown hook
  jackpotEth: string | null;     // pre-formatted; never a raw float
  qualifiedCount: number | null;
  /** true only when randomness has been requested and not yet settled */
  randomnessPending?: boolean;
};

/** Section 1 of 4. Left column sells the mechanic in words; right column IS the machine.
 *  All numbers come in pre-formatted — this component performs no protocol reads. */
export function MachineHero({
  round,
  prizes,
}: {
  round: HeroRound;
  prizes: { ticker: string }[];
}) {
  const shown = prizes.slice(0, 4);
  const lamp = round.randomnessPending
    ? { tone: "wait" as const, label: "RANDOMNESS PENDING · CLAW SEARCHING" }
    : { tone: "neutral" as const, label: "CLAW ARMED · WAITING FOR ROUND CLOSE" };

  return (
    <section className="grid grid-cols-1 items-center gap-8 py-10 lg:grid-cols-2">
      <div className="flex min-w-0 flex-col gap-[18px]">
        <span className="font-mono text-label text-amber">MEME MARKETS, MACHINE-OPERATED</span>
        <h1 className="m-0 font-display text-[clamp(34px,5.4vw,62px)] leading-[0.98] tracking-[-0.025em] text-balance">
          Put a ticker in the machine.
        </h1>
        <p className="m-0 max-w-[46ch] text-[16.5px] leading-[1.55] text-ink-400 text-pretty">
          Launch a ticker, trade it, and every qualified token goes into the prize pool. When the round
          closes the claw picks one at random — verifiably — and the winning token&apos;s holders split the pot.
        </p>
        <div className="flex flex-wrap items-center gap-3">
          <Link
            href="/launch"
            className="rounded-full bg-cap-amber px-[26px] py-[17px] font-display text-sm tracking-[0.07em] text-amber-ink shadow-cap"
          >
            LAUNCH A TICKER
          </Link>
          <Link
            href="/explore"
            className="border border-edge-hard bg-chassis-600 px-5 py-4 font-mono text-meta text-ink-100"
          >
            SEE WHAT&apos;S IN THE MACHINE
          </Link>
        </div>
        <div className="flex flex-wrap gap-x-[18px] gap-y-2 font-mono text-meta text-ink-500">
          {["CHAINLINK VRF", "ONCHAIN SETTLEMENT", "NO PRESALE"].map((t) => (
            <span key={t} className="flex items-center gap-[7px]">
              <span aria-hidden className="h-2 w-2 rounded-full bg-ok shadow-[0_0_8px_#7FD6A0]" />
              {t}
            </span>
          ))}
        </div>
      </div>

      <Cabinet className="min-w-0">
        <div className="relative overflow-hidden rounded-md border border-edge-hard bg-gradient-to-b from-chassis-700 to-chassis-900 px-4 py-3">
          <div aria-hidden className="pointer-events-none absolute inset-0 bg-marquee-glow" />
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p className="m-0 font-display text-[26px] leading-[0.9] tracking-[0.05em] text-ink-200 [text-shadow:0_1px_0_rgba(255,255,255,.22),0_0_22px_rgba(255,243,214,.28)]">
                CLOG
              </p>
              <p className="mt-1 font-mono text-label text-ink-500">
                {round.roundNumber != null ? `ROUND #${round.roundNumber} · LIVE` : "ROUND — · LOADING"}
              </p>
            </div>
            <div className="flex gap-2">
              <Display label="CLOSES IN" className="min-w-[96px] border-edge-hair bg-chassis-800 shadow-none">
                <p className="clog-fig m-0 mt-0.5 text-fig text-bulb">{round.countdown ?? "—:—"}</p>
              </Display>
              <Display
                label="JACKPOT"
                className="min-w-[110px] border-amber/40 bg-amber/[0.07] shadow-none [&>p]:text-amber-dim"
              >
                <p className="clog-fig m-0 mt-0.5 text-fig text-amber">{round.jackpotEth ?? "—"}</p>
              </Display>
            </div>
          </div>
        </div>

        <Glass
          className="mt-3 h-[clamp(240px,34vw,330px)]"
          label={
            round.qualifiedCount != null
              ? `QUALIFIED PRIZE POOL · ${round.qualifiedCount}`
              : "QUALIFIED PRIZE POOL · —"
          }
        >
          <Claw state="idle" />
          <div className="absolute bottom-3.5 left-0 flex w-full items-end justify-center gap-2 px-4">
            {shown.map((p, i) => (
              <PrizePuck
                key={p.ticker}
                ticker={p.ticker}
                size={i === 0 ? 86 : 58 + ((i * 7) % 12)}
                tilt={i % 2 ? 6 : -5}
                sway={i === 0}
              />
            ))}
            <PrizeSlot />
          </div>
        </Glass>

        <ControlDeck className="mt-3 flex flex-wrap items-center justify-between gap-3">
          <StatusLamp tone={lamp.tone} label={lamp.label} />
          <Link
            href="/round"
            className="border border-amber/40 bg-amber/[0.07] px-3 py-2 font-mono text-meta text-amber"
          >
            WATCH THE DRAW
          </Link>
        </ControlDeck>
      </Cabinet>
    </section>
  );
}
