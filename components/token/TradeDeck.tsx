"use client";

import { useState } from "react";
import { Cabinet } from "@/components/machine/Cabinet";
import { PhysicalButton, StatusLamp } from "@/components/machine/PhysicalButton";
import { txMotionState, TX_COPY } from "@/components/machine/motion";

/** Control-panel trading. EVERY number renders on flat display material, full-opacity,
 *  tabular, nowrap — never over glass sheen and never inside a distorting element.
 *
 *  The quote and approval logic are NOT reimplemented here: pass through exactly what
 *  useTradeQuote / computeSellApprovalState already return. The sell path must stay
 *  gated behind sufficient allowance. */
export function TradeDeck({
  ticker,
  side,
  onSide,
  amount,
  onAmount,
  balanceLabel,
  quoteOut,
  quoteMin,
  needsApproval,
  status,
  hash,
  errorMessage,
  disabled,
  onSubmit,
}: {
  ticker: string;
  side: "buy" | "sell";
  onSide: (s: "buy" | "sell") => void;
  amount: string;
  onAmount: (v: string) => void;
  balanceLabel: string;
  quoteOut: string | null;
  quoteMin: string | null;
  needsApproval: boolean;
  status: "idle" | "pending" | "success" | "error";
  hash?: `0x${string}` | null;
  errorMessage?: string | null;
  disabled?: boolean;
  onSubmit: () => void;
}) {
  const motion = txMotionState({ status, hash, disabled });
  const tone = TX_COPY[motion].tone;

  const label =
    status === "success" ? "FILLED"
    : motion === "awaiting-signature" ? "AWAITING WALLET"
    : motion === "pending" ? "PENDING…"
    : side === "sell" && needsApproval ? "APPROVE & SELL"
    : side === "sell" ? `SELL ${ticker}`
    : `BUY ${ticker}`;

  return (
    <Cabinet state={motion}>
      <div className="flex gap-1.5 rounded-md border border-edge-hair bg-chassis-900 p-1">
        {(["buy", "sell"] as const).map((s) => (
          <button
            key={s}
            onClick={() => onSide(s)}
            aria-pressed={side === s}
            className={`flex-1 rounded px-3 py-3 font-mono text-xs font-bold tracking-[0.08em] ${
              side === s ? "bg-amber text-amber-ink" : "bg-transparent text-ink-500"
            }`}
          >
            {s.toUpperCase()}
          </button>
        ))}
      </div>

      <div className="mt-3 flex flex-col gap-3 rounded-md border border-edge-hair bg-chassis-900 p-3.5 shadow-display">
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-2.5">
            <label htmlFor="trade-amount" className="font-mono text-label text-ink-500">
              {side === "buy" ? "YOU PAY" : "YOU SELL"}
            </label>
            <span className="clog-fig whitespace-nowrap text-[10.5px] text-ink-500">BAL {balanceLabel}</span>
          </div>
          <div className="flex items-center gap-2.5 border border-edge-hair bg-chassis-800 px-3 py-2.5">
            <input
              id="trade-amount"
              value={amount}
              onChange={(e) => onAmount(e.target.value)}
              inputMode="decimal"
              placeholder="0.0"
              className="clog-fig min-w-0 flex-1 border-0 bg-transparent text-[21px] text-ink-100 outline-none placeholder:text-ink-600"
            />
            <span className="whitespace-nowrap font-mono text-xs text-ink-400">
              {side === "buy" ? "ETH" : ticker}
            </span>
          </div>
        </div>

        <dl className="m-0 flex flex-col gap-2 border-t border-dashed border-edge-hair pt-3">
          <div className="flex items-center justify-between gap-2.5">
            <dt className="font-mono text-[10.5px] text-ink-500">YOU RECEIVE</dt>
            <dd className="clog-fig m-0 whitespace-nowrap text-[15px] text-ink-100">{quoteOut ?? "—"}</dd>
          </div>
          <div className="flex items-center justify-between gap-2.5">
            <dt className="font-mono text-[10.5px] text-ink-500">MIN AFTER SLIPPAGE</dt>
            <dd className="clog-fig m-0 whitespace-nowrap text-[11.5px] text-ink-400">{quoteMin ?? "—"}</dd>
          </div>
          <div className="flex items-center justify-between gap-2.5">
            <dt className="font-mono text-[10.5px] text-ink-500">QUOTE SOURCE</dt>
            <dd className="m-0 whitespace-nowrap font-mono text-[10.5px] text-ok">onchain simulation</dd>
          </div>
        </dl>

        {side === "sell" && needsApproval ? (
          <div className="flex flex-col gap-2 border border-amber/35 bg-amber/[0.06] px-3 py-2.5">
            <p className="m-0 font-mono text-[10.5px] tracking-[0.1em] text-amber">APPROVAL REQUIRED FIRST</p>
            <p className="m-0 text-xs leading-[1.5] text-ink-400">
              Selling needs an allowance for the curve contract — one extra transaction. The sell
              quote stays locked until it confirms.
            </p>
          </div>
        ) : null}
      </div>

      <div className="mt-3 flex flex-col gap-2.5 rounded-md border border-edge-hard bg-chassis-plate p-3.5">
        <StatusLamp tone={tone} label={TX_COPY[motion].label} />
        {errorMessage ? <p className="m-0 break-words font-mono text-[11px] text-bad">{errorMessage}</p> : null}
        <PhysicalButton state={motion} onPress={onSubmit} className="w-full">
          {label}
        </PhysicalButton>
      </div>
    </Cabinet>
  );
}
