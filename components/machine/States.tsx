import type { ReactNode } from "react";

/** No-signal skeleton. Never renders a plausible-looking number. */
export function NoSignal({ lines = 3, className = "" }: { lines?: number; className?: string }) {
  return (
    <div className={`flex flex-col gap-2 ${className}`} aria-busy="true" aria-live="polite">
      {Array.from({ length: lines }).map((_, i) => (
        <div key={i} className="h-3.5 animate-clog-lamp bg-edge-inner" style={{ width: `${92 - i * 14}%` }} />
      ))}
      <span className="sr-only">Loading</span>
    </div>
  );
}

/** Error plate. A failed read is NOT an empty result — say so, and offer retry.
 *  Use this everywhere a read can fail (see patch P0-3). */
export function ErrorPlate({
  title,
  detail,
  onRetry,
}: {
  title: string;
  detail?: string;
  onRetry?: () => void;
}) {
  return (
    <div className="flex flex-col items-start gap-3 border border-bad/40 bg-bad/[0.06] p-5">
      <div className="flex items-center gap-2.5">
        <span aria-hidden className="h-2.5 w-2.5 rounded-full bg-bad shadow-[0_0_10px_#FF6A4D]" />
        <p className="m-0 font-display text-[17px]">{title}</p>
      </div>
      {detail ? <p className="m-0 max-w-[60ch] font-mono text-[11px] text-bad">{detail}</p> : null}
      {onRetry ? (
        <button
          onClick={onRetry}
          className="border border-edge-hard bg-chassis-600 px-4 py-2.5 font-mono text-meta text-ink-100"
        >
          RETRY READ
        </button>
      ) : null}
    </div>
  );
}

/** Empty chute. Quiet on purpose — no zeros dressed up as results. */
export function EmptyChute({ label, body, children }: { label: string; body: string; children?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-2.5">
      <span aria-hidden className="h-[50px] w-[50px] rounded-xl bg-prize-empty" />
      <p className="m-0 font-mono text-meta text-ink-400">{label}</p>
      <p className="m-0 max-w-[56ch] text-[13.5px] leading-[1.55] text-ink-500 text-pretty">{body}</p>
      {children}
    </div>
  );
}
