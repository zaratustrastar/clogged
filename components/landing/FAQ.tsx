import { CLAIM_WINDOW_DAYS, MIN_DRAW_CANDIDATES } from "@/lib/constants";

const FAQS = [
  {
    q: "Can a newly launched meme qualify this hour?",
    a: "Yes. There's no minimum token age and no waiting for a previous round to complete — a meme launched minutes ago can qualify for the round that's currently open, including the very first round the protocol ever runs.",
  },
  {
    q: `What happens if fewer than ${MIN_DRAW_CANDIDATES} memes qualify?`,
    a: `There's no winner that round. The jackpot rolls forward and keeps accumulating until a round closes with at least ${MIN_DRAW_CANDIDATES} qualified memes.`,
  },
  {
    q: "Does holding more improve the meme's odds?",
    a: "No. A meme's chance of being drawn depends only on whether it's qualified — every qualified meme has exactly equal odds, regardless of market cap or holder count. Holding more only affects your share of the reward if that meme wins.",
  },
  {
    q: "When can rewards be claimed?",
    a: `Anytime after the round settles, from your dashboard. There's a ${CLAIM_WINDOW_DAYS}-day window to claim after a round resolves.`,
  },
  {
    q: "Can the TickerNFT be sold?",
    a: "Yes, on OpenSea. Selling it transfers the ticker-owner fee rights to the new owner — CLOG doesn't run its own NFT marketplace.",
  },
  {
    q: "Why is CLOG reserved?",
    a: "CLOG is permanently reserved as a ticker. The official $CLOG token launches separately, on Pons.",
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
