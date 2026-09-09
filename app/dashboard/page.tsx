"use client";

import Link from "next/link";
import { Button } from "@/components/ui/Button";
import { Skeleton } from "@/components/ui/Skeleton";
import { ClaimableWinnings } from "@/components/dashboard/ClaimableWinnings";
import { HoldingsTable } from "@/components/dashboard/HoldingsTable";
import { LaunchedTable } from "@/components/dashboard/LaunchedTable";
import { TickerNFTList } from "@/components/dashboard/TickerNFTList";
import { useWalletAccount } from "@/lib/hooks/useWalletAccount";
import {
  useHeldTokens,
  useLaunchedTokens,
  useClaimableRewards,
  useOwnedTickerNFTs,
} from "@/lib/hooks/useWalletData";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="mb-3 font-display text-base font-semibold text-ink">{title}</h2>
      {children}
    </section>
  );
}

export default function DashboardPage() {
  const { isConnected, connect } = useWalletAccount();
  const holdings = useHeldTokens();
  const launched = useLaunchedTokens();
  const claimable = useClaimableRewards();
  const tickerNfts = useOwnedTickerNFTs();

  if (!isConnected) {
    return (
      <div className="content-container flex flex-col items-center py-24 text-center">
        <h1 className="font-display text-2xl font-semibold text-ink">Connect your wallet</h1>
        <p className="mt-2 max-w-sm text-sm text-ink-dim">
          Connect to see tokens you hold, tokens you&apos;ve launched, and any winnings ready to
          claim.
        </p>
        <Button className="mt-6" onClick={connect}>
          Connect wallet
        </Button>
      </div>
    );
  }

  return (
    <div className="content-container flex flex-col gap-10 py-10">
      <div>
        <h1 className="font-display text-2xl font-semibold text-ink">Dashboard</h1>
        <p className="mt-1 text-sm text-ink-dim">Your tokens, launches, and rewards.</p>
      </div>

      {claimable.isLoading ? (
        <Skeleton className="h-28 w-full" />
      ) : (
        claimable.data && <ClaimableWinnings rewards={claimable.data} />
      )}

      <Section title="Your holdings">
        {holdings.isLoading ? (
          <Skeleton className="h-40 w-full" />
        ) : (
          <HoldingsTable positions={holdings.data ?? []} />
        )}
      </Section>

      <Section title="Your launches">
        {launched.isLoading ? (
          <Skeleton className="h-40 w-full" />
        ) : (
          <LaunchedTable tokens={launched.data ?? []} />
        )}
      </Section>

      <Section title="Your ticker NFTs">
        {tickerNfts.isLoading ? (
          <Skeleton className="h-24 w-full" />
        ) : (
          <TickerNFTList nfts={tickerNfts.data ?? []} />
        )}
      </Section>

      <p className="text-center text-xs text-ink-faint">
        Want to launch something new?{" "}
        <Link href="/launch" className="text-cyan hover:underline">
          Launch a token
        </Link>
      </p>
    </div>
  );
}
