"use client";

import { notFound, useParams } from "next/navigation";
import { useTokenDetail } from "@/lib/hooks/useTokenData";
import { TokenHeader } from "@/components/token/TokenHeader";
import { MarketInfo } from "@/components/token/MarketInfo";
import { TradeWidget } from "@/components/token/TradeWidget";
import { ClogMechanicsPanel } from "@/components/token/ClogMechanicsPanel";
import { DrawPanel } from "@/components/token/DrawPanel";
import { ActivityFeed } from "@/components/token/ActivityFeed";
import { TickerInfoPanel } from "@/components/token/TickerInfoPanel";
import { Skeleton } from "@/components/ui/Skeleton";
import { isProtocolConfigured } from "@/lib/web3/env";

export default function TokenDetailPage() {
  const params = useParams<{ ticker: string }>();
  const ticker = (params.ticker ?? "").toString();
  const { data: token, isLoading } = useTokenDetail(ticker);

  if (!isProtocolConfigured) {
    return (
      <div className="content-container py-24 text-center">
        <p className="text-sm text-ink-dim">Protocol contracts not configured yet.</p>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="content-container py-10">
        <Skeleton className="h-10 w-64" />
        <Skeleton className="mt-6 h-96 w-full" />
      </div>
    );
  }

  if (!token) {
    notFound();
  }

  return (
    <div className="content-container py-10">
      {/* 1. What is this meme? */}
      <TokenHeader token={token} />

      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_340px]">
        <div className="flex flex-col gap-6">
          <MarketInfo token={token} />

          <div>
            <h2 className="mb-3 font-display text-sm font-semibold text-ink">Recent activity</h2>
            <ActivityFeed events={token.recentActivity} />
          </div>
        </div>

        <div className="flex flex-col gap-5">
          {/* 2. Can I buy/sell it? */}
          <TradeWidget token={token} />
          {/* 3. Is it entering this hour's draw? */}
          <DrawPanel token={token} />
          {/* 4. Who owns the ticker? */}
          <TickerInfoPanel token={token} />
          <ClogMechanicsPanel token={token} />
        </div>
      </div>
    </div>
  );
}
