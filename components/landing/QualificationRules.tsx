import { TrendingUp, ShieldCheck, Zap } from "lucide-react";
import { MIN_PROGRESS_BPS, MIN_RESERVE_THRESHOLD_ETH, REQUIRED_STREAK_SECONDS } from "@/lib/constants";

const progressPct = MIN_PROGRESS_BPS / 100;
const streakMinutes = REQUIRED_STREAK_SECONDS / 60;

export function QualificationRules() {
  return (
    <section className="border-t border-border bg-surface/40 py-16">
      <div className="content-container">
        <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">
          What your meme must do to enter the draw
        </h2>
        <p className="mt-2 max-w-xl text-sm text-ink-dim">
          Three exact rules. No age requirement, no waiting for a previous round — a meme launched
          minutes ago can qualify for the round that&apos;s open right now.
        </p>

        <div className="mt-8 grid gap-5 lg:grid-cols-3">
          <div className="rounded-lg border border-border bg-surface p-5">
            <div className="flex h-9 w-9 items-center justify-center rounded-md bg-cyan/10 text-cyan">
              <TrendingUp size={18} strokeWidth={1.75} />
            </div>
            <h3 className="mt-4 font-display text-sm font-semibold text-ink">
              Rule 1 — Reach {progressPct}% curve progress
            </h3>
            <p className="mt-1.5 text-sm text-ink-dim">
              Your meme must reach at least {progressPct}% progress on its bonding curve.
            </p>
            <div className="mt-4 h-1.5 w-full overflow-hidden rounded-full bg-border">
              <div className="h-full w-[5%] rounded-full bg-cyan" />
            </div>
            <p className="mt-1.5 font-mono text-xs text-ink-faint">0% → {progressPct}%</p>
          </div>

          <div className="rounded-lg border border-border bg-surface p-5">
            <div className="flex h-9 w-9 items-center justify-center rounded-md bg-gold/10 text-gold">
              <ShieldCheck size={18} strokeWidth={1.75} />
            </div>
            <h3 className="mt-4 font-display text-sm font-semibold text-ink">
              Rule 2 — Hold {MIN_RESERVE_THRESHOLD_ETH} ETH reserve for {streakMinutes} min
            </h3>
            <p className="mt-1.5 text-sm text-ink-dim">
              The market must keep at least {MIN_RESERVE_THRESHOLD_ETH} ETH of real backing for{" "}
              {streakMinutes} continuous minutes.
            </p>
            <div className="mt-4 flex items-center justify-between rounded border border-border bg-surface-raised px-3 py-2 text-xs">
              <span className="text-ink-dim">Reserve held</span>
              <span className="font-mono text-gold">18:42 / {streakMinutes}:00</span>
            </div>
          </div>

          <div className="rounded-lg border border-border bg-surface p-5">
            <div className="flex h-9 w-9 items-center justify-center rounded-md bg-violet/10 text-violet">
              <Zap size={18} strokeWidth={1.75} />
            </div>
            <h3 className="mt-4 font-display text-sm font-semibold text-ink">Rule 3 — Confirm entry</h3>
            <p className="mt-1.5 text-sm text-ink-dim">
              After both rules are met, a new trade or a permissionless qualify action locks your
              meme into the current round.
            </p>
            <div className="mt-4 flex items-center gap-2 rounded border border-violet/30 bg-violet/5 px-3 py-2 text-xs text-violet">
              <span className="h-1.5 w-1.5 rounded-full bg-violet" />
              Ready → Qualified
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
