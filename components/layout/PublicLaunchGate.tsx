"use client";

import { useEffect, useState } from "react";

/**
 * Public launch gate.
 *
 * Before LAUNCH_AT the site shows a full-screen CLOG countdown and the entire
 * application subtree — Web3Provider, MachineHeader, protocol hooks, BasePlate —
 * is never rendered, so none of it mounts or hydrates. At T-0 the running page
 * swaps itself over to the real application with no refresh and no redeploy.
 *
 * Route handlers under /api/... are unaffected: a root layout does not wrap
 * route handlers, so they keep serving through the gate.
 */

/**
 * Exact UTC instant, built from numeric parts via Date.UTC — never parsed from a
 * string. `new Date("2026-09-25T17:00:00Z")` would be correct here, but a bare
 * "YYYY-MM-DD HH:mm" style string is implementation-defined and can be read as
 * local time; using Date.UTC removes that class of bug entirely.
 * Month is 0-indexed: 8 = September.
 */
export const LAUNCH_AT_MS = Date.UTC(2026, 8, 25, 17, 0, 0);

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

function split(remainingMs: number) {
  const t = Math.max(0, remainingMs);
  return {
    days: Math.floor(t / DAY),
    hours: Math.floor((t % DAY) / HOUR),
    minutes: Math.floor((t % HOUR) / MINUTE),
    seconds: Math.floor((t % MINUTE) / SECOND),
  };
}

const pad = (n: number, width = 2) => String(n).padStart(width, "0");

function Unit({ value, label }: { value: string; label: string }) {
  return (
    <div className="flex flex-col items-center gap-2">
      <div
        className="clog-fig rounded-sm border border-edge-hair bg-chassis-700 px-3 py-3 text-3xl tabular-nums text-ink-100 shadow-display sm:px-5 sm:py-4 sm:text-5xl"
        // the digits themselves are decorative relative to the sr-only summary
        // below; announcing them once a second would be unusable with a reader
        aria-hidden="true"
      >
        {value}
      </div>
      <div className="text-label uppercase text-ink-400">{label}</div>
    </div>
  );
}

export function PublicLaunchGate({ children }: { children: React.ReactNode }) {
  /**
   * null on the server AND on the very first client render, so the markup React
   * hydrates against is byte-identical to what the server produced. The clock is
   * only read inside the effect, after hydration has committed — this is what
   * keeps a time-dependent UI free of hydration mismatch.
   */
  const [nowMs, setNowMs] = useState<number | null>(null);

  useEffect(() => {
    const tick = () => setNowMs(Date.now());
    tick(); // paint real digits immediately after hydration
    const id = window.setInterval(tick, SECOND);
    return () => window.clearInterval(id);
  }, []);

  // Once the deadline passes the interval's next tick flips this and the real
  // application renders in place — no refresh, no server restart.
  if (nowMs !== null && nowMs >= LAUNCH_AT_MS) {
    return <>{children}</>;
  }

  const pending = nowMs === null;
  const { days, hours, minutes, seconds } = split(pending ? 0 : LAUNCH_AT_MS - nowMs);

  return (
    <div className="relative flex min-h-screen flex-col items-center justify-center overflow-hidden bg-void px-6 py-16">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-64 bg-marquee-glow" aria-hidden="true" />

      <div className="relative flex w-full max-w-xl flex-col items-center gap-10">
        <div className="flex flex-col items-center gap-3 text-center">
          <h1 className="font-display text-5xl tracking-tight text-ink-100 sm:text-6xl">CLOG</h1>
          <p className="text-meta uppercase text-amber">Launching soon</p>
        </div>

        <div role="timer" aria-live="off" className="flex items-start justify-center gap-3 sm:gap-5">
          <Unit value={pending ? "--" : pad(days)} label="Days" />
          <Unit value={pending ? "--" : pad(hours)} label="Hours" />
          <Unit value={pending ? "--" : pad(minutes)} label="Minutes" />
          <Unit value={pending ? "--" : pad(seconds)} label="Seconds" />
        </div>

        {/* one calm, readable statement for assistive tech instead of a
            per-second barrage from the digits above */}
        <p className="sr-only">
          {pending
            ? "Loading time remaining until launch."
            : `${days} days, ${hours} hours, ${minutes} minutes and ${seconds} seconds until launch.`}
        </p>

        <p className="max-w-sm text-center text-meta leading-relaxed text-ink-400">
          Launch a ticker, qualify it, and let the claw pick.
          <br />
          <span className="clog-fig text-ink-500">2026-09-25 · 17:00 UTC</span>
        </p>
      </div>
    </div>
  );
}
