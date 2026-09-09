export function HolderPayoutExplainer() {
  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">HOLD MORE + HOLD LONGER</h3>
      <p className="mt-1.5 text-sm text-ink">= larger share if your meme wins</p>
      <p className="mt-3 text-xs text-ink-dim">
        CLOG tracks balance × time during the round (TWAB — time-weighted average balance) to split
        the jackpot among winning holders.
      </p>
      <p className="mt-2 text-xs text-ink-faint">
        This only affects your share of a win — it does not change the meme&apos;s chance of being
        selected.
      </p>
    </div>
  );
}
