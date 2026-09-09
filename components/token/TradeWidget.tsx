"use client";

import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { useBuyToken, useSellToken } from "@/lib/hooks/useProtocolActions";
import { TRADE_TAX_PCT } from "@/lib/constants";
import type { TokenDetail } from "@/lib/types";
import clsx from "clsx";

export function TradeWidget({ token }: { token: TokenDetail }) {
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("");
  const buy = useBuyToken();
  const sell = useSellToken();
  const active = side === "buy" ? buy : sell;

  const numericAmount = parseFloat(amount) || 0;
  const estimate =
    side === "buy"
      ? numericAmount > 0
        ? numericAmount / token.priceEth
        : 0
      : numericAmount > 0
      ? numericAmount * token.priceEth
      : 0;

  async function onSubmit() {
    if (side === "buy") await buy.execute(token.marketAddress, numericAmount);
    else await sell.execute(token.marketAddress, numericAmount);
  }

  if (active.status === "success") {
    return (
      <div className="rounded-md border border-border bg-surface p-5 text-center">
        <p className="text-sm font-medium text-cyan">
          {side === "buy" ? "Buy" : "Sell"} confirmed
        </p>
        <p className="mt-1 text-xs text-ink-dim">
          {side === "buy"
            ? `You received an estimated ${estimate.toLocaleString(undefined, { maximumFractionDigits: 0 })} ${token.ticker}.`
            : `You received an estimated ${estimate.toFixed(4)} ETH.`}
        </p>
        <Button
          variant="secondary"
          size="sm"
          className="mt-4"
          onClick={() => {
            buy.reset();
            sell.reset();
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
        className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2.5 font-mono text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60"
      />

      <div className="mt-3 flex justify-between text-xs text-ink-dim">
        <span>{side === "buy" ? `Estimated ${token.ticker}` : "Estimated ETH"}</span>
        <span className="font-mono tabular text-ink">
          {side === "buy" ? estimate.toLocaleString(undefined, { maximumFractionDigits: 0 }) : estimate.toFixed(4)}
        </span>
      </div>
      <div className="mt-1 flex justify-between text-xs text-ink-faint">
        <span>Trading fee</span>
        <span>{TRADE_TAX_PCT}%</span>
      </div>

      {active.error && <p className="mt-3 text-xs text-danger">{active.error}</p>}

      <Button
        fullWidth
        size="lg"
        className="mt-4"
        variant={side === "buy" ? "primary" : "danger"}
        disabled={numericAmount <= 0 || active.status === "pending"}
        onClick={onSubmit}
      >
        {active.status === "pending" ? "Confirming…" : `${side === "buy" ? "Buy" : "Sell"} ${token.ticker}`}
      </Button>
    </div>
  );
}
