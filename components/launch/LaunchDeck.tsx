"use client";

import Link from "next/link";
import { PhysicalButton, StatusLamp } from "@/components/machine/PhysicalButton";
import { TX_COPY, TONE_CLASS, type TxMotionState } from "@/components/machine/motion";

/** Maps your existing LaunchPhase onto copy + motion. The phase names are the ones
 *  useLaunchToken already exposes: idle | committing | waiting | revealing | live | error. */
export type LaunchPhase = "idle" | "committing" | "waiting" | "revealing" | "live" | "error";

const PHASE: Record<LaunchPhase, { step: 1 | 2; motion: TxMotionState; label: string; sub: string; btn: string }> = {
  idle: {
    step: 1, motion: "idle", label: "READY",
    sub: "Press to commit the ticker hashed with a salt. Nothing is sent until you sign.",
    btn: "SECURE TICKER",
  },
  committing: {
    step: 1, motion: "awaiting-signature", label: "AWAITING SIGNATURE",
    sub: "Confirm in your wallet. Nothing has been sent yet.",
    btn: "AWAITING WALLET",
  },
  waiting: {
    step: 2, motion: "confirmed", label: "SECURED ONCHAIN",
    sub: "Your commit is confirmed. The reveal delay is the protocol's — it unlocks below, then one more transaction mints. Do not clear site data: the salt lives in this browser.",
    btn: "REVEAL & MINT",
  },
  revealing: {
    step: 2, motion: "pending", label: "REVEALING",
    sub: "Second transaction in flight. This mints the ERC-20 and the TickerNFT together.",
    btn: "REVEALING…",
  },
  live: {
    step: 2, motion: "confirmed", label: "TOKEN IS LIVE",
    sub: "Tradeable on the curve now. It is not a prize yet — it qualifies once the reserve threshold holds long enough.",
    btn: "GO TO TOKEN PAGE",
  },
  error: {
    step: 1, motion: "failed", label: "TRANSACTION FAILED",
    sub: "Nothing was sent. The chain's error is shown below verbatim.",
    btn: "TRY AGAIN",
  },
};

export function LaunchDeck({
  phase,
  errorMessage,
  txHash,
  explorerUrl,
  revealUnlocksIn,
  disabled,
  blockedReason,
  onPrimary,
  tokenHref,
}: {
  phase: LaunchPhase;
  /** pass the hook's error verbatim — never a friendly rewrite */
  errorMessage?: string | null;
  txHash?: string | null;
  explorerUrl?: string | null;
  /** pre-formatted mm:ss from the protocol's own deadline, or null when unlocked */
  revealUnlocksIn?: string | null;
  disabled?: boolean;
  /** Set when `disabled` is true for a reason the person can act on themselves
   *  right now (e.g. an image upload still in flight or failed) - shown as its
   *  own small notice so a disabled REVEAL & MINT button never looks broken or
   *  unexplained. Distinct from errorMessage: this is not a chain/tx error. */
  blockedReason?: string | null;
  onPrimary: () => void;
  tokenHref?: string;
}) {
  const p = PHASE[phase];
  const motion: TxMotionState = disabled ? "disabled" : p.motion;
  const tone = TX_COPY[motion].tone;

  return (
    <div className="mt-3 flex flex-col gap-2.5 rounded-md border border-edge-hard bg-chassis-plate p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <StatusLamp tone={tone} label={p.label} />
        <span className="font-mono text-label text-ink-600">STEP {p.step} OF 2</span>
      </div>

      <p className="m-0 text-[13px] leading-[1.55] text-ink-400 text-pretty">{p.sub}</p>

      {errorMessage ? (
        <p className={`m-0 break-words font-mono text-[11.5px] ${TONE_CLASS.bad}`}>{errorMessage}</p>
      ) : null}

      {blockedReason ? (
        <div className="flex items-center gap-2.5 border border-amber/35 bg-amber/[0.06] p-3">
          <span className={`font-mono text-label ${TONE_CLASS.wait}`}>{blockedReason}</span>
        </div>
      ) : null}

      {txHash ? (
        <div className="flex items-center justify-between gap-2.5 border border-edge-hair bg-chassis-900 px-3 py-2.5">
          <span className="truncate font-mono text-[11.5px] text-ink-100">{txHash}</span>
          {explorerUrl ? (
            <Link href={explorerUrl} target="_blank" rel="noreferrer" className="whitespace-nowrap font-mono text-[10.5px] text-amber">
              view ↗
            </Link>
          ) : null}
        </div>
      ) : null}

      {revealUnlocksIn ? (
        <div className="flex flex-wrap items-center justify-between gap-3 border border-amber/35 bg-amber/[0.06] p-3">
          <span className="font-mono text-label text-amber-dim">REVEAL UNLOCKS IN</span>
          <span className="clog-fig text-[19px] text-amber">{revealUnlocksIn}</span>
        </div>
      ) : null}

      {phase === "live" && tokenHref ? (
        <Link
          href={tokenHref}
          className="rounded-full bg-cap-amber px-5 py-[17px] text-center font-display text-sm tracking-[0.07em] text-amber-ink shadow-cap no-underline"
        >
          {p.btn}
        </Link>
      ) : (
        <PhysicalButton state={motion} onPress={onPrimary} className="w-full">
          {p.btn}
        </PhysicalButton>
      )}

      <p className="m-0 font-mono text-label text-ink-600">COST 0.002 ETH + GAS</p>
    </div>
  );
}
