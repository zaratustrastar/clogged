import type { ReactNode } from "react";
import type { TxMotionState } from "./motion";

const CABINET_FX: Partial<Record<TxMotionState, string>> = {
  "awaiting-signature": "animate-clog-shake",
  pending: "animate-clog-hum",
  confirmed: "animate-clog-impact",
  failed: "animate-clog-flicker",
};

/** The machine body. Wraps marquee + glass + control deck + chute.
 *  `state` drives the whole-machine reaction; everything else is layout. */
export function Cabinet({
  state = "idle",
  className = "",
  children,
}: {
  state?: TxMotionState;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={`relative rounded-2xl border border-edge-soft bg-chassis-face p-3.5 shadow-chassis ${className}`}
    >
      <div className={CABINET_FX[state] ?? ""}>{children}</div>
    </div>
  );
}

/** Glass sheet. Distortion is clipped to this box and never overlays an input.
 *  overflow-hidden also clips the claw's rod where it leaves the cabinet. */
export function Glass({
  label,
  className = "",
  children,
}: {
  label?: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={`relative overflow-hidden rounded-md border border-edge-hard bg-glass-body ${className}`}>
      <div aria-hidden className="pointer-events-none absolute inset-0 bg-glass-sheen" />
      <div aria-hidden className="pointer-events-none absolute inset-0 bg-glass-scan" />
      {label ? (
        <p className="absolute left-4 top-4 m-0 font-mono text-label text-ink-100/30">{label}</p>
      ) : null}
      {children}
    </div>
  );
}

/** Inset near-black display. Everything financial renders on this, full-opacity, never over sheen. */
export function Display({
  label,
  className = "",
  children,
}: {
  label?: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={`border border-edge-hair bg-chassis-900 p-3 shadow-display ${className}`}>
      {label ? <p className="m-0 font-mono text-label text-ink-500">{label}</p> : null}
      {children}
    </div>
  );
}

/** Raised, pressable plate. Holds primary actions. */
export function ControlDeck({ className = "", children }: { className?: string; children: ReactNode }) {
  return (
    <div className={`rounded-md border border-edge-hard bg-chassis-plate p-4 ${className}`}>{children}</div>
  );
}

/** One-shot CRT tear. Mount with a changing `key` so the animation restarts. */
export function Tear({ fire }: { fire: number }) {
  if (!fire) return null;
  return (
    <div
      key={fire}
      aria-hidden
      className="pointer-events-none absolute left-0 top-0 h-6 w-full animate-clog-tear bg-tear-band mix-blend-screen"
    />
  );
}
