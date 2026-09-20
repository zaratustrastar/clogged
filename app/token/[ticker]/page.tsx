"use client";

import { useState } from "react";
import { parseUnits } from "viem";
import { TokenHeader, MarketPanel, ActivityFeed, LabelPanel, type ActivityEvent } from "@/components/token/TokenPanels";
import { TradeDeck } from "@/components/token/TradeDeck";
import { DrawPanel, type QualificationState } from "@/components/token/DrawPanel";
import { NoSignal, ErrorPlate } from "@/components/machine/States";
import { useTokenDetail } from "@/lib/hooks/useTokenData";
import { useRoundStatus, useTokenList } from "@/lib/hooks/useTokenData";
import {
  useTradeQuote,
  computeSellApprovalState,
  useBuyToken,
  useSellToken,
  useApproveToken,
  useTokenAllowance,
  useQualifyToken,
} from "@/lib/hooks/useProtocolActions";
import { useAccount, useReadContract } from "wagmi";
import { addresses } from "@/lib/web3/addresses";
import { env } from "@/lib/web3/env";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { isProtocolConfigured } from "@/lib/web3/env";
import { formatEthPrecise, formatAddress, formatPct, formatCountdown } from "@/lib/format";
import { MIN_PROGRESS_BPS, MIN_RESERVE_THRESHOLD_ETH, REQUIRED_STREAK_SECONDS } from "@/lib/constants";
import { useNow } from "@/lib/hooks/useNow";

/* Layout: 1fr + 340px rail on desktop, single column under ~720px - via auto-fit so it
 * wraps without JS measurement. Nothing about quoting, allowance gating or receipt
 * handling is reimplemented: this page renders what the hooks return.
 *
 * Runbook §0 mismatches found and fixed here (all confirmed directly against the real
 * hooks, not assumed):
 *   - useTokenData(ticker)                    -> useTokenDetail(ticker) (lib/hooks/useTokenData.ts)
 *   - useTradeQuote({ ticker, side, amount })  -> useTradeQuote(marketAddress, side, ethAmount,
 *       sellAmountWei, sellAllowanceSufficient) - a 5-positional-arg call, not one options object.
 *       The function itself was ALSO missing entirely from useProtocolActions (it lived
 *       unexported inside the OLD components/token/TradeWidget.tsx) - extracted verbatim
 *       into useProtocolActions.ts in the previous commit, not reimplemented here.
 *   - useTrade()                               -> does not exist. Real hooks are separate:
 *       useBuyToken()/useSellToken(), plus useApproveToken()/useTokenAllowance() for the
 *       sell-approval gate (computeSellApprovalState's own real signature is
 *       { allowance, sellAmountWei }, not { allowance, amount, side } as the handoff assumed).
 *   - TokenDetail carries NONE of the handoff's assumed pre-formatted label fields
 *       (creatorShort/ageLabel/qualification/change1hLabel/change24hLabel/holdersLabel/
 *       reserveLabel/ethBalanceLabel/tokenBalanceLabel/round/activity/allowance/contractUrl).
 *       Its real shape is TokenSummary's raw fields (tokenId, ticker, name, priceEth,
 *       marketCapEth, curveProgressPct, eligibility, eligibleSinceSeconds, ...) plus
 *       tickerOwner/tickerTokenId/realReserveEth/clogRemainingTokens/totalSupply/
 *       curveAllocation/clogAllocation/recentActivity/drawHistory. Every label below is
 *       computed here, at the page's edge, from those raw fields - never invented.
 *   - No holder-count field exists anywhere in TokenDetail or any hook - MarketPanel's
 *       `holders` prop is passed "—" rather than fabricated.
 *
 * FIXME(eligibleSinceSeconds): lib/types.ts documents this field as "seconds into the
 * current streak", but the current, unmodified DrawPanel.tsx and TokenTable.tsx both
 * compute `Math.floor(Date.now() / 1000) - eligibleSinceSeconds`, i.e. treat it as a unix
 * timestamp. That exact arithmetic (never touched, never "fixed by guessing" here) is
 * reproduced below in deriveQualificationState. See the runbook's own §8 and the PR
 * description - this needs a human decision, not a silent behavior change. */

function deriveQualificationState(params: {
  token: NonNullable<ReturnType<typeof useTokenDetail>["data"]>;
  qualifiedCount: number;
  now: number;
}): QualificationState {
  const { token, qualifiedCount, now } = params;

  if (token.eligibility === "qualified") {
    const odds = qualifiedCount > 0 ? `1 / ${qualifiedCount}` : "—";
    return { kind: "qualified", oddsLabel: odds };
  }

  const progressMet = token.curveProgressPct >= MIN_PROGRESS_BPS / 100;
  const reserveMet = token.realReserveEth >= MIN_RESERVE_THRESHOLD_ETH;
  // FIXME(eligibleSinceSeconds) - see this file's own header comment. Existing
  // arithmetic preserved exactly, not reinterpreted.
  const elapsed = token.eligibleSinceSeconds ? Math.max(0, Math.floor(now / 1000) - token.eligibleSinceSeconds) : 0;
  const streakMet = reserveMet && elapsed >= REQUIRED_STREAK_SECONDS;

  if (progressMet && streakMet) return { kind: "ready" };
  if (progressMet && reserveMet) {
    const remaining = Math.max(0, REQUIRED_STREAK_SECONDS - elapsed);
    const m = Math.floor(remaining / 60);
    const s = remaining % 60;
    return { kind: "qualifying", remainingLabel: `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` };
  }
  return { kind: "building", curvePct: Math.round(token.curveProgressPct * 10) / 10 };
}

function toActivityEvent(e: NonNullable<ReturnType<typeof useTokenDetail>["data"]>["recentActivity"][number]): ActivityEvent {
  const kindMap: Record<string, ActivityEvent["kind"]> = { buy: "BUY", sell: "SELL", qualify: "QUAL", launch: "QUAL" };
  const detail =
    e.type === "buy" || e.type === "sell"
      ? e.amountEth !== null
        ? `${formatEthPrecise(e.amountEth)} ETH`
        : e.amountTokens !== null
          ? `${e.amountTokens.toLocaleString()} tokens`
          : "—"
      : e.type === "qualify"
        ? "Qualified"
        : "Launched";
  const ago = formatTimeAgoShort(e.timestamp);
  return { kind: kindMap[e.type] ?? "QUAL", detail, who: formatAddress(e.address), ago };
}

function formatTimeAgoShort(iso: string): string {
  const diffSec = Math.floor((Date.now() - new Date(iso).getTime()) / 1000);
  if (diffSec < 60) return `${diffSec}s`;
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h`;
  return `${Math.floor(diffSec / 86400)}d`;
}

export default function TokenPage({ params }: { params: { ticker: string } }) {
  const rawTicker = params.ticker.toUpperCase();
  const ticker = `$${rawTicker}`;
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("");
  const now = useNow(1000);
  const { address } = useAccount();

  const token = useTokenDetail(rawTicker);
  const roundStatus = useRoundStatus();
  const tokenList = useTokenList();
  const buy = useBuyToken();
  const sell = useSellToken();
  const approve = useApproveToken();
  const qualify = useQualifyToken();

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });

  let sellAmountWei: bigint | null = null;
  if (side === "sell" && amount.trim() !== "") {
    try {
      sellAmountWei = parseUnits(amount, 18);
    } catch {
      sellAmountWei = null;
    }
  }

  const allowance = useTokenAllowance(
    side === "sell" ? token.data?.tokenAddress : undefined,
    address,
    side === "sell" ? token.data?.marketAddress : undefined
  );
  const { hasEnoughAllowance, needsApproval } = computeSellApprovalState({
    allowance: allowance.allowance,
    sellAmountWei,
  });

  const numericAmount = parseFloat(amount) || 0;
  const quote = useTradeQuote(
    token.data?.marketAddress ?? "0x0000000000000000000000000000000000000000",
    side,
    numericAmount,
    sellAmountWei,
    hasEnoughAllowance
  );

  if (token.error) {
    return (
      <div className="mx-auto max-w-[1240px] px-5 py-7">
        <ErrorPlate title={`Could not load ${ticker}`} detail={token.error} onRetry={() => window.location.reload()} />
      </div>
    );
  }

  if (!token.data) {
    return (
      <div className="mx-auto max-w-[1240px] px-5 py-7">
        <NoSignal lines={8} />
      </div>
    );
  }

  const t = token.data;
  const openSeaUrl = t.tickerTokenId
    // PATCH P1-1: real contract address, not the "ticker-nft" placeholder string.
    ? `https://opensea.io/assets/ethereum/${addresses.tickerNFT}/${t.tickerTokenId}`
    : null;

  const qualifiedCount = (tokenList.data ?? []).filter((x) => x.eligibility === "qualified").length;
  const qualificationState = deriveQualificationState({ token: t, qualifiedCount, now });

  // A single deck can be mid-approve, mid-buy, or mid-sell - whichever the
  // person just pressed is the one whose real status/hash/error is shown.
  // Never combined/guessed: exactly the action currently in flight, or the
  // side's own primary action when nothing is in flight.
  const activeAction =
    side === "sell" && (approve.status === "pending" || (approve.status === "error" && needsApproval))
      ? approve
      : side === "buy"
        ? buy
        : sell;

  async function onTradeSubmit() {
    if (side === "buy") {
      if (!t) return;
      await buy.execute(t.marketAddress, numericAmount);
      return;
    }
    if (!t || sellAmountWei === null) return;
    if (needsApproval) {
      await approve.execute(t.tokenAddress, t.marketAddress, sellAmountWei);
      // Only proceed to sell once the approval itself is confirmed
      // (receipt-gated) - never optimistically chain into sell.
      if (approve.status !== "success") return;
    }
    await sell.execute(t.marketAddress, sellAmountWei);
  }

  return (
    <div className="mx-auto flex max-w-[1240px] flex-col gap-[18px] px-5 pb-24 pt-7">
      <TokenHeader
        ticker={ticker}
        name={t.name}
        imageUrl={t.imageUrl}
        creator={formatAddress(t.creator)}
        ageLabel={formatTimeAgoShort(t.createdAt)}
        qualified={t.eligibility === "qualified"}
        openSeaUrl={openSeaUrl}
        contractUrl={env.explorerUrl ? `${env.explorerUrl}/address/${t.tokenAddress}` : ""}
      />

      <div className="grid grid-cols-1 items-start gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(300px,340px)]">
        <div className="flex min-w-0 flex-col gap-3.5">
          <MarketPanel
            priceEth={`${formatEthPrecise(t.priceEth)} ETH`}
            change1h={t.change1hPct === null ? "—" : formatPct(t.change1hPct)}
            change24h={t.change24hPct === null ? "—" : formatPct(t.change24hPct)}
            marketCapEth={`${formatEthPrecise(t.marketCapEth)} ETH`}
            holders="—"
            curvePct={t.curveProgressPct}
            reserveLabel={`${t.realReserveEth.toFixed(3)} / ${MIN_RESERVE_THRESHOLD_ETH} ETH`}
          />
          <ActivityFeed events={t.recentActivity.map(toActivityEvent)} />
        </div>

        <div className="flex min-w-0 flex-col gap-3.5">
          <TradeDeck
            ticker={ticker}
            side={side}
            onSide={(s) => {
              setSide(s);
              setAmount("");
            }}
            amount={amount}
            onAmount={setAmount}
            balanceLabel="—"
            // quote.output's own unit depends on side: buying returns a
            // token count (this ticker's own token), selling returns ETH -
            // confirmed directly against useTradeQuote's real implementation
            // (buySim decodes BondingCurveClog.buy's tokensOut; sellSim
            // decodes sell's ethOut). formatEthPrecise's sig-fig-based
            // rounding is tuned for small ETH amounts, not a token count in
            // the thousands/millions, so the buy side uses toLocaleString
            // instead - and the unit label matches which one is actually
            // being shown, never a blanket "ETH" regardless of side.
            quoteOut={
              quote.output !== null
                ? side === "sell"
                  ? `${formatEthPrecise(quote.output)} ETH`
                  : `${quote.output.toLocaleString(undefined, { maximumFractionDigits: 0 })} ${ticker}`
                : null
            }
            quoteMin={
              quote.output !== null
                ? side === "sell"
                  ? `${formatEthPrecise(quote.output * 0.99)} ETH`
                  : `${(quote.output * 0.99).toLocaleString(undefined, { maximumFractionDigits: 0 })} ${ticker}`
                : null
            }
            needsApproval={side === "sell" && needsApproval}
            status={activeAction.status}
            hash={activeAction.txHash}
            errorMessage={activeAction.error}
            disabled={!amount || quote.isLoading}
            onSubmit={onTradeSubmit}
          />

          <DrawPanel
            ticker={ticker}
            roundNumber={roundStatus.data?.roundId ?? null}
            jackpotEth={unallocatedPool !== undefined ? `${formatEthPrecise(unallocatedPool)} ETH` : null}
            countdown={roundStatus.data ? formatCountdown(roundStatus.data.closesAt, now) : null}
            state={qualificationState}
            status={qualify.status}
            hash={qualify.txHash}
            errorMessage={qualify.error}
            onQualify={qualificationState.kind === "ready" ? () => qualify.execute(t.tokenId) : undefined}
          />

          {t.tickerTokenId ? (
            <LabelPanel ticker={ticker} tokenId={`#${t.tickerTokenId}`} openSeaUrl={openSeaUrl} />
          ) : null}
        </div>
      </div>
    </div>
  );
}
