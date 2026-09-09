"use client";

import { useState } from "react";
import { MIN_DRAW_CANDIDATES } from "@/lib/constants";

const STEPS = ["Round closes", "Candidates freeze", "Chainlink VRF", "Winner", "Claim ETH"];

export function RandomnessTrust() {
  const [showTechnical, setShowTechnical] = useState(false);

  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-2 text-xs text-ink-dim">
        {STEPS.map((step, i) => (
          <span key={step} className="flex items-center gap-2">
            <span className={i === 2 ? "font-medium text-violet" : "text-ink"}>{step}</span>
            {i < STEPS.length - 1 && <span className="text-ink-faint">→</span>}
          </span>
        ))}
      </div>
      <p className="mt-4 text-sm text-ink-dim">
        The candidate list freezes first. Chainlink provides the randomness after.
      </p>
      <p className="mt-2 text-xs text-ink-faint">
        Fewer than {MIN_DRAW_CANDIDATES} qualified memes → no winner → jackpot rolls forward.
      </p>

      <button
        onClick={() => setShowTechnical((v) => !v)}
        className="mt-3 text-xs font-medium text-violet hover:underline"
      >
        {showTechnical ? "Hide technical details" : "Technical details"}
      </button>
      {showTechnical && (
        <p className="mt-2 text-xs text-ink-faint">
          Randomness is generated through Chainlink VRF and relayed to Robinhood Chain through
          Chainlink CCIP.
        </p>
      )}
    </div>
  );
}
