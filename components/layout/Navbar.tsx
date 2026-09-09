"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { WalletButton } from "@/components/wallet/WalletButton";

export function Navbar() {
  const router = useRouter();
  const [query, setQuery] = useState("");

  function onSearchSubmit(e: React.FormEvent) {
    e.preventDefault();
    router.push(query.trim() ? `/explore?q=${encodeURIComponent(query.trim())}` : "/explore");
  }

  return (
    <header className="sticky top-0 z-40 border-b border-border bg-bg/95 backdrop-blur">
      <div className="content-container flex h-16 items-center gap-4">
        <Link href="/" className="flex shrink-0 items-center gap-2">
          <span className="flex h-7 w-7 items-center justify-center rounded bg-cyan text-sm font-bold text-bg">
            C
          </span>
          <span className="font-display text-lg font-semibold tracking-tight text-ink">CLOG</span>
        </Link>

        <form onSubmit={onSearchSubmit} className="hidden flex-1 max-w-md md:block">
          <div className="flex items-center gap-2 rounded border border-border bg-surface px-3 py-2 focus-within:border-cyan/60">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" className="shrink-0 text-ink-faint">
              <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="2" />
              <path d="m21 21-4.3-4.3" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search tokens"
              className="w-full bg-transparent text-sm text-ink placeholder:text-ink-faint outline-none"
            />
          </div>
        </form>

        <nav className="ml-auto hidden items-center gap-6 text-sm font-medium text-ink-dim md:flex">
          <Link href="/explore" className="hover:text-ink">
            Explore
          </Link>
          <Link href="/dashboard" className="hover:text-ink">
            Dashboard
          </Link>
        </nav>

        <Link href="/launch" className="ml-2 hidden sm:block">
          <Button size="md">Launch token</Button>
        </Link>

        <WalletButton />
      </div>
    </header>
  );
}
