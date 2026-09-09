"use client";

import { useTokenList } from "@/lib/hooks/useTokenData";
import { useHeldTokens } from "@/lib/hooks/useWalletData";

export function PersonalProbability() {
  const { data: tokens } = useTokenList();
  const { data: holdings } = useHeldTokens();

  if (!tokens || !holdings) return null;

  const qualified = tokens.filter((t) => t.eligibility === "qualified");
  if (qualified.length === 0) return null;

  const heldQualifiedCount = holdings.filter((h) =>
    qualified.some((q) => q.tokenId === h.token.tokenId)
  ).length;

  if (heldQualifiedCount === 0) return null;

  const chancePct = (heldQualifiedCount / qualified.length) * 100;

  return (
    <div className="rounded-lg border border-cyan/30 bg-cyan/5 p-5 shadow-glow-cyan">
      <p className="text-xs font-medium tracking-wide text-cyan">
        YOU HOLD {heldQualifiedCount} OF {qualified.length} QUALIFIED MEMES
      </p>
      <p className="mt-1 font-mono text-4xl text-ink">{chancePct.toFixed(0)}%</p>
      <p className="mt-2 text-sm text-ink-dim">
        Chance that one of the memes you hold wins this draw.
      </p>
      <p className="mt-2 text-xs text-ink-faint">
        If one wins, your personal payout depends on how much and how long you held it.
      </p>
    </div>
  );
}
