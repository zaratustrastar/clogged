const STEPS = [
  {
    n: 1,
    title: "Launch",
    body: "Claim one of 7,777 unique CLOG tickers.",
  },
  {
    n: 2,
    title: "Qualify",
    body: "Reach 5% curve progress and keep at least 0.229 ETH of real reserve for 30 minutes.",
  },
  {
    n: 3,
    title: "Draw",
    body: "Confirm entry before the hour closes. Every qualified meme gets one equal chance.",
  },
];

export function HowItWorks() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink">How CLOG works</h2>
      <div className="mt-8 grid gap-8 sm:grid-cols-3">
        {STEPS.map((s) => (
          <div key={s.n}>
            <span className="font-mono text-sm text-cyan">{String(s.n).padStart(2, "0")}</span>
            <h3 className="mt-2 font-display text-base font-semibold text-ink">{s.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-ink-dim">{s.body}</p>
          </div>
        ))}
      </div>
      <p className="mt-8 text-sm font-medium text-ink">
        Winning meme holders split the ETH jackpot.
      </p>
    </section>
  );
}
