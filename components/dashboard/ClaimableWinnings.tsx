"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { useClaimReward } from "@/lib/hooks/useProtocolActions";
import type { ClaimableReward } from "@/lib/types";

function ClaimRow({ reward }: { reward: ClaimableReward }) {
  const { execute, status } = useClaimReward();
  const [claimed, setClaimed] = useState(false);

  async function onClaim() {
    await execute(reward.roundId);
    setClaimed(true);
  }

  return (
    <div className="flex items-center justify-between rounded border border-gold/30 bg-gold/5 px-4 py-3">
      <div>
        <p className="font-mono text-lg text-gold">{reward.amountEth.toFixed(3)} ETH</p>
        <p className="text-xs text-ink-dim">
          {reward.ticker} won Round #{reward.roundId}
        </p>
      </div>
      <Button variant="gold" size="md" disabled={claimed || status === "pending"} onClick={onClaim}>
        {claimed ? "Claimed" : status === "pending" ? "Claiming…" : "Claim winnings"}
      </Button>
    </div>
  );
}

export function ClaimableWinnings({ rewards }: { rewards: ClaimableReward[] }) {
  if (rewards.length === 0) return null;

  const total = rewards.reduce((sum, r) => sum + r.amountEth, 0);

  return (
    <section className="rounded-md border border-gold/40 bg-surface p-5">
      <div className="flex items-baseline justify-between">
        <h2 className="font-display text-base font-semibold text-ink">
          {total.toFixed(3)} ETH ready to claim
        </h2>
      </div>
      <p className="mt-1 text-xs text-ink-dim">
        Winnings aren&apos;t sent automatically — claim them below. Each has a 90-day window.
      </p>
      <div className="mt-4 flex flex-col gap-2">
        {rewards.map((r) => (
          <ClaimRow key={r.roundId} reward={r} />
        ))}
      </div>
    </section>
  );
}
