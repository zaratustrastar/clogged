"use client";

import { useNow } from "@/lib/hooks/useNow";
import { formatCountdown } from "@/lib/format";
import clsx from "clsx";

export function CountdownClock({
  targetIso,
  size = "lg",
}: {
  targetIso: string;
  size?: "lg" | "md";
}) {
  const now = useNow();
  const display = formatCountdown(targetIso, now);
  const isClosing = new Date(targetIso).getTime() - now < 5 * 60_000;

  return (
    <span
      className={clsx(
        "font-mono tabular tracking-tight",
        size === "lg" ? "text-6xl sm:text-7xl" : "text-2xl",
        isClosing ? "text-gold" : "text-ink"
      )}
    >
      {display}
    </span>
  );
}
