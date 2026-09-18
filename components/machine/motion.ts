/** The one motion state machine. Derived from real hook output only. */

export type TxMotionState =
  | "idle"
  | "hover"
  | "pressed"
  | "awaiting-signature"
  | "pending"
  | "confirmed"
  | "failed"
  | "disabled";

/** Maps the repo's existing TxStatus (+ hash) onto motion state. No timers, no optimism.
 *  Call with exactly what useProtocolActions already returns — do not add reads. */
export function txMotionState(args: {
  status: "idle" | "pending" | "success" | "error";
  hash?: `0x${string}` | null;
  disabled?: boolean;
}): TxMotionState {
  if (args.disabled) return "disabled";
  switch (args.status) {
    case "pending":
      return args.hash ? "pending" : "awaiting-signature";
    case "success":
      return "confirmed";
    case "error":
      return "failed";
    default:
      return "idle";
  }
}

export const LAMP: Record<string, string> = {
  building: "bg-ink-500",
  qualifying: "bg-amber animate-clog-lamp",
  ready: "bg-amber animate-clog-lamp-fast",
  qualified: "bg-ok",
  winner: "bg-bulb",
  failed: "bg-bad",
};

/** Words for every state — motion is never the only signal. */
export const TX_COPY: Record<TxMotionState, { label: string; tone: "neutral" | "wait" | "ok" | "bad" }> = {
  idle: { label: "Ready", tone: "neutral" },
  hover: { label: "Ready", tone: "neutral" },
  pressed: { label: "Ready", tone: "neutral" },
  "awaiting-signature": { label: "Awaiting signature — confirm in your wallet", tone: "wait" },
  pending: { label: "Transaction pending — waiting for receipt", tone: "wait" },
  confirmed: { label: "Confirmed onchain", tone: "ok" },
  failed: { label: "Transaction failed", tone: "bad" },
  disabled: { label: "Unavailable", tone: "neutral" },
};

export const TONE_CLASS = {
  neutral: "text-ink-300",
  wait: "text-amber",
  ok: "text-ok",
  bad: "text-bad",
} as const;
