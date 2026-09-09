export function OddsVsPayout() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">
        Same odds. Different shares.
      </h2>
      <p className="mt-2 text-sm text-ink-dim">The meme&apos;s odds and your payout are separate.</p>

      <div className="mt-8 grid gap-5 lg:grid-cols-2">
        <div className="rounded-lg border border-cyan/30 bg-cyan/5 p-6">
          <p className="text-xs font-medium uppercase tracking-wide text-cyan">Meme odds</p>
          <p className="mt-2 font-mono text-5xl font-semibold text-ink">1 / 8</p>
          <p className="mt-2 text-sm text-ink-dim">If 8 memes qualify, each has the same chance.</p>

          <div className="mt-4 flex flex-col gap-1 font-mono text-xs text-ink-dim">
            <div className="flex justify-between">
              <span>CAT</span>
              <span className="text-cyan">1/8</span>
            </div>
            <div className="flex justify-between">
              <span>DOG</span>
              <span className="text-cyan">1/8</span>
            </div>
            <div className="flex justify-between">
              <span>PEPE</span>
              <span className="text-cyan">1/8</span>
            </div>
            <div className="text-ink-faint">…</div>
          </div>
          <p className="mt-4 text-xs text-ink-faint">Buying more CAT does not improve CAT&apos;s draw odds.</p>
        </div>

        <div className="rounded-lg border border-gold/30 bg-gold/5 p-6">
          <p className="text-xs font-medium uppercase tracking-wide text-gold">Your share</p>
          <p className="mt-2 font-mono text-3xl font-semibold text-ink">BALANCE × TIME</p>
          <p className="mt-2 text-sm text-ink-dim">
            If CAT wins, holders split the jackpot based on how much and how long they held.
          </p>

          <div className="mt-4 flex items-center justify-between rounded border border-border bg-surface px-4 py-3 font-mono text-xs text-ink-dim">
            <span>1M CAT × 60 min</span>
            <span className="text-ink-faint">vs</span>
            <span>1M CAT × 30 min</span>
          </div>
          <p className="mt-2 text-center font-mono text-sm text-gold">≈ 2× reward weight</p>
          <p className="mt-4 text-xs text-ink-faint">
            More balance or more time changes your share, not the meme&apos;s odds.
          </p>
        </div>
      </div>
    </section>
  );
}
