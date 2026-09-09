export function ClogMechanicSection() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">
        100M tokens stay in CLOG.
      </h2>

      <div className="mt-8 grid gap-6 lg:grid-cols-2 lg:items-center">
        <div className="rounded-lg border border-border bg-surface p-6">
          <p className="text-xs uppercase tracking-wide text-ink-faint">1B total</p>
          <div className="mt-3 flex h-8 w-full overflow-hidden rounded-full bg-border">
            <div className="flex h-full w-[90%] items-center justify-center bg-cyan/70 text-[11px] font-medium text-bg">
              900M
            </div>
            <div className="flex h-full w-[10%] items-center justify-center bg-gold text-[10px] font-medium text-bg">
              100M
            </div>
          </div>
          <div className="mt-2 flex justify-between text-xs">
            <span className="text-cyan">Bonding curve</span>
            <span className="text-gold">CLOG reserve</span>
          </div>
        </div>

        <div>
          <div className="flex items-center gap-3 rounded border border-border bg-surface-raised px-4 py-2.5 text-xs text-ink-dim">
            <span>Previous high 20%</span>
            <span className="text-ink-faint">→</span>
            <span>Falls to 14%</span>
          </div>
          <div className="mt-2 flex items-center gap-3 rounded border border-border bg-surface-raised px-4 py-2.5 text-xs text-ink-dim">
            <span className="font-mono">14% → 20%</span>
            <span className="text-ink-faint">·</span>
            <span>No new CLOG</span>
          </div>
          <div className="mt-2 flex items-center gap-3 rounded border border-gold/30 bg-gold/5 px-4 py-2.5 text-xs text-gold">
            <span className="font-mono">20% → 21%</span>
            <span>·</span>
            <span>New territory → CLOG activates</span>
          </div>
          <p className="mt-4 text-sm text-ink-dim">
            CLOG activates only when buying pushes the curve into new all-time territory.
          </p>
        </div>
      </div>
    </section>
  );
}
