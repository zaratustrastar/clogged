import { Dices, Coins } from "lucide-react";

export function OddsVsPayout() {
  return (
    <section className="content-container py-16">
      <h2 className="font-display text-2xl font-semibold text-ink sm:text-3xl">Two different things</h2>
      <p className="mt-2 max-w-xl text-sm text-ink-dim">
        This is the most important distinction on CLOG. Keep these separate.
      </p>

      <div className="mt-8 grid gap-5 lg:grid-cols-2">
        <div className="rounded-lg border border-cyan/30 bg-cyan/5 p-6">
          <div className="flex items-center gap-2 text-cyan">
            <Dices size={20} strokeWidth={1.75} />
            <span className="text-xs font-medium uppercase tracking-wide">Chance your meme wins</span>
          </div>
          <p className="mt-3 text-lg font-medium text-ink">All qualified memes have equal odds.</p>
          <div className="mt-4 rounded border border-border bg-surface px-4 py-3">
            <p className="text-xs text-ink-dim">Example</p>
            <p className="mt-1 font-mono text-sm text-ink">
              3 qualified memes = each meme has <span className="text-cyan">1 in 3</span> chance
            </p>
          </div>
          <p className="mt-3 text-xs text-ink-faint">
            Holding more of a meme does not improve its odds of being drawn.
          </p>
        </div>

        <div className="rounded-lg border border-gold/30 bg-gold/5 p-6">
          <div className="flex items-center gap-2 text-gold">
            <Coins size={20} strokeWidth={1.75} />
            <span className="text-xs font-medium uppercase tracking-wide">How much you win if it wins</span>
          </div>
          <p className="mt-3 text-lg font-medium text-ink">
            Holders split the jackpot based on how much and how long they held.
          </p>
          <div className="mt-4 rounded border border-border bg-surface px-4 py-3">
            <p className="text-xs text-ink-dim">Example</p>
            <p className="mt-1 font-mono text-sm text-ink">
              Held 2x longer, same balance = roughly <span className="text-gold">2x</span> the share
            </p>
          </div>
          <p className="mt-3 text-xs text-ink-faint">
            This only changes your payout — never the meme&apos;s chance of being selected.
          </p>
        </div>
      </div>
    </section>
  );
}
