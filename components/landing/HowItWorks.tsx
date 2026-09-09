import { Rocket, Timer, Dices, Trophy, Wallet } from "lucide-react";

const STEPS = [
  {
    icon: Rocket,
    title: "Launch",
    body: "Pick a unique ticker and launch your meme.",
  },
  {
    icon: Timer,
    title: "Qualify",
    body: "Reach the entry rules while the hour is open.",
  },
  {
    icon: Dices,
    title: "Draw",
    body: "All qualified memes go into one Chainlink-powered draw.",
  },
  {
    icon: Trophy,
    title: "Win",
    body: "One meme wins the ETH jackpot.",
  },
  {
    icon: Wallet,
    title: "Claim",
    body: "Holders of the winning meme claim their share onchain.",
  },
];

export function HowItWorks() {
  return (
    <section id="how-it-works" className="content-container py-16">
      <div className="mb-10 flex items-end justify-between">
        <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">How CLOG works</h2>
        <span className="hidden text-xs text-ink-faint sm:block">One loop, every hour</span>
      </div>

      <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-5">
        {STEPS.map((s, i) => (
          <div key={s.title} className="relative">
            <div className="flex h-full flex-col rounded-lg border border-border bg-surface p-5 transition-colors hover:border-cyan/40">
              <div className="flex h-10 w-10 items-center justify-center rounded-md bg-cyan/10 text-cyan">
                <s.icon size={20} strokeWidth={1.75} />
              </div>
              <div className="mt-4 flex items-baseline gap-2">
                <span className="font-mono text-xs text-ink-faint">{i + 1}</span>
                <h3 className="font-display text-base font-semibold text-ink">{s.title}</h3>
              </div>
              <p className="mt-1.5 text-sm leading-relaxed text-ink-dim">{s.body}</p>
            </div>
            {i < STEPS.length - 1 && (
              <span className="pointer-events-none absolute -right-4 top-1/2 z-10 hidden -translate-y-1/2 text-ink-faint lg:block">
                →
              </span>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}
