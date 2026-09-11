"use client";

import { useEffect, useState } from "react";
import { useAccount, useSimulateContract } from "wagmi";
import { parseUnits } from "viem";
import { Button } from "@/components/ui/Button";
import { useBuyToken, useSellToken, useTokenAllowance, useApproveToken, computeSellApprovalState } from "@/lib/hooks/useProtocolActions";
import { TRADE_TAX_PCT } from "@/lib/constants";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { env } from "@/lib/web3/env";
import type { TokenDetail } from "@/lib/types";
import clsx from "clsx";

/** Real pre-trade quote via wagmi's useSimulateContract - an eth_call
 * against BondingCurveClog's actual buy/sell function (there is no separate
 * external quote function on the contract; see the implementation report).
 * Not an approximation: this is the exact result the real transaction would
 * produce if submitted right now.
 *
 * The sell simulation is only ever attempted once allowance is already
 * sufficient - sell() itself calls token.transferFrom() internally, so
 * simulating it against insufficient allowance would revert for a reason
 * that has nothing to do with price. That revert must never be shown as
 * "price moved" - it isn't attempted at all until the approval-gated sell
 * button (below) confirms allowance is enough. */
function useTradeQuote(
  marketAddress: `0x${string}`,
  side: "buy" | "sell",
  ethAmount: number,
  sellAmountWei: bigint | null,
  sellAllowanceSufficient: boolean
) {
  const { address } = useAccount();

  // Refreshed periodically rather than frozen at mount: a token page left
  // open for a long time must never simulate against a deadline computed
  // when the component first mounted, which could eventually be more than
  // 10 minutes in the past. This is a read-only quote (never the actual
  // transaction - see useBuyToken/useSellToken for that, which derive
  // their own deadline fresh from the chain's latest block at submit
  // time), so refreshing once a minute is more than sufficient headroom
  // against the contract's 600-second window. No useMemo needed - this
  // computation is trivially cheap, and re-running it on every render
  // (whether triggered by the interval below or by the amount input
  // changing) costs nothing extra.
  const [, forceMinuteTick] = useState(0);
  useEffect(() => {
    const id = setInterval(() => forceMinuteTick((t) => t + 1), 60_000);
    return () => clearInterval(id);
  }, []);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

  const validBuy = ethAmount > 0 && Boolean(address);
  const validSell = sellAmountWei !== null && sellAmountWei > 0n && Boolean(address) && sellAllowanceSufficient;

  const buySim = useSimulateContract({
    address: marketAddress,
    abi: bondingCurveClogAbi,
    functionName: "buy",
    args: [0n, deadline],
    value: validBuy ? BigInt(Math.round(ethAmount * 1e18)) : 0n,
    account: address,
    query: { enabled: validBuy && side === "buy" },
  });

  const sellSim = useSimulateContract({
    address: marketAddress,
    abi: bondingCurveClogAbi,
    functionName: "sell",
    args: [sellAmountWei ?? 0n, 0n, deadline],
    account: address,
    query: { enabled: validSell && side === "sell" },
  });

  if (side === "buy") {
    return {
      output: buySim.data ? Number(buySim.data.result) / 1e18 : null,
      isLoading: buySim.isFetching,
      error: buySim.error ? String(buySim.error.message ?? buySim.error) : null,
    };
  }
  return {
    output: sellSim.data ? Number(sellSim.data.result[0]) / 1e18 : null,
    isLoading: sellSim.isFetching,
    error: sellSim.error ? String(sellSim.error.message ?? sellSim.error) : null,
  };
}

export function TradeWidget({ token }: { token: TokenDetail }) {
  const { address, isConnected } = useAccount();
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("");
  const buy = useBuyToken();
  const sell = useSellToken();
  const approve = useApproveToken();
  const active = side === "buy" ? buy : sell;

  const numericAmount = parseFloat(amount) || 0;

  // Parsed with viem's parseUnits directly from the raw string input -
  // never through `Number(amount) * 1e18`, which cannot represent large
  // 18-decimal token amounts exactly (a real wallet balance like
  // 198978.001876459213675822 HOOD has 24 significant digits; a JS number
  // only holds about 15-17 reliably). The string is kept as-is right up
  // until this exact conversion. null for empty/invalid/partial input
  // (e.g. "12.") - treated as not-yet-a-valid-amount, not an error.
  let sellAmountWei: bigint | null = null;
  if (side === "sell" && amount.trim() !== "") {
    try {
      sellAmountWei = parseUnits(amount, 18);
    } catch {
      sellAmountWei = null;
    }
  }

  // BondingCurveClog.sell() calls token.transferFrom(msg.sender,
  // address(this), tokenAmount) internally - the market must be an
  // approved spender first. Only checked/queried on the sell side.
  const allowance = useTokenAllowance(
    side === "sell" ? token.tokenAddress : undefined,
    address,
    side === "sell" ? token.marketAddress : undefined
  );
  const allowanceKnown = allowance.allowance !== null;
  const { checkingAllowance, hasEnoughAllowance, needsApproval } = computeSellApprovalState({
    allowance: allowance.allowance,
    sellAmountWei,
  });

  const quote = useTradeQuote(token.marketAddress, side, numericAmount, sellAmountWei, hasEnoughAllowance);

  async function onApprove() {
    if (!sellAmountWei) return;
    await approve.execute(token.tokenAddress, token.marketAddress, sellAmountWei);
  }

  async function onSubmit() {
    if (side === "buy") await buy.execute(token.marketAddress, numericAmount);
    else if (sellAmountWei !== null) await sell.execute(token.marketAddress, sellAmountWei);
  }

  if (active.status === "success") {
    return (
      <div className="rounded-md border border-border bg-surface p-5 text-center">
        <p className="text-sm font-medium text-cyan">Confirmed</p>
        <p className="mt-1 text-xs text-ink-dim">
          {side === "buy" ? "Buy" : "Sell"} transaction confirmed on-chain.
        </p>
        {active.txHash && env.explorerUrl && (
          <a
            href={`${env.explorerUrl}/tx/${active.txHash}`}
            target="_blank"
            rel="noreferrer"
            className="mt-2 inline-block text-xs text-cyan hover:underline"
          >
            View on explorer ↗
          </a>
        )}
        <Button
          variant="secondary"
          size="sm"
          className="mt-4"
          onClick={() => {
            buy.reset();
            sell.reset();
            approve.reset();
            setAmount("");
          }}
        >
          Make another trade
        </Button>
      </div>
    );
  }

  return (
    <div className="rounded-md border border-border bg-surface p-5">
      <div className="flex rounded bg-surface-raised p-1">
        <button
          onClick={() => setSide("buy")}
          className={clsx(
            "flex-1 rounded py-2 text-sm font-medium transition-colors",
            side === "buy" ? "bg-cyan text-bg" : "text-ink-dim"
          )}
        >
          Buy
        </button>
        <button
          onClick={() => setSide("sell")}
          className={clsx(
            "flex-1 rounded py-2 text-sm font-medium transition-colors",
            side === "sell" ? "bg-danger text-bg" : "text-ink-dim"
          )}
        >
          Sell
        </button>
      </div>

      <label className="mt-4 block text-xs font-medium text-ink-dim">
        {side === "buy" ? "ETH amount" : `${token.ticker} amount`}
      </label>
      <input
        value={amount}
        onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
        placeholder="0.0"
        inputMode="decimal"
        disabled={!isConnected}
        className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2.5 font-mono text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
      />

      <div className="mt-3 flex justify-between text-xs text-ink-dim">
        <span>{side === "buy" ? `Expected ${token.ticker}` : "Expected ETH"}</span>
        <span className="font-mono tabular text-ink">
          {side === "sell" && (needsApproval || checkingAllowance)
            ? needsApproval
              ? "Approval required"
              : "…"
            : numericAmount <= 0
            ? "—"
            : quote.isLoading
            ? "…"
            : quote.output !== null
            ? side === "buy"
              ? quote.output.toLocaleString(undefined, { maximumFractionDigits: 0 })
              : quote.output.toFixed(4)
            : "—"}
        </span>
      </div>
      <div className="mt-1 flex justify-between text-xs text-ink-faint">
        <span>Trading fee</span>
        <span>{TRADE_TAX_PCT}%</span>
      </div>

      {!isConnected && <p className="mt-3 text-xs text-ink-faint">Connect a wallet to trade.</p>}
      {side === "sell" && approve.status === "success" && needsApproval && (
        <p className="mt-3 text-xs text-cyan">Approval confirmed — updating…</p>
      )}
      {approve.error && <p className="mt-3 text-xs text-danger">{approve.error}</p>}
      {active.error && <p className="mt-3 text-xs text-danger">{active.error}</p>}

      {side === "sell" && needsApproval ? (
        <Button
          fullWidth
          size="lg"
          className="mt-4"
          variant="secondary"
          disabled={!isConnected || sellAmountWei === null || sellAmountWei <= 0n || approve.status === "pending"}
          onClick={onApprove}
        >
          {approve.status === "pending" ? "Confirm in wallet…" : `Approve ${token.ticker}`}
        </Button>
      ) : (
        <Button
          fullWidth
          size="lg"
          className="mt-4"
          variant={side === "buy" ? "primary" : "danger"}
          disabled={
            !isConnected ||
            active.status === "pending" ||
            (side === "buy" ? numericAmount <= 0 : sellAmountWei === null || sellAmountWei <= 0n || checkingAllowance)
          }
          onClick={onSubmit}
        >
          {active.status === "pending" ? "Confirm in wallet…" : `${side === "buy" ? "Buy" : "Sell"} ${token.ticker}`}
        </Button>
      )}
    </div>
  );
}
