"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import type { TxMotionState } from "./motion";

/** Physical button with real travel and spring return.
 *  Depressed while the wallet holds the transaction — the cap stays down until
 *  the chain answers, which is the honest read of "we are waiting on you". */
export function PhysicalButton({
  state = "idle",
  onPress,
  onTear,
  type = "button",
  children,
  className = "",
}: {
  state?: TxMotionState;
  onPress?: () => void;
  onTear?: () => void;
  type?: "button" | "submit";
  children: ReactNode;
  className?: string;
}) {
  const [down, setDown] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout>>();

  useEffect(() => () => clearTimeout(timer.current), []);

  const held = state === "awaiting-signature" || state === "pending";
  const disabled = state === "disabled";
  const pressed = down || held;

  return (
    <button
      type={type}
      disabled={disabled}
      aria-busy={held}
      onPointerDown={() => {
        if (disabled) return;
        setDown(true);
        onTear?.();
        clearTimeout(timer.current);
        timer.current = setTimeout(() => setDown(false), 160);
      }}
      onClick={onPress}
      className={[
        "rounded-full px-7 py-[19px] font-display text-[15px] tracking-[0.07em] text-amber-ink",
        "bg-cap-amber transition-[transform,box-shadow] duration-[80ms] ease-out",
        pressed ? "translate-y-[6px] shadow-cap-down" : "shadow-cap",
        disabled ? "cursor-not-allowed opacity-40 saturate-0" : "cursor-pointer",
        className,
      ].join(" ")}
    >
      {children}
    </button>
  );
}

/** Status lamp + its words. Never ships without the label. */
export function StatusLamp({ tone, label }: { tone: "neutral" | "wait" | "ok" | "bad"; label: string }) {
  const bulb = {
    neutral: "bg-amber animate-clog-lamp",
    wait: "bg-amber animate-clog-lamp-fast",
    ok: "bg-ok",
    bad: "bg-bad animate-clog-flicker",
  }[tone];
  const ink = { neutral: "text-ink-400", wait: "text-amber", ok: "text-ok", bad: "text-bad" }[tone];
  return (
    <span className="flex min-w-0 items-center gap-2">
      <span aria-hidden className={`h-2.5 w-2.5 flex-none rounded-full shadow-[0_0_9px_currentColor] ${bulb}`} />
      <span className={`font-mono text-meta ${ink}`}>{label}</span>
    </span>
  );
}
