"use client";

import { useMemo } from "react";

export type MarqueeStat = { label: string; value: string; tone?: "money" | "bulb" | "ok" | "plain" };

const TONE = { money: "text-amber", bulb: "text-bulb", ok: "text-ok", plain: "text-ink-100" } as const;

/** Replaces StatsTicker. Keyframes are global (fix F2) so the track actually moves.
 *  Duplicated once for a seamless -50% loop; the copy is aria-hidden. */
export function MachineMarquee({ stats, seconds = 38 }: { stats: MarqueeStat[]; seconds?: number }) {
  const track = useMemo(
    () => (
      <div className="flex items-center gap-[30px] whitespace-nowrap pr-[30px] font-mono text-meta text-ink-500">
        {stats.map((s) => (
          <span key={s.label} className="flex items-center gap-[30px]">
            <span>
              {s.label} <span className={`clog-fig ${TONE[s.tone ?? "plain"]}`}>{s.value}</span>
            </span>
            <span className="text-edge-hair">/</span>
          </span>
        ))}
      </div>
    ),
    [stats],
  );

  return (
    <div className="flex h-8 items-center overflow-hidden border-t border-edge-inner bg-chassis-800">
      <div
        className="flex w-max animate-clog-marquee"
        style={{ animationDuration: `${seconds}s` }}
      >
        {track}
        <div aria-hidden>{track}</div>
      </div>
    </div>
  );
}
