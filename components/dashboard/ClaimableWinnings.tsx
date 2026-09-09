"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { useClaimReward } from "@/lib/hooks/useProtocolActions";
import { CLAIM_WINDOW_DAYS } from "@/lib/constants";
import type { ClaimableReward } from "@/lib/types";

function ClaimRow({ reward }: { reward: ClaimableReward }) {
  const { execute, status, error } = useClaimReward();
  const [claimed, setClaimed] = useState(false);

  async function onClaim() {
    await execute(reward.roundId);
    setClaimed(true);
  }

  return (
    <div className="rounded border border-gold/30 bg-gold/5 px-4 py-3">
      <div className="flex items-center justify-between">
        <div>
          <p className="font-mono text-lg text-gold">{reward.amountEth.toFixed(4)} ETH</p>
          <p className="text-xs text-ink-dim">
            {reward.ticker} won Round #{reward.roundId}
          </p>
        </div>
        <Button variant="gold" size="md" disabled={claimed || status === "pending"} onClick={onClaim}>
          {claimed ? "Claimed" : status === "pending" ? "Claiming…" : "Claim ETH"}
        </Button>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </div>
  );
}

export function ClaimableWinnings({ rewards }: { rewards: ClaimableReward[] }) {
  if (rewards.length === 0) return null;

  const total = rewards.reduce((sum, r) => sum + r.amountEth, 0);

  return (
    <section className="rounded-lg border border-gold/40 bg-surface p-5 shadow-glow-gold">
      <p className="text-xs font-medium tracking-wide text-gold">YOUR WINNINGS</p>
      <h2 className="mt-1 font-display text-2xl font-semibold text-ink">
        {total.toFixed(4)} ETH claimable
      </h2>
      <p className="mt-1 text-xs text-ink-dim">
        Your reward is reserved onchain until you claim it — nothing is sent automatically. Each
        round has a {CLAIM_WINDOW_DAYS}-day claim window.
      </p>
      <div className="mt-4 flex flex-col gap-2">
        {rewards.map((r) => (
          <ClaimRow key={r.roundId} reward={r} />
        ))}
      </div>
    </section>
  );
}
