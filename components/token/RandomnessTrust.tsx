const STEPS = ["Round closes", "Candidates freeze", "Chainlink VRF", "Winner", "Claim ETH"];

export function RandomnessTrust() {
  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">HOW THE WINNER IS PICKED</h3>
      <div className="mt-4 flex flex-wrap items-center gap-x-2 gap-y-2 text-xs text-ink-dim">
        {STEPS.map((step, i) => (
          <span key={step} className="flex items-center gap-2">
            <span className={i === 2 ? "font-medium text-cyan" : "text-ink"}>{step}</span>
            {i < STEPS.length - 1 && <span className="text-ink-faint">→</span>}
          </span>
        ))}
      </div>
      <p className="mt-4 text-sm font-medium text-ink">Nobody at CLOG chooses the winner.</p>
      <p className="mt-1.5 text-xs text-ink-faint">
        Randomness comes from Chainlink VRF, relayed cross-chain via Chainlink CCIP.
      </p>
    </div>
  );
}
