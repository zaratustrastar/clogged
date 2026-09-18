const STEPS = [
  { n: "01", kicker: "LAUNCH", title: "Secure a ticker", body: "Commit the ticker, wait out the reveal delay, then mint. You get the ERC-20 and the TickerNFT that owns the label.", hot: false },
  { n: "02", kicker: "TRADE", title: "Qualify it", body: "Buying pushes the curve. Hold the reserve threshold long enough and the token is loaded into the machine as a prize.", hot: false },
  { n: "03", kicker: "DRAW", title: "The claw picks", body: "Round closes, candidates freeze, Chainlink returns randomness. One qualified token is selected — nobody can nudge it.", hot: true },
  { n: "04", kicker: "WINNER", title: "Pot goes to the prize", body: "The round pot is assigned to the winning token and split across its holders by their share at settlement.", hot: false },
  { n: "05", kicker: "CLAIM", title: "ETH in the chute", body: "Your winnings sit in the vault until you claim them from the dashboard. Real ETH, your transaction, your gas.", hot: false },
];

/** Section 2 of 4 — replaces TwoWaysIn + QualificationRules + ClogMechanicSection + OddsVsPayout.
 *  Deliberately carries NO figures: every number on this page should be live protocol state. */
export function LoopStrip() {
  return (
    <section id="loop" className="flex flex-col gap-5 py-11">
      <div className="flex flex-wrap items-baseline gap-3.5">
        <h2 className="m-0 font-display text-[clamp(24px,3.2vw,34px)] tracking-[-0.02em]">One loop, five moves</h2>
        <span className="font-mono text-meta text-ink-500">EVERY STEP SETTLES ONCHAIN</span>
      </div>
      <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2 xl:grid-cols-5">
        {STEPS.map((s) => (
          <div
            key={s.n}
            className={[
              "flex min-w-0 flex-col gap-2 p-[18px]",
              s.hot
                ? "border border-amber/35 bg-gradient-to-b from-[#16130A] to-[#0B0A07]"
                : "border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800",
            ].join(" ")}
          >
            <span className={`font-mono text-label ${s.n === "05" ? "text-ok" : "text-amber"}`}>
              {s.n} · {s.kicker}
            </span>
            <p className="m-0 font-display text-[17px] tracking-[-0.01em]">{s.title}</p>
            <p className="m-0 text-[13.5px] leading-[1.55] text-ink-400 text-pretty">{s.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
