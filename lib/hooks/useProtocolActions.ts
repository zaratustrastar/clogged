"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  useAccount,
  usePublicClient,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { encodeAbiParameters, keccak256, decodeEventLog, BaseError, ContractFunctionRevertedError, type Address, type Log } from "viem";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { memeTokenAbi } from "@/lib/web3/abis/memeToken";
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
  // Prefer viem's own structured revert reason when available - the exact,
  // clean string the contract actually reverted with (e.g. "expired",
  // "slippage"), never the surrounding diagnostic text (function
  // signature, ABI parameter names, args) that matching the raw error
  // message text below risks false-triggering on. This specifically fixes
  // two real misclassifications: buy/sell's ABI signature includes
  // "deadline", "minTotalTokensOut", and "minEthOut" as parameter names -
  // viem's own diagnostic output echoes these for EVERY call to buy/sell,
  // regardless of what actually reverted, so matching those words alone
  // is not evidence of an actual expiry or slippage failure.
  // BondingCurveClog's real revert reasons are the bare strings "expired"
  // and "slippage" - checked directly here.
  if (err instanceof BaseError) {
    const revertError = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revertError instanceof ContractFunctionRevertedError) {
      if (revertError.reason === "expired") return "Transaction took too long and expired — try again.";
      if (revertError.reason === "slippage") return "Price moved more than expected — try again.";
      // ERC20's own standard insufficient-allowance revert - normally the
      // allowance-aware sell UI (see useTokenAllowance/useApproveToken)
      // prevents this from ever being reached, but this is a defense-in-
      // depth fallback for anything that slips through (e.g. an allowance
      // that was reduced by another transaction between the check and the
      // actual sell). Checked via the decoded custom error name when
      // available, since ERC20InsufficientAllowance is a custom error
      // (OpenZeppelin 5.x), not a plain string revert reason.
      if (revertError.data?.errorName === "ERC20InsufficientAllowance") {
        return "Approve the token before selling.";
      }
    }
  }

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
  if (/insufficient allowance|ERC20InsufficientAllowance|exceeds allowance/i.test(raw)) return "Approve the token before selling.";

  // Fall back to the first line of the revert reason if one is present,
  // otherwise a short generic message - never the full raw error blob.
  const firstLine = raw.split("\n")[0];
  return firstLine.length > 0 && firstLine.length < 120 ? firstLine : "Transaction failed.";
}

export type TxStatus = "idle" | "pending" | "success" | "error";

function useContractWrite() {
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();
  const queryClient = useQueryClient();
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
        // A confirmed transaction (buy/sell/qualify/claim/launch) can
        // change real onchain state these queries cache - reserve,
        // balance, price, progress, qualification. Invalidate broadly so
        // the UI reflects it promptly rather than waiting out each
        // query's own scheduled refetch interval.
        queryClient.invalidateQueries({ queryKey: ["clog-token-discovery"] });
        queryClient.invalidateQueries({ queryKey: ["clog-token-detail"] });
        queryClient.invalidateQueries({ queryKey: ["clog-held-tokens"] });
        queryClient.invalidateQueries({ queryKey: ["clog-round-status"] });
        queryClient.invalidateQueries({ queryKey: ["clog-allowance"] });
        return hash;
      } catch (e) {
        setStatus("error");
        setError(translateContractError(e));
        throw e;
      }
    },
    [publicClient, queryClient]
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

/** Parses the real, authoritative launched tokenId from a TickerRegistry
 * reveal transaction's receipt. Extracted as a standalone, pure function
 * (no wagmi/react hooks involved) specifically so this logic - the
 * source of truth useLaunchToken's reveal() returns directly to its
 * caller, rather than relying on react state a caller's own closure might
 * read before it has actually updated - is directly testable. Returns
 * null if the Launched event isn't found/decodable, which should never
 * happen for a genuinely successful reveal. */
export function parseLaunchedTokenIdFromReceipt(logs: readonly Log[], registryAddress: string): number | null {
  for (const l of logs) {
    if (l.address.toLowerCase() !== registryAddress.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({ abi: tickerRegistryAbi, data: l.data, topics: l.topics });
      if (decoded.eventName === "Launched") {
        return Number((decoded.args as { tokenId: bigint }).tokenId);
      }
    } catch {
      /* not this log */
    }
  }
  return null;
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
  const queryClient = useQueryClient();
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

  const reveal = useCallback(async (): Promise<{ tokenId: number; txHash: `0x${string}` } | null> => {
    if (!publicClient || !addresses.tickerRegistry || !pending.current) return null;
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

      // Parse the Launched event directly for the real tokenId. This is
      // the single authoritative source - callers must use the value
      // RETURNED from this function directly, not react state read via a
      // closure captured before this call resolved (setTokenId below
      // updates state for rendering the success screen on a LATER render;
      // it is not synchronously visible to code that continues executing
      // immediately after this same await).
      const launchedTokenId = parseLaunchedTokenIdFromReceipt(receipt.logs, registry);

      if (launchedTokenId === null) {
        // The transaction succeeded onchain, but the Launched event wasn't
        // found/decoded - this should never happen for a genuine success.
        // Surfacing it as an error is safer than returning a fabricated id.
        setError("Launch transaction succeeded, but the launched tokenId could not be determined. Check your dashboard.");
        setPhase("error");
        return null;
      }

      setTokenId(launchedTokenId);
      setPhase("live");

      // The discovery cache (staleTime 15s / refetchInterval 20s) has no
      // way to know this token exists until it actually refetches - a
      // just-launched ticker is real onchain immediately, so a stale
      // discovery snapshot must never be treated as proof it doesn't
      // exist. Invalidating here means the very next component that reads
      // discovery (e.g. the token detail page reached via "View token")
      // refetches promptly instead of waiting out the scheduled interval.
      queryClient.invalidateQueries({ queryKey: ["clog-token-discovery"] });

      return { tokenId: launchedTokenId, txHash: hash };
    } catch (e) {
      setError(translateContractError(e));
      setPhase("error");
      return null;
    }
  }, [publicClient, writeContractAsync, queryClient]);

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
  const { address } = useAccount();
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (marketAddress: Address, ethAmount: number) => {
      if (!publicClient) throw new Error("no client");
      const value = BigInt(Math.round(ethAmount * 1e18));

      await run(async () => {
        // Derived from the chain's own latest block timestamp, not the
        // browser's Date.now() - immune to any local clock skew, and
        // computed fresh for this specific attempt rather than reused from
        // an earlier render, so a page left open for a long time can never
        // simulate or submit against an already-stale deadline.
        const latestBlock = await publicClient.getBlock();
        const deadline = latestBlock.timestamp + 600n;

        const { result: expectedOut } = await publicClient.simulateContract({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "buy",
          args: [0n, deadline],
          value,
          // Must match the real wallet transaction's own sender.
          // BondingCurveClog.buy() ultimately transfers purchased tokens to
          // msg.sender, and the quote simulation in TradeWidget already
          // passes the connected account - this simulation must model the
          // same caller as both of those, not an unspecified/default one.
          account: address,
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
    [address, publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real BondingCurveClog.sell(tokenAmount, minEthOut, deadline), same
 * simulate-then-write pattern as buy. Takes the exact token amount as a
 * bigint (already converted via parseUnits at the call site - see
 * TradeWidget) rather than a JS number - an 18-decimal ERC20 amount can
 * exceed what a JS number can represent exactly, so no floating-point
 * arithmetic ever touches this value. */
export function useSellToken() {
  const { address } = useAccount();
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (marketAddress: Address, tokenAmountWei: bigint) => {
      if (!publicClient) throw new Error("no client");

      await run(async () => {
        const latestBlock = await publicClient.getBlock();
        const deadline = latestBlock.timestamp + 600n;

        const { result } = await publicClient.simulateContract({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "sell",
          args: [tokenAmountWei, 0n, deadline],
          account: address,
        });
        const [expectedOut] = result;
        const minOut = (expectedOut * 99n) / 100n;
        return writeContractAsync({
          address: marketAddress,
          abi: bondingCurveClogAbi,
          functionName: "sell",
          args: [tokenAmountWei, minOut, deadline],
        });
      });
    },
    [address, publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real MemeToken.allowance(owner, spender) - BondingCurveClog.sell()
 * calls token.transferFrom(msg.sender, address(this), tokenAmount)
 * internally, so the market must be an approved spender before a sell can
 * succeed. React Query-backed so it can be invalidated (see
 * useApproveToken below) the moment an approval confirms. */
/** Whether a sell needs an ERC20 approval first, and what state that
 * check is in. Extracted as a pure function (no react-query/wagmi
 * involved) specifically so this decision is directly testable.
 * allowance is null while the allowance read hasn't resolved yet at all -
 * distinct from a resolved allowance of 0n. */
export function computeSellApprovalState(params: {
  allowance: bigint | null;
  sellAmountWei: bigint | null;
}): { checkingAllowance: boolean; hasEnoughAllowance: boolean; needsApproval: boolean } {
  const { allowance, sellAmountWei } = params;
  const hasRealAmount = sellAmountWei !== null && sellAmountWei > 0n;

  if (!hasRealAmount) {
    return { checkingAllowance: false, hasEnoughAllowance: false, needsApproval: false };
  }
  if (allowance === null) {
    return { checkingAllowance: true, hasEnoughAllowance: false, needsApproval: false };
  }
  const hasEnoughAllowance = allowance >= (sellAmountWei as bigint);
  return { checkingAllowance: false, hasEnoughAllowance, needsApproval: !hasEnoughAllowance };
}

/** Real MemeToken.allowance(owner, spender) - BondingCurveClog.sell()
 * calls token.transferFrom(msg.sender, address(this), tokenAmount)
 * internally, so the market must be an approved spender before a sell can
 * succeed. React Query-backed so it can be invalidated (see
 * useApproveToken below) the moment an approval confirms. */
export function useTokenAllowance(tokenAddress: Address | undefined, owner: Address | undefined, spender: Address | undefined) {
  const publicClient = usePublicClient();

  const query = useQuery({
    queryKey: ["clog-allowance", tokenAddress, owner, spender],
    enabled: Boolean(tokenAddress && owner && spender && publicClient),
    refetchInterval: 15_000,
    queryFn: async (): Promise<bigint> => {
      if (!tokenAddress || !owner || !spender || !publicClient) throw new Error("not ready");
      return publicClient.readContract({
        address: tokenAddress,
        abi: memeTokenAbi,
        functionName: "allowance",
        args: [owner, spender],
      });
    },
  });

  return {
    allowance: query.data ?? null,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    error: query.error ? String(query.error) : null,
  };
}

/** Real MemeToken.approve(spender, amount). Approves the exact requested
 * amount (not an unlimited/max approval) - see the report for why exact,
 * per-trade approval was preferred here. */
export function useApproveToken() {
  const { run, status, error, txHash, reset } = useContractWrite();
  const { writeContractAsync } = useWriteContract();
  const queryClient = useQueryClient();

  const execute = useCallback(
    async (tokenAddress: Address, spender: Address, amountWei: bigint) => {
      await run(() =>
        writeContractAsync({
          address: tokenAddress,
          abi: memeTokenAbi,
          functionName: "approve",
          args: [spender, amountWei],
        })
      );
      // useContractWrite's shared invalidation list doesn't know about
      // allowance queries (they're keyed by token+owner+spender, not a
      // fixed name) - invalidate explicitly here so the sell UI sees the
      // new allowance immediately rather than waiting out the 15s
      // refetchInterval above.
      queryClient.invalidateQueries({ queryKey: ["clog-allowance"] });
    },
    [run, writeContractAsync, queryClient]
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
