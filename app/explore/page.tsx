"use client";

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import { TokenTable } from "@/components/explore/TokenTable";

function ExploreContent() {
  const params = useSearchParams();
  const q = params.get("q") ?? "";
  const tabParam = params.get("tab");
  const initialTab = tabParam === "next-draw" || tabParam === "new" ? tabParam : "trending";

  return (
    <div className="content-container py-10">
      <h1 className="font-display text-2xl font-semibold text-ink">Explore tokens</h1>
      <p className="mt-1 text-sm text-ink-dim">
        {q ? (
          <>
            Showing results for <span className="text-ink">&ldquo;{q}&rdquo;</span>
          </>
        ) : (
          "Every meme launched through CLOG."
        )}
      </p>
      <div className="mt-6">
        <TokenTable searchQuery={q} initialTab={initialTab} />
      </div>
    </div>
  );
}

export default function ExplorePage() {
  return (
    <Suspense fallback={<div className="content-container py-10 text-sm text-ink-dim">Loading…</div>}>
      <ExploreContent />
    </Suspense>
  );
}
