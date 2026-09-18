"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useState } from "react";
import { MachineMarquee, type MarqueeStat } from "@/components/landing/MachineMarquee"; // handoff's own file lives under components/landing/, not alongside this file - the relative "./MachineMarquee" was wrong

/* Replaces Navbar + StatsTicker. The marquee is riveted to the top of the cabinet.
 * Wire stats from useRoundStatus() — pass "—" for anything still loading and OMIT
 * any stat you cannot source. Never ship a hardcoded "—" as if it were a real read
 * (that is the current marquee's Volume field, issue P2). */

const NAV = [
  { href: "/explore", label: "EXPLORE" },
  { href: "/round", label: "THE DRAW" },
  { href: "/dashboard", label: "DASHBOARD" },
];

export function MachineHeader({ stats }: { stats?: MarqueeStat[] }) {
  const pathname = usePathname();
  const router = useRouter();
  const [q, setQ] = useState("");

  return (
    <header className="sticky top-0 z-40 border-b border-edge-hair bg-chassis-900/[0.94] backdrop-blur-lg">
      <div className="mx-auto flex max-w-[1240px] flex-wrap items-center gap-4 px-5 py-3">
        <Link href="/" className="font-display text-[22px] tracking-[0.04em] text-ink-200 no-underline">
          CLOG
        </Link>

        <nav className="ml-2 flex flex-wrap gap-1">
          {NAV.map((n) => {
            const active = pathname === n.href || pathname.startsWith(n.href + "/");
            return (
              <Link
                key={n.href}
                href={n.href}
                className={`px-[11px] py-2 font-mono text-[12px] tracking-[0.08em] no-underline ${
                  active ? "text-amber" : "text-ink-400 hover:text-ink-100"
                }`}
              >
                {n.label}
              </Link>
            );
          })}
        </nav>

        <div className="flex-1 basis-8" />

        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (q.trim()) router.push(`/explore?q=${encodeURIComponent(q.trim())}`);
          }}
          className="hidden md:block"
        >
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="search ticker"
            aria-label="Search tickers"
            className="w-[180px] border border-edge-hair bg-chassis-800 px-3 py-2 font-mono text-[12px] text-ink-100 outline-none placeholder:text-ink-600"
          />
        </form>

        <Link
          href="/launch"
          className="border border-edge-hard bg-chassis-600 px-3.5 py-2.5 font-mono text-[12px] tracking-[0.08em] text-ink-100 no-underline"
        >
          LAUNCH TOKEN
        </Link>

        {/* Reown AppKit element — unchanged from the current implementation */}
        <appkit-button />
      </div>

      {stats?.length ? <MachineMarquee stats={stats} /> : null}
    </header>
  );
}
