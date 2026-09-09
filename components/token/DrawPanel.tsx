"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { useRoundStatus, useTokenList } from "@/lib/hooks/useTokenData";
import { useQualifyToken } from "@/lib/hooks/useProtocolActions";
import { MIN_PROGRESS_BPS, MIN_RESERVE_THRESHOLD_ETH, REQUIRED_STREAK_SECONDS, MIN_DRAW_CANDIDATES } from "@/lib/constants";
import type { TokenDetail } from "@/lib/types";

function Row({ done, label, value }: { done: boolean; label: string; value: string }) {
  return (
    <div className="flex items-center justify-between text-sm">
      <span className={done ? "text-cyan" : "text-ink-dim"}>
        {done ? "✓" : "○"} {label}
      </span>
      <span className="font-mono tabular text-ink">{value}</span>
    </div>
  );
}

export function DrawPanel({ token }: { token: TokenDetail }) {
  const { data: round } = useRoundStatus();
  const { data: allTokens } = useTokenList();
  const qualify = useQualifyToken();
  const [justQualified, setJustQualified] = useState(false);

  const qualifiedTokens = allTokens?.filter((t) => t.eligibility === "qualified") ?? [];
  const qualifiedCount = qualifiedTokens.length;

  // Two genuinely independent gates - see EligibilityRegistry.sol's
  // _touch/_maybeQualify. Gate A (progress) is checked at confirmation time
  // and can go down if the token is sold heavily - it is not a permanent
  // high-water mark. Gate B (reserve) drives the 30-minute timer, which
  // resets to zero the instant real reserve dips below the threshold.
  const progressMet = token.curveProgressPct >= MIN_PROGRESS_BPS / 100;
  const reserveMet = token.realReserveEth >= MIN_RESERVE_THRESHOLD_ETH;
  const elapsed = token.eligibleSinceSeconds
    ? Math.max(0, Math.floor(Date.now() / 1000) - token.eligibleSinceSeconds)
    : 0;
  const streakMet = reserveMet && elapsed >= REQUIRED_STREAK_SECONDS;

  const progressRow = (
    <Row done={progressMet} label="Curve progress" value={`${token.curveProgressPct.toFixed(1)}% / 5%`} />
  );
  const reserveRow = (
    <Row
      done={reserveMet}
      label="Real reserve"
      value={`${token.realReserveEth.toFixed(2)} / ${MIN_RESERVE_THRESHOLD_ETH} ETH`}
    />
  );

  async function onQualify() {
    await qualify.execute(token.tokenId);
    setJustQualified(true);
  }

  if (token.eligibility === "qualified" || justQualified) {
    return (
      <div className="rounded-md border border-cyan/30 bg-cyan/5 p-5">
        <h3 className="font-display text-sm font-semibold text-cyan">QUALIFIED</h3>
        <p className="mt-1.5 text-sm text-ink">
          {token.ticker} is in the{" "}
          {round ? new Date(round.closesAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "upcoming"}{" "}
          draw
        </p>
        <div className="mt-3 flex items-baseline justify-between rounded border border-border bg-surface-raised px-3 py-2">
          <span className="text-xs text-ink-dim">{qualifiedCount} memes qualified</span>
          <span className="font-mono text-lg text-ink">
            {token.ticker} chance: 1 / {qualifiedCount || "—"}
            {qualifiedCount > 0 && (
              <span className="ml-1 text-sm text-ink-dim">
                · {(100 / qualifiedCount).toFixed(1)}%
              </span>
            )}
          </span>
        </div>
        <p className="mt-2 text-xs text-ink-faint">
          Holding more {token.ticker} does not change this chance — every qualified meme has exactly
          one equal entry.
        </p>
      </div>
    );
  }

  if (streakMet && progressMet) {
    return (
      <div className="rounded-md border border-gold/40 bg-gold/5 p-5">
        <h3 className="font-display text-sm font-semibold text-gold">READY TO ENTER</h3>
        <div className="mt-3 flex flex-col gap-1.5">
          {progressRow}
          {reserveRow}
          <Row done={true} label="Reserve held" value="30:00 / 30:00" />
          <Row done={false} label="Entry" value="Ready" />
        </div>
        {qualify.error && <p className="mt-3 text-xs text-danger">{qualify.error}</p>}
        <Button fullWidth size="lg" className="mt-4" onClick={onQualify} disabled={qualify.status === "pending"}>
          {qualify.status === "pending" ? "Confirm in wallet…" : "Qualify now"}
        </Button>
        <p className="mt-2 text-xs text-ink-faint">A normal buy or sell also confirms entry automatically.</p>
      </div>
    );
  }

  if (reserveMet) {
    const pct = Math.min(100, (elapsed / REQUIRED_STREAK_SECONDS) * 100);
    const heldM = Math.floor(elapsed / 60);
    const heldS = elapsed % 60;
    const remaining = REQUIRED_STREAK_SECONDS - elapsed;
    return (
      <div className="rounded-md border border-border bg-surface p-5">
        <h3 className="font-display text-sm font-semibold text-ink">ENTER THIS HOUR&apos;S DRAW</h3>
        <div className="mt-3 flex flex-col gap-1.5">
          {progressRow}
          {reserveRow}
          <Row
            done={false}
            label="Reserve held"
            value={`${String(heldM).padStart(2, "0")}:${String(heldS).padStart(2, "0")} / 30:00`}
          />
          <Row done={false} label="Entry" value="Waiting" />
        </div>
        <div className="mt-3 h-1.5 w-full overflow-hidden rounded-full bg-border">
          <div className="h-full rounded-full bg-cyan" style={{ width: `${pct}%` }} />
        </div>
        <p className="mt-3 font-mono text-2xl tabular text-ink">
          {String(Math.floor(remaining / 60)).padStart(2, "0")}:{String(remaining % 60).padStart(2, "0")} remaining
        </p>
        <p className="mt-2 text-xs text-ink-dim">
          Keep at least {MIN_RESERVE_THRESHOLD_ETH} ETH of real reserve until the timer finishes. If
          it drops below that, the timer resets.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <h3 className="font-display text-sm font-semibold text-ink">ENTER THIS HOUR&apos;S DRAW</h3>
      <div className="mt-3 flex flex-col gap-1.5">
        {progressRow}
        {reserveRow}
        <Row done={false} label="Reserve held" value="Not started" />
        <Row done={false} label="Entry" value="Waiting" />
      </div>
      <p className="mt-3 text-xs text-ink-dim">
        Increase real reserve to at least {MIN_RESERVE_THRESHOLD_ETH} ETH to start the 30-minute
        timer.
      </p>
      {qualifiedCount < MIN_DRAW_CANDIDATES && (
        <p className="mt-2 text-xs text-ink-faint">
          {qualifiedCount} / {MIN_DRAW_CANDIDATES} memes qualified this round. If fewer than{" "}
          {MIN_DRAW_CANDIDATES} qualify before the hour closes, there is no winner and the jackpot
          rolls forward.
        </p>
      )}
    </div>
  );
}
