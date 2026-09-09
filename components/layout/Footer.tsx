import Link from "next/link";

export function Footer() {
  return (
    <footer className="border-t border-border">
      <div className="content-container flex flex-col items-center justify-between gap-3 py-6 text-xs text-ink-faint sm:flex-row">
        <span>CLOG is an independent protocol. Official $CLOG launches on Pons — not through this app.</span>
        <div className="flex gap-4">
          <Link href="/explore" className="hover:text-ink-dim">
            Explore
          </Link>
          <Link href="/launch" className="hover:text-ink-dim">
            Launch
          </Link>
          <Link href="/dashboard" className="hover:text-ink-dim">
            Dashboard
          </Link>
        </div>
      </div>
    </footer>
  );
}
