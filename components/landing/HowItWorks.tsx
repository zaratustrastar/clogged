import { LAUNCH_PRICE_ETH } from "@/lib/constants";

const STEPS = [
  {
    n: 1,
    title: "Launch",
    body: `Pay ${LAUNCH_PRICE_ETH} ETH to launch a meme. It gets a fixed 1B supply — 900M in a bonding curve, 100M held in reserve — and you get the TickerNFT.`,
  },
  {
    n: 2,
    title: "Build activity",
    body: "Not every token qualifies automatically. A token needs sustained real trading — enough reserve, held long enough — before it's in the running.",
  },
  {
    n: 3,
    title: "Qualify",
    body: "Once a token clears that bar, it's locked in as a candidate for the next hourly draw, alongside every other qualified token.",
  },
  {
    n: 4,
    title: "Draw & win",
    body: "One qualified token is picked at random each hour — equal odds for all. If it's yours, holders from that round split the ETH pot by how much and how long they held.",
  },
];

export function HowItWorks() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink">How CLOG works</h2>
      <div className="mt-8 grid gap-8 sm:grid-cols-2 lg:grid-cols-4">
        {STEPS.map((s) => (
          <div key={s.n}>
            <span className="font-mono text-sm text-cyan">{String(s.n).padStart(2, "0")}</span>
            <h3 className="mt-2 font-display text-base font-semibold text-ink">{s.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-ink-dim">{s.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
