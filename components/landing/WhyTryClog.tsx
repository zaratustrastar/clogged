import { Ticket, Scale, Clock, Wallet2 } from "lucide-react";

const CARDS = [
  {
    icon: Ticket,
    title: "Unique ticker",
    body: "You're not just launching a meme. You're claiming a ticker.",
  },
  {
    icon: Scale,
    title: "Equal draw odds",
    body: "Whales don't buy better meme odds. Qualified memes enter equally.",
  },
  {
    icon: Clock,
    title: "Hourly rounds",
    body: "There's always a next round to watch.",
  },
  {
    icon: Wallet2,
    title: "Onchain rewards",
    body: "If your meme wins, holders claim ETH onchain.",
  },
];

export function WhyTryClog() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">Why people will try CLOG</h2>
      <div className="mt-8 grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
        {CARDS.map((c) => (
          <div
            key={c.title}
            className="rounded-lg border border-border bg-surface p-5 transition-colors hover:border-violet/40"
          >
            <div className="flex h-9 w-9 items-center justify-center rounded-md bg-violet/10 text-violet">
              <c.icon size={18} strokeWidth={1.75} />
            </div>
            <h3 className="mt-4 font-display text-sm font-semibold text-ink">{c.title}</h3>
            <p className="mt-1.5 text-sm text-ink-dim">{c.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
