"use client";

import { StatusLamp } from "@/components/machine/PhysicalButton";

export type Availability =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "available" }
  | { kind: "taken"; owner?: string }
  | { kind: "invalid"; reason: string };

/** The label-maker display. Availability comes from useTickerAvailability — this
 *  component performs no check of its own. */
export function TickerSlot({
  ticker,
  onTicker,
  name,
  onName,
  availability,
}: {
  ticker: string;
  onTicker: (v: string) => void;
  name: string;
  onName: (v: string) => void;
  availability: Availability;
}) {
  const lamp = {
    idle: { tone: "neutral" as const, label: "3–10 CHARACTERS" },
    checking: { tone: "wait" as const, label: "CHECKING ONCHAIN…" },
    available: { tone: "ok" as const, label: "AVAILABLE · SLOT IS EMPTY" },
    taken: { tone: "bad" as const, label: "TAKEN · ANOTHER TICKERNFT OWNS THIS LABEL" },
    invalid: { tone: "bad" as const, label: availability.kind === "invalid" ? availability.reason.toUpperCase() : "" },
  }[availability.kind];

  return (
    <div className="flex flex-col gap-3.5 rounded-md border border-edge-hair bg-chassis-900 p-[18px] shadow-display">
      <div className="flex flex-col gap-2">
        <label htmlFor="ticker" className="font-mono text-label text-ink-500">TICKER SLOT</label>
        <div className="flex items-center gap-2.5 border-b border-edge-hair pb-2.5">
          <span aria-hidden className="font-mono text-[27px] text-ink-600">$</span>
          <input
            id="ticker"
            value={ticker}
            onChange={(e) => onTicker(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ""))}
            maxLength={10}
            placeholder="CLAW"
            autoComplete="off"
            spellCheck={false}
            className="min-w-0 flex-1 border-0 bg-transparent font-mono text-[27px] uppercase tracking-[0.06em] text-bulb outline-none placeholder:text-ink-600"
          />
        </div>
        <StatusLamp tone={lamp.tone} label={lamp.label} />
      </div>

      <div className="flex flex-col gap-2">
        <label htmlFor="token-name" className="font-mono text-label text-ink-500">TOKEN NAME</label>
        <input
          id="token-name"
          value={name}
          onChange={(e) => onName(e.target.value)}
          placeholder="Claw Machine Coin"
          className="border border-edge-hair bg-chassis-800 px-3 py-2.5 text-sm text-ink-100 outline-none placeholder:text-ink-600"
        />
      </div>
    </div>
  );
}

/** Optional metadata, collapsed out of the critical path so the primary action is
 *  never below six fields. Skipping these does not delay the launch. */
export function OptionalMeta({ open, onToggle }: { open: boolean; onToggle: () => void }) {
  return (
    <>
      <button
        onClick={onToggle}
        aria-expanded={open}
        className="flex items-center gap-2 border-0 bg-transparent p-0 text-left font-mono text-label text-ink-400"
      >
        <span className="text-amber">{open ? "−" : "+"}</span> OPTIONAL · IMAGE, X, TELEGRAM, WEBSITE
      </button>
      {open ? (
        <div className="flex flex-col gap-2.5 border-l border-edge-hair pl-3.5">
          <div className="flex items-center gap-2.5 border border-dashed border-edge-hard bg-chassis-800 p-3">
            <span aria-hidden className="h-[38px] w-[38px] flex-none rounded-[10px] bg-prize-empty" />
            <span className="font-mono text-[10.5px] text-ink-500">DROP PRIZE IMAGE · PNG/JPG · OPTIONAL</span>
          </div>
          {[
            { name: "x", ph: "x.com/handle" },
            { name: "telegram", ph: "t.me/channel" },
            { name: "website", ph: "https://" },
          ].map((i) => (
            <input
              key={i.name}
              name={i.name}
              placeholder={i.ph}
              className="border border-edge-hair bg-chassis-800 px-2.5 py-2 text-[12.5px] text-ink-100 outline-none placeholder:text-ink-600"
            />
          ))}
          <p className="m-0 text-[11.5px] leading-[1.5] text-ink-500">
            Stored off-chain after the token is live.
          </p>
        </div>
      ) : null}
    </>
  );
}
