import Link from "next/link";

/** Machine base plate. Replaces Footer. */
export function BasePlate() {
  return (
    <footer className="border-t border-edge-hair bg-chassis-900">
      <div className="mx-auto flex max-w-[1240px] flex-wrap items-center justify-between gap-4 px-5 py-6">
        <p className="m-0 font-mono text-label text-ink-600">
          CLOG · MISFITS BELONG HERE · ROBINHOOD CHAIN MAINNET
        </p>
        <div className="flex gap-[18px] font-mono text-meta">
          <Link href="/explore" className="text-ink-500 no-underline hover:text-ink-100">EXPLORE</Link>
          <Link href="/round" className="text-ink-500 no-underline hover:text-ink-100">THE DRAW</Link>
          <Link href="/launch" className="text-ink-500 no-underline hover:text-ink-100">LAUNCH</Link>
        </div>
      </div>
    </footer>
  );
}
