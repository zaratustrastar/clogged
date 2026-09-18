"use client";

import { useState } from "react";
import Link from "next/link";
import { useQueryClient } from "@tanstack/react-query";
import { PrizeChute, type ClaimRow } from "@/components/dashboard/PrizeChute";
import { HoldingsTray, TickerNftTray, type Holding, type TickerNft } from "@/components/dashboard/Trays";
import { useHeldTokens, useOwnedTickerNFTs, useClaimableRewards } from "@/lib/hooks/useWalletData";
import { useWalletAccount } from "@/lib/hooks/useWalletAccount";
import { useClaimReward } from "@/lib/hooks/useProtocolActions";
import { formatEthPrecise } from "@/lib/format";

/* Order changed: the prize chute is FIRST. Everything else follows.
 *
 * PATCH P0-3 is structural and lives right here: every block passes its own
 * `error` through to the component. The old page rendered `claimable.data && …`,
 * so a failed read was indistinguishable from "no winnings". Never reintroduce
 * a bare `data &&` guard on this page.
 *
 * Runbook §0 mismatches found and fixed here (all confirmed directly against
 * the real hooks, not assumed):
 *   - useWalletData(address)   -> does not exist as one hook at all. Real hooks
 *       are separate: useHeldTokens()/useOwnedTickerNFTs()/useClaimableRewards()
 *       (none take an address param - they read the connected wallet
 *       internally via useWalletAccount, same as this page already does).
 *       useLaunchedTokens()/useClaimHistory() also exist but nothing on this
 *       page's own data requirements calls for them.
 *   - useClaim()               -> useClaimReward() (lib/hooks/useProtocolActions.ts).
 *       Its real shape is a SINGLE in-flight-transaction tracker
 *       ({execute, status, error, txHash, reset}, execute(roundId: number)) -
 *       not the handoff's assumed multi-round API (confirmedRounds/statusFor/
 *       hashFor/errorFor/executeAll), none of which exist. Per-round claiming
 *       state is tracked at this page's own level instead (claimingRoundId +
 *       confirmedRoundIds below) - see the P0-1 note there for why this is
 *       still receipt-gated, never optimistic.
 *   - useClaimableRewards().error is a plain string (AsyncState's own shape),
 *       not the { message: string } object ClaimRow/HoldingsTray/TickerNftTray
 *       all want - wrapped at this page's edge, never inside those components.
 *   - ClaimableReward carries amountEth: number, not amountWei: bigint -
 *       useClaimableRewards() itself already converts wei to a float
 *       internally (Number(claimable) / 1e18 - confirmed directly against its
 *       own source). The bigint PrizeChute's own ClaimRow type wants is
 *       reconstructed via BigInt(Math.round(amountEth * 1e18)) - this cannot
 *       recover precision already lost inside the hook itself without
 *       modifying it, which is out of scope for a presentation-only redesign;
 *       flagged in the PR description as a known limitation, not silently
 *       glossed over.
 *   - No hook anywhere exposes a per-winner "share of the pot" percentage -
 *       ClaimRow.shareLabel and Holding.shareLabel both get "—", never a
 *       fabricated number.
 *   - "claimAll" (PrizeChute's own optional bulk-claim prop) is left
 *       undefined - there is no contract/hook support for claiming multiple
 *       rounds in one transaction, and building a client-side loop that
 *       fires multiple sequential wallet prompts is a new feature this task
 *       was not asked to invent; omitted rather than fabricated.
 */

export default function DashboardPage() {
  const { address, isConnected } = useWalletAccount();
  const heldTokens = useHeldTokens();
  const tickerNfts = useOwnedTickerNFTs();
  const claimable = useClaimableRewards();
  const claim = useClaimReward();
  const queryClient = useQueryClient();
  // None of the three AsyncState-wrapped hooks above expose a refetch()
  // method (confirmed directly against lib/hooks/useWalletData.ts - their
  // own toAsyncState helper returns only {data, isLoading, error}). Retry
  // uses the same react-query infrastructure those hooks are already built
  // on instead, invalidating by the hooks' own real query-key prefixes
  // (confirmed directly against their queryKey arrays) - this never
  // modifies the hooks themselves, just asks the query cache they already
  // participate in to refetch.
  const retryHeldTokens = () => queryClient.invalidateQueries({ queryKey: ["clog-held-tokens"] });
  const retryTickerNfts = () => queryClient.invalidateQueries({ queryKey: ["clog-owned-ticker-nfts"] });
  const retryClaimable = () => queryClient.invalidateQueries({ queryKey: ["clog-claimable"] });

  // PATCH P0-1, applied at the page level since useClaimReward tracks only
  // one in-flight transaction globally, not per round: "claimed" is derived
  // from claim.execute() itself never throwing, which (per useContractWrite's
  // own run() implementation - confirmed directly against its source) only
  // happens after publicClient.waitForTransactionReceipt has actually
  // resolved. A rejected signature or a reverted transaction always throws,
  // so confirmedRoundIds is only ever populated by a real confirmed receipt -
  // never set optimistically "after we called execute".
  const [claimingRoundId, setClaimingRoundId] = useState<number | null>(null);
  const [confirmedRoundIds, setConfirmedRoundIds] = useState<Set<number>>(new Set());

  async function onClaim(roundId: number) {
    setClaimingRoundId(roundId);
    try {
      await claim.execute(roundId);
      // execute() resolved without throwing - the receipt is confirmed.
      setConfirmedRoundIds((prev) => new Set(prev).add(roundId));
      // The hook's own invalidation list (useContractWrite's run()) does not
      // include the claimable query - refetch explicitly so a just-claimed
      // round's real chain state (previewClaim now returns 0 for it) is
      // reflected promptly rather than waiting out the query's own interval.
      retryClaimable();
    } catch {
      // claim.error already carries the real, translated failure message -
      // nothing else to do here. The round stays claimable (never marked
      // confirmed), exactly as P0-1 requires.
    } finally {
      setClaimingRoundId(null);
    }
  }

  if (!isConnected) {
    return (
      <div className="mx-auto flex max-w-[1240px] flex-col items-start gap-4 px-5 py-16">
        <h1 className="m-0 font-display text-[clamp(26px,3.6vw,38px)] tracking-[-0.025em]">Your machine</h1>
        <p className="m-0 max-w-[52ch] text-[15px] leading-[1.6] text-ink-400 text-pretty">
          Connect a wallet to see your winnings, holdings and the labels you own. Nothing here
          requires a signature to read.
        </p>
        <appkit-button />
      </div>
    );
  }

  const claimRows: ClaimRow[] = (claimable.data ?? []).map((c): ClaimRow => {
    const isThisRoundClaiming = claimingRoundId === c.roundId;
    return {
      roundNumber: c.roundId,
      ticker: c.ticker,
      amountWei: BigInt(Math.round(c.amountEth * 1e18)),
      shareLabel: "—",
      claimed: confirmedRoundIds.has(c.roundId),
      status: isThisRoundClaiming ? claim.status : "idle",
      hash: isThisRoundClaiming ? claim.txHash : null,
      errorMessage: isThisRoundClaiming ? claim.error : null,
      onClaim: () => onClaim(c.roundId),
    };
  });

  const holdings: Holding[] = (heldTokens.data ?? []).map((h) => ({
    ticker: h.token.ticker,
    balanceLabel: h.balanceTokens.toLocaleString(undefined, { maximumFractionDigits: 2 }),
    valueEthLabel: formatEthPrecise(h.balanceTokens * h.token.priceEth),
    shareLabel: "—",
    qualified: h.token.eligibility === "qualified",
  }));

  const nfts: TickerNft[] = (tickerNfts.data ?? []).map((n) => ({
    ticker: n.ticker,
    tokenId: `#${n.tokenId}`,
    openSeaUrl: n.openSeaUrl,
  }));

  return (
    <div className="mx-auto flex max-w-[1240px] flex-col gap-[18px] px-5 pb-24 pt-7">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="m-0 font-display text-[clamp(26px,3.6vw,38px)] tracking-[-0.025em]">Your machine</h1>
          <p className="mt-1.5 font-mono text-meta text-ink-500">{address} · ROBINHOOD CHAIN</p>
        </div>
        <Link href="/round" className="border border-edge-hard bg-chassis-600 px-3.5 py-2.5 font-mono text-meta text-ink-100 no-underline">
          WATCH THE DRAW →
        </Link>
      </header>

      <PrizeChute
        rows={claimRows}
        isLoading={claimable.isLoading}
        error={claimable.error ? { message: claimable.error } : null}
        onRetry={retryClaimable}
      />

      <div className="grid grid-cols-1 gap-3.5 lg:grid-cols-2">
        <HoldingsTray
          holdings={holdings}
          isLoading={heldTokens.isLoading}
          error={heldTokens.error ? { message: heldTokens.error } : null}
          onRetry={retryHeldTokens}
        />
        <TickerNftTray
          nfts={nfts}
          isLoading={tickerNfts.isLoading}
          error={tickerNfts.error ? { message: tickerNfts.error } : null}
          onRetry={retryTickerNfts}
        />
      </div>
    </div>
  );
}
