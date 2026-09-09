const FAQS = [
  {
    q: "Does holding more of a token improve its chance of winning?",
    a: "No. A token's chance of being drawn depends only on whether it's qualified — every qualified token has exactly equal odds, regardless of its market cap or holder count. Holding more only affects your share of the reward if that token wins.",
  },
  {
    q: "What makes a token qualify?",
    a: "A token needs to be past its first hour, have made meaningful progress through its bonding curve, and hold enough real reserve continuously for 30 minutes. Once it clears that bar, it's in the running for the next draw.",
  },
  {
    q: "How is the reward split if a token wins?",
    a: "Holders of the winning token from that specific round split the ETH pot in proportion to how much they held and for how long during the round (time-weighted average balance) — not by wallet count, and not by who bought first.",
  },
  {
    q: "Are rewards sent automatically?",
    a: "No. Winnings sit in the reward vault until you claim them from your dashboard. There's a 90-day window to claim after a round resolves.",
  },
  {
    q: "Can I trade the ticker itself, not just the token?",
    a: "Each ticker has an ownership NFT that earns a share of that token's trading fees. You can trade that NFT on OpenSea — CLOG doesn't run its own NFT marketplace.",
  },
  {
    q: "Why can't I launch a token called CLOG?",
    a: "CLOG is permanently reserved. The official $CLOG token launches separately, on Pons.",
  },
];

export function FAQ() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink">Frequently asked</h2>
      <div className="mt-6 divide-y divide-border rounded-md border border-border">
        {FAQS.map((f) => (
          <details key={f.q} className="group px-5 py-4">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-sm font-medium text-ink">
              {f.q}
              <span className="shrink-0 text-ink-faint transition-transform group-open:rotate-45">+</span>
            </summary>
            <p className="mt-3 text-sm leading-relaxed text-ink-dim">{f.a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}
