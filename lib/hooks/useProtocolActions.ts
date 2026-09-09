"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  useAccount,
  usePublicClient,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { encodeAbiParameters, keccak256, type Address } from "viem";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { eligibilityRegistryAbi } from "@/lib/web3/abis/eligibilityRegistry";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { RESERVED_TICKER, MAX_TICKER_LENGTH, MIN_TICKER_LENGTH, LAUNCH_PRICE_ETH } from "@/lib/constants";
import type { TickerAvailability } from "@/lib/types";

// ---------------------------------------------------------------------------
// Shared error translation - contract require() strings and common wallet/
// wagmi errors, mapped to plain language. Falls back to a short generic
// message rather than a raw Solidity revert blob.
// ---------------------------------------------------------------------------
export function translateContractError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);

  if (/User rejected|user rejected|ACTION_REJECTED/i.test(raw)) return "Transaction rejected in wallet.";
  if (/insufficient funds/i.test(raw)) return "Insufficient ETH in your wallet for this transaction.";
  if (/chain.*mismatch|wrong network|ChainMismatchError/i.test(raw)) return "Wrong network — switch to Robinhood Chain.";
  if (/TickerRegistry: wrong payment/.test(raw)) return "Payment amount doesn't match the launch price.";
  if (/TickerRegistry: ticker taken/.test(raw)) return "That ticker was just taken — try another.";
  if (/TickerRegistry: CLOG is reserved/.test(raw)) return "CLOG is reserved and cannot be launched.";
  if (/TickerRegistry: reveal too early/.test(raw)) return "The reveal delay hasn't passed yet — try again shortly.";
  if (/TickerRegistry: reveal expired/.test(raw)) return "The reveal window expired — start over with a new reservation.";
  if (/TickerRegistry: no matching commitment/.test(raw)) return "No matching reservation found for this ticker.";
  if (/TickerRegistry: already committed/.test(raw)) return "That reservation already exists — wait for it to clear or use a different ticker.";
  if (/TickerRegistry: public ticker cap reached/.test(raw)) return "All 7,777 tickers have been claimed.";
  if (/exceeds available token inventory|exceeds.*inventory/i.test(raw)) return "That amount is too large for the current curve depth — try a smaller amount.";
  if (/insufficient.*balance|ERC20.*balance/i.test(raw)) return "Insufficient token balance for this trade.";
  if (/deadline/i.test(raw)) return "Transaction took too long and expired — try again.";
  if (/slippage|minTotalTokensOut|minEthOut/i.test(raw)) return "Price moved more than expected — try again.";

  // Fall back to the first line of the revert reason if one is present,
  // otherwise a short generic message - never the full raw error blob.
  const firstLine = raw.split("\n")[0];
  return firstLine.length > 0 && firstLine.length < 120 ? firstLine : "Transaction failed.";
}

export type TxStatus = "idle" | "pending" | "success" | "error";

function useContractWrite() {
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const [status, setStatus] = useState<TxStatus>("idle");
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);

  const run = useCallback(
    async (fn: () => Promise<`0x${string}`>) => {
      setStatus("pending");
      setError(null);
      setTxHash(null);
      try {
        const hash = await fn();
        setTxHash(hash);
        if (publicClient) {
          await publicClient.waitForTransactionReceipt({ hash });
        }
        setStatus("success");
        return hash;
      } catch (e) {
        setStatus("error");
        setError(translateContractError(e));
        throw e;
      }
    },
    [publicClient]
  );

  const reset = useCallback(() => {
    setStatus("idle");
    setError(null);
    setTxHash(null);
  }, []);

  return { writeContractAsync, status, error, txHash, run, reset };
}

/** Real TickerRegistry.isAvailable() read, after the same client-side
 * format checks the contract itself enforces (length, A-Z only, reserved
 * ticker) so obviously-invalid input never needs a network round trip. */
export function useTickerAvailability(ticker: string): TickerAvailability {
  const [result, setResult] = useState<TickerAvailability>({ status: "idle" });
  const publicClient = usePublicClient();

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
    if (!isProtocolConfigured || !publicClient || !addresses.tickerRegistry) {
      setResult({ status: "idle" });
      return;
    }

    setResult({ status: "checking" });
    let cancelled = false;
    const t = setTimeout(async () => {
      try {
        const available = await publicClient.readContract({
          address: addresses.tickerRegistry!,
          abi: tickerRegistryAbi,
          functionName: "isAvailable",
          args: [normalized],
        });
        if (!cancelled) setResult(available ? { status: "available" } : { status: "taken" });
      } catch {
        if (!cancelled) setResult({ status: "idle" });
      }
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [ticker, publicClient]);

  return result;
}

export type LaunchPhase =
  | "idle"
  | "committing" // wallet tx 1 in flight
  | "waiting" // committed, waiting out MIN_REVEAL_DELAY
  | "revealing" // wallet tx 2 in flight
  | "live" // launched
  | "error";

/** Real two-transaction commit/reveal flow: TickerRegistry.commit() then,
 * after MIN_REVEAL_DELAY, TickerRegistry.reveal(). The salt is generated
 * client-side and held in memory for the duration of the flow - if the page
 * is closed mid-wait, the commitment is simply abandoned (the ticker stays
 * reserved on-chain until someone reveals it or it's superseded; this
 * matches the contract's own design, not a frontend limitation to solve
 * here). Ticker normalization and key derivation call the contract's own
 * pure `normalize`/`tickerKeyOf` functions rather than reimplementing that
 * logic client-side, so it can never drift from what `reveal()` computes. */
export function useLaunchToken() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { writeContractAsync } = useWriteContract();
  const [phase, setPhase] = useState<LaunchPhase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [tokenId, setTokenId] = useState<number | null>(null);
  const [revealAt, setRevealAt] = useState<number | null>(null);
  const pending = useRef<{ ticker: string; salt: `0x${string}`; commitHash: `0x${string}` } | null>(null);

  const execute = useCallback(
    async (input: { ticker: string }) => {
      if (!address || !publicClient || !addresses.tickerRegistry) {
        setError("Wallet not connected or protocol not configured.");
        setPhase("error");
        return;
      }
      const registry = addresses.tickerRegistry;
      setError(null);

      try {
        setPhase("committing");
        const normalized = await publicClient.readContract({
          address: registry,
          abi: tickerRegistryAbi,
          functionName: "normalize",
          args: [input.ticker],
        });
        const tickerKey = await publicClient.readContract({
          address: registry,
          abi: tickerRegistryAbi,
          functionName: "tickerKeyOf",
          args: [normalized],
        });

        const salt = crypto.getRandomValues(new Uint8Array(32));
        const saltHex = `0x${Array.from(salt).map((b) => b.toString(16).padStart(2, "0")).join("")}` as `0x${string}`;

        // Mirrors the contract exactly: keccak256(abi.encode(sender, tickerKey, salt))
        const commitHash = keccak256(
          encodeAbiParameters(
            [{ type: "address" }, { type: "bytes32" }, { type: "bytes32" }],
            [address, tickerKey, saltHex]
          )
        );

        pending.current = { ticker: normalized, salt: saltHex, commitHash };

        const hash = await writeContractAsync({
          address: registry,
          abi: tickerRegistryAbi,
          functionName: "commit",
          args: [commitHash],
        });
        await publicClient.waitForTransactionReceipt({ hash });

        const minRevealDelay = await publicClient.readContract({
          address: registry,
          abi: tickerRegistryAbi,
          functionName: "MIN_REVEAL_DELAY",
        });
        setRevealAt(Date.now() + Number(minRevealDelay) * 1000);
        setPhase("waiting");
      } catch (e) {
        setError(translateContractError(e));
        setPhase("error");
      }
    },
    [address, publicClient, writeContractAsync]
  );

  const reveal = useCallback(async () => {
    if (!publicClient || !addresses.tickerRegistry || !pending.current) return;
    const registry = addresses.tickerRegistry;
    try {
      setPhase("revealing");
      const hash = await writeContractAsync({
        address: registry,
        abi: tickerRegistryAbi,
        functionName: "reveal",
        args: [pending.current.ticker, pending.current.salt],
        value: BigInt(Math.round(LAUNCH_PRICE_ETH * 1e18)),
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });

      // Parse the Launched event directly for the real tokenId.
      const { decodeEventLog } = await import("viem");
      for (const l of receipt.logs) {
        if (l.address.toLowerCase() !== registry.toLowerCase()) continue;
        try {
          const decoded = decodeEventLog({ abi: tickerRegistryAbi, data: l.data, topics: l.topics });
          if (decoded.eventName === "Launched") {
            setTokenId(Number((decoded.args as { tokenId: bigint }).tokenId));
            break;
          }
        } catch {
          /* not this log */
        }
      }

      setPhase("live");
    } catch (e) {
      setError(translateContractError(e));
      setPhase("error");
    }
  }, [publicClient, writeContractAsync]);

  const reset = useCallback(() => {
    setPhase("idle");
    setError(null);
    setTokenId(null);
    setRevealAt(null);
    pending.current = null;
  }, []);

  return { execute, reveal, reset, phase, error, tokenId, revealAt, ticker: pending.current?.ticker ?? null };
}

/** Real BondingCurveClog.buy(minTotalTokensOut, deadline). Simulates first
 * to get the authoritative expected output (from the real contract, not
 * reimplemented math - see the report on why no separate quote function
 * exists), then submits with a 1% slippage floor computed from that
 * simulated value. */
export function useBuyToken() {
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (marketAddress: Address, ethAmount: number) => {
      if (!publicClient) throw new Error("no client");
      const value = BigInt(Math.round(ethAmount * 1e18));
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

      await run(async () => {
        const { result: expectedOut } = await publicClient.simulateContract({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "buy",
          args: [0n, deadline],
          value,
        });
        const minOut = (expectedOut * 99n) / 100n;
        return writeContractAsync({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "buy",
          args: [minOut, deadline],
          value,
        });
      });
    },
    [publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real BondingCurveClog.sell(tokenAmount, minEthOut, deadline), same
 * simulate-then-write pattern as buy. */
export function useSellToken() {
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (marketAddress: Address, tokenAmount: number) => {
      if (!publicClient) throw new Error("no client");
      const amountWei = BigInt(Math.round(tokenAmount * 1e18));
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

      await run(async () => {
        const { result } = await publicClient.simulateContract({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "sell",
          args: [amountWei, 0n, deadline],
        });
        const [expectedOut] = result;
        const minOut = (expectedOut * 99n) / 100n;
        return writeContractAsync({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "sell",
          args: [amountWei, minOut, deadline],
        });
      });
    },
    [publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real, permissionless EligibilityRegistry.qualify(tokenId). */
export function useQualifyToken() {
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();

  const execute = useCallback(
    async (tokenId: number) => {
      if (!addresses.eligibilityRegistry) throw new Error("not configured");
      await run(() =>
        writeContractAsync({
          address: addresses.eligibilityRegistry!,
          abi: eligibilityRegistryAbi,
          functionName: "qualify",
          args: [BigInt(tokenId)],
        })
      );
    },
    [run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real RewardVault.claim(roundId, holder). */
export function useClaimReward() {
  const { address } = useAccount();
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();

  const execute = useCallback(
    async (roundId: number) => {
      if (!addresses.rewardVault || !address) throw new Error("not configured");
      await run(() =>
        writeContractAsync({
          address: addresses.rewardVault!,
          abi: rewardVaultAbi,
          functionName: "claim",
          args: [BigInt(roundId), address],
        })
      );
    },
    [address, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

// Re-export the receipt hook for components that want to render an explorer
// link once a hash is known, without each one re-deriving the pattern.
export { useWaitForTransactionReceipt };
