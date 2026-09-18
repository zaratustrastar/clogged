import type { TxMotionState } from "./motion";

/** The claw rig. Three CSS fingers on a chrome rod — no SVG, no asset payload.
 *
 *  Position is a function of REAL state:
 *    idle / searching  → hovers (randomness not yet returned)
 *    awaiting/pending  → descends and locks
 *    confirmed         → lifts, and only then may a prize rise with it
 *  Never animate toward a winner before settlement exists onchain. */
/** The SEARCHING claw: hangs from the centre of the glass while no winner exists.
 *  It must NOT be used to lift a prize — candidates sit in a centred row, so the
 *  winner is almost never at the centre and a centred claw would close on empty air.
 *  Pass `grabbed` to PrizePuck instead; that renders ClawHead attached to the prize. */
export function Claw({ state = "idle", offset }: { state?: TxMotionState; offset?: number }) {
  const y = offset ?? (state === "idle" ? 0 : 176);
  const searching = state === "idle" && offset === undefined;

  return (
    <div aria-hidden className="pointer-events-none absolute inset-0">
      <div
        className={`absolute left-1/2 top-[58px] ${searching ? "animate-clog-hover" : ""}`}
        style={{
          transform: `translate(-50%, ${y}px)`,
          transition: "transform 760ms cubic-bezier(.35,0,.2,1)",
        }}
      >
        <ClawFingers />
      </div>
    </div>
  );
}

/** Head + fingers + the rod that suspends them, as ONE unit.
 *  The rod is a child, never a sibling: a sibling rod cannot follow a horizontal
 *  animation and the head visibly flies off its own cable. The glass's
 *  overflow-hidden clips the rod where it leaves the cabinet. */
function ClawFingers({ closed = false }: { closed?: boolean }) {
  const splay = closed ? "rotate-[22deg]" : "rotate-[14deg]";
  const splayR = closed ? "-rotate-[22deg]" : "-rotate-[14deg]";
  return (
    <div className="relative -ml-8 h-[50px] w-16">
      <div className="absolute bottom-full left-1/2 -ml-px h-[420px] w-0.5 bg-chrome-rod" />
      <div className="absolute left-4 top-0 h-[17px] w-8 rounded-[3px] bg-gradient-to-b from-chrome-100 to-chrome-300 shadow-[0_2px_6px_rgba(0,0,0,.6)]" />
      <div className={`absolute left-[5px] top-3.5 h-[34px] w-2.5 ${splay} rounded-b-[10px] bg-gradient-to-b from-chrome-200 to-chrome-400`} />
      <div className="absolute left-[27px] top-3.5 h-[38px] w-2.5 rounded-b-[10px] bg-gradient-to-b from-chrome-100 to-chrome-300" />
      <div className={`absolute left-[49px] top-3.5 h-[34px] w-2.5 ${splayR} rounded-b-[10px] bg-gradient-to-b from-chrome-200 to-chrome-400`} />
    </div>
  );
}

/** The GRABBING claw. Rendered inside the winning puck's wrapper so it is locked to
 *  the prize horizontally by construction — no measurement, correct for any winner.
 *  The rod runs up out of the glass and is clipped by the glass's overflow-hidden. */
function ClawHead() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute bottom-[calc(100%-22px)] left-1/2 h-[50px] w-16 -translate-x-1/2"
    >
      <div className="absolute left-8">
        <ClawFingers closed />
      </div>
    </div>
  );
}

/** Deterministic plush palette from the ticker string — same input, same prize, no assets.
 *  Independent of lib/tickerArtwork.ts, which stays byte-identical for minted metadata. */
export function prizeSkin(ticker: string): string {
  const palettes = [
    ["#FFF0D8", "#D8B98A"],
    ["#B9C4B2", "#76816F"],
    ["#F0E4DA", "#B39E92"],
    ["#D9BFC4", "#9B7B84"],
    ["#C6C2A8", "#85826D"],
    ["#C3CBD9", "#7C8595"],
  ];
  let h = 0;
  for (let i = 0; i < ticker.length; i++) h = (h * 31 + ticker.charCodeAt(i)) >>> 0;
  const [a, b] = palettes[h % palettes.length];
  return `radial-gradient(70% 60% at 34% 26%, ${a}, ${b})`;
}

/** A prize inside the glass. `lifted` only ever comes from settled state.
 *  When lifted, the claw is rendered as a CHILD here, so claw and prize move as one
 *  unit — that is what keeps them aligned for a winner anywhere in the row. */
export function PrizePuck({
  ticker,
  size = 68,
  tilt = 0,
  lifted = false,
  sway = false,
}: {
  ticker: string;
  size?: number;
  tilt?: number;
  lifted?: boolean;
  sway?: boolean;
}) {
  return (
    <div
      className={`relative ${sway ? "origin-bottom animate-clog-sway" : ""}`}
      style={{
        transform: lifted ? "translateY(-116px)" : `rotate(${tilt}deg)`,
        transition: "transform 700ms cubic-bezier(.3,0,.2,1)",
      }}
    >
      {lifted ? <ClawHead /> : null}
      <div
        className="flex items-end justify-center rounded-2xl pb-1.5 shadow-prize"
        style={{ width: size, height: size, background: prizeSkin(ticker) }}
      >
        <span className="bg-white/60 px-1.5 py-0.5 font-mono text-[9.5px] font-bold text-[#2B2622]">
          {ticker}
        </span>
      </div>
    </div>
  );
}

/** Empty slot — marks where a real plush render drops in later. */
export function PrizeSlot({ size = 54 }: { size?: number }) {
  return (
    <div
      className="flex items-end justify-center rounded-xl border border-dashed border-chrome-500 bg-prize-empty pb-1"
      style={{ width: size, height: size }}
    >
      <span className="font-mono text-[7.5px] text-ink-500">prize art</span>
    </div>
  );
}
