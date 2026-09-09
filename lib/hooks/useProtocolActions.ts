"use client";

import { useCallback, useEffect, useState } from "react";
import { RESERVED_TICKER, MAX_TICKER_LENGTH, MIN_TICKER_LENGTH } from "@/lib/constants";
import type { TickerAvailability } from "@/lib/types";

// ---------------------------------------------------------------------------
// WRITE / MUTATION HOOKS
//
// Each hook exposes { execute, status, error, txHash } where status moves
// through "idle" -> "pending" -> "success" | "error", matching the shape
// wagmi's useWriteContract + useWaitForTransactionReceipt produces. Screens
// are written against this shape now so wiring the real calls later means
// replacing the inside of `execute`, not the component code that calls it.
// ---------------------------------------------------------------------------

export type TxStatus = "idle" | "pending" | "success" | "error";

interface TxState {
  status: TxStatus;
  error: string | null;
  txHash: string | null;
}

function useMockTx() {
  const [state, setState] = useState<TxState>({ status: "idle", error: null, txHash: null });
  const reset = useCallback(() => setState({ status: "idle", error: null, txHash: null }), []);
  return { state, setState, reset };
}

const TAKEN_TICKERS = ["TOAST", "MOSS", "GUSH", "PEBBLE", "FERAL", "DRIFT", "NEWT", "DOGE", "PEPE"];

/**
 * Checks whether a ticker string can currently be launched.
 *
 * TODO (live wiring): normalize client-side the same way TickerRegistry does
 * (ASCII A-Z only, 2-10 chars, uppercased) for instant feedback, then confirm
 * against the contract with `TickerRegistry.isAvailable(ticker)` (a view
 * call, safe to call on every keystroke with a short debounce).
 */
export function useTickerAvailability(ticker: string): TickerAvailability {
  const [result, setResult] = useState<TickerAvailability>({ status: "idle" });

  useEffect(() => {
    const normalized = ticker.trim().toUpperCase();

    if (normalized.length === 0) {
      setResult({ status: "idle" });
      return;
    }
    if (normalized.length < MIN_TICKER_LENGTH || normalized.length > MAX_TICKER_LENGTH) {
      setResult({ status: "invalid", reason: `Ticker must be ${MIN_TICKER_LENGTH}-${MAX_TICKER_LENGTH} letters` });
      return;
    }
    if (!/^[A-Z]+$/.test(normalized)) {
      setResult({ status: "invalid", reason: "Letters A-Z only, no numbers or symbols" });
      return;
    }
    if (normalized === RESERVED_TICKER) {
      setResult({ status: "reserved" });
      return;
    }

    setResult({ status: "checking" });
    const t = setTimeout(() => {
      // Mock: a small deterministic set of tickers are "taken" so the taken
      // state is demonstrable. Replace with a real isAvailable() read.
      setResult(TAKEN_TICKERS.includes(normalized) ? { status: "taken" } : { status: "available" });
    }, 450);
    return () => clearTimeout(t);
  }, [ticker]);

  return result;
}

/**
 * Launches a new meme token (commit/reveal abstracted away as one action).
 *
 * TODO (live wiring): this is genuinely two transactions on-chain
 * (TickerRegistry.commit, then TickerRegistry.reveal after the minimum
 * delay). Options for the UI:
 *   (a) run both automatically behind one "Launch" button with an internal
 *       waiting step and a status message ("Confirming reservation…" ->
 *       "Waiting for reveal window…" -> "Launching…"), or
 *   (b) surface the two steps explicitly if the delay is long enough that
 *       hiding it would feel broken.
 * The mock below simulates (a) with a single delay.
 */
export function useLaunchToken() {
  const { state, setState, reset } = useMockTx();

  const execute = useCallback(
    async (input: { ticker: string; name: string }) => {
      setState({ status: "pending", error: null, txHash: null });
      await new Promise((r) => setTimeout(r, 1600));
      setState({ status: "success", error: null, txHash: "0xmock" + input.ticker.toLowerCase() });
    },
    [setState]
  );

  return { execute, reset, ...state };
}

/** TODO (live wiring): BondingCurveClog.buy(minTokensOut, deadline) with msg.value. */
export function useBuyToken() {
  const { state, setState, reset } = useMockTx();
  const execute = useCallback(
    async (_marketAddress: string, _ethAmount: number) => {
      setState({ status: "pending", error: null, txHash: null });
      await new Promise((r) => setTimeout(r, 1200));
      setState({ status: "success", error: null, txHash: "0xmockbuy" });
    },
    [setState]
  );
  return { execute, reset, ...state };
}

/** TODO (live wiring): BondingCurveClog.sell(tokenAmount, minEthOut, deadline). */
export function useSellToken() {
  const { state, setState, reset } = useMockTx();
  const execute = useCallback(
    async (_marketAddress: string, _tokenAmount: number) => {
      setState({ status: "pending", error: null, txHash: null });
      await new Promise((r) => setTimeout(r, 1200));
      setState({ status: "success", error: null, txHash: "0xmocksell" });
    },
    [setState]
  );
  return { execute, reset, ...state };
}

/** TODO (live wiring): RewardVault.claim(roundId, holderAddress). */
export function useClaimReward() {
  const { state, setState, reset } = useMockTx();
  const execute = useCallback(
    async (_roundId: number) => {
      setState({ status: "pending", error: null, txHash: null });
      await new Promise((r) => setTimeout(r, 1000));
      setState({ status: "success", error: null, txHash: "0xmockclaim" });
    },
    [setState]
  );
  return { execute, reset, ...state };
}
