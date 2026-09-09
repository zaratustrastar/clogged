import { MIN_PROGRESS_BPS, MIN_RESERVE_THRESHOLD_ETH, REQUIRED_STREAK_SECONDS } from "@/lib/constants";

const progressPct = MIN_PROGRESS_BPS / 100;
const streakMinutes = REQUIRED_STREAK_SECONDS / 60;

export function QualificationRules() {
  return (
    <section className="border-t border-border bg-surface/40 py-16">
      <div className="content-container">
        <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">Get into the draw</h2>
        <p className="mt-2 text-sm text-ink-dim">A meme passes three checks.</p>

        <div className="mt-8 grid gap-5 lg:grid-cols-3">
          {/* 01 - curve progress */}
          <div className="rounded-lg border border-border bg-surface p-5">
            <span className="font-mono text-xs text-ink-faint">01</span>
            <h3 className="mt-1 font-display text-sm font-semibold text-ink">
              {progressPct}% CURVE PROGRESS
            </h3>
            <p className="mt-1.5 text-sm text-ink-dim">Reach the {progressPct}% entry line.</p>

            <div className="mt-5">
              <div className="relative h-1.5 w-full rounded-full bg-border">
                <div className="h-full w-[84%] rounded-full bg-cyan" />
                <div className="absolute -top-1 left-[84%] h-3.5 w-px bg-ink" />
              </div>
              <div className="mt-1.5 flex justify-between font-mono text-[11px] text-ink-faint">
                <span>0%</span>
                <span className="text-ink">{progressPct}%</span>
              </div>
            </div>
            <p className="mt-3 flex items-center gap-1.5 font-mono text-sm text-cyan">
              5.7% <span className="text-xs">✓</span>
            </p>
          </div>

          {/* 02 - real reserve */}
          <div className="rounded-lg border border-border bg-surface p-5">
            <span className="font-mono text-xs text-ink-faint">02</span>
            <h3 className="mt-1 font-display text-sm font-semibold text-ink">
              {MIN_RESERVE_THRESHOLD_ETH} ETH RESERVE
            </h3>
            <p className="mt-1.5 text-sm text-ink-dim">
              Keep at least {MIN_RESERVE_THRESHOLD_ETH} ETH of real reserve for {streakMinutes} minutes.
            </p>

            <div className="mt-5 rounded border border-border bg-surface-raised px-3 py-2.5">
              <div className="flex items-baseline justify-between">
                <span className="text-[11px] text-ink-faint">Real reserve</span>
                <span className="font-mono text-sm text-gold">0.31 ETH ✓</span>
              </div>
              <div className="relative mt-2 h-1.5 w-full rounded-full bg-border">
                <div className="h-full w-[100%] rounded-full bg-gold" />
                <div className="absolute -top-1 left-[74%] h-3.5 w-px bg-ink-faint" />
              </div>
              <p className="mt-1 font-mono text-[10px] text-ink-faint">
                {MIN_RESERVE_THRESHOLD_ETH} ETH minimum
              </p>
            </div>
            <p className="mt-3 font-mono text-sm text-ink">18:42 / {streakMinutes}:00</p>
            <p className="mt-1 text-[11px] text-ink-faint">
              Below {MIN_RESERVE_THRESHOLD_ETH} ETH → timer resets.
            </p>
          </div>

          {/* 03 - confirm entry */}
          <div className="rounded-lg border border-border bg-surface p-5">
            <span className="font-mono text-xs text-ink-faint">03</span>
            <h3 className="mt-1 font-display text-sm font-semibold text-ink">CONFIRM ENTRY</h3>
            <p className="mt-1.5 text-sm text-ink-dim">
              Once both checks pass, a trade or Qualify call confirms entry.
            </p>

            <div className="mt-5 flex flex-col items-center gap-1.5">
              <span className="w-full rounded border border-border bg-surface-raised px-3 py-2 text-center text-xs font-medium text-ink-dim">
                READY
              </span>
              <span className="text-ink-faint">↓</span>
              <span className="w-full rounded border border-cyan/30 bg-cyan/5 px-3 py-2 text-center text-xs font-medium text-cyan">
                QUALIFIED
              </span>
              <span className="text-ink-faint">↓</span>
              <span className="w-full rounded border border-gold/30 bg-gold/5 px-3 py-2 text-center text-xs font-medium text-gold">
                14:00 DRAW
              </span>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
