"use client";

import { Button } from "@/components/ui/Button";

/** Shown when useClaimableRewards' underlying query (or its upstream
 * useRoundHistory scan) failed - e.g. the Robinhood public RPC rate
 * limiting a round-history scan (429 Too Many Requests). Deliberately
 * distinct from simply rendering nothing: a real fetch failure must never
 * look identical to "you have no winnings", since the person's actual,
 * real winnings could be sitting unclaimed onchain the whole time with no
 * visible indication anything went wrong. */
export function ClaimableWinningsError({ onRetry }: { onRetry: () => void }) {
  return (
    <section role="alert" className="rounded-lg border border-danger/40 bg-danger/5 p-5">
      <p className="text-xs font-medium tracking-wide text-danger">UNABLE TO LOAD WINNINGS</p>
      <p className="mt-1 text-sm text-ink-dim">
        Couldn&apos;t check whether you have ETH to claim - this is usually a temporary network
        issue, not a sign you have no winnings.
      </p>
      <Button variant="secondary" size="sm" className="mt-3" onClick={onRetry}>
        Retry
      </Button>
    </section>
  );
}
