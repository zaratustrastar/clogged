"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  useAccount,
  usePublicClient,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { encodeAbiParameters, encodePacked, maxUint256, keccak256, decodeEventLog, BaseError, ContractFunctionRevertedError, type Address, type Log } from "viem";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { tickerRegistryAbi } from "@/lib/web3/abis/tickerRegistry";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { memeTokenAbi } from "@/lib/web3/abis/memeToken";
import { eligibilityRegistryAbi } from "@/lib/web3/abis/eligibilityRegistry";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";
import { clogV4HookAbi } from "@/lib/web3/abis/clogV4Hook";
import { universalRouterAbi } from "@/lib/web3/abis/universalRouter";
import { permit2Abi } from "@/lib/web3/abis/permit2";
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

function useContractWrite(translateError: (err: unknown) => string = translateContractError) {
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
        queryClient.invalidateQueries({ queryKey: ["clog-permit2-allowance"] });
        queryClient.invalidateQueries({ queryKey: ["clog-permit2-router-allowance"] });
        return hash;
      } catch (e) {
        setStatus("error");
        setError(translateError(e));
        throw e;
      }
    },
    [publicClient, queryClient, translateError]
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

// ============================================================================
// v4 trading path: wallet -> real Robinhood Universal Router -> real deployed
// PoolManager -> the universal ClogV4Hook -> canonical BondingCurveClog.
// Active only when isV4TradingConfigured is true (see lib/web3/env.ts) - the
// direct-path hooks above (useBuyToken/useSellToken) remain fully intact and
// are what TradeWidget falls back to otherwise. See docs/V4_TRADING.md for
// the full architecture note and the operator's own encoding-compatibility
// caveat.
// ============================================================================

const V4_ACTION_SETTLE = 0x0b;
const V4_ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
const V4_ACTION_TAKE_ALL = 0x0f;
const UNIVERSAL_ROUTER_COMMAND_V4_SWAP = 0x10;

const POOL_KEY_ABI_TYPE = {
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;

// The Robinhood-compatible ExactInputSingleParams encoding, including
// minHopPriceX36 immediately before hookData - per the operator's own
// confirmation (current Uniswap documentation/Trading API identifies the
// Robinhood deployment as Universal Router v2.1.1) plus independently-found
// third-party ecosystem documentation describing this exact field placement.
// This has NOT been independently re-verified against deployed bytecode or
// verified Blockscout source for the live router address - see
// docs/V4_TRADING.md for the full caveat. If this encoding is wrong, the
// real router reverts on a genuine ABI mismatch rather than silently
// misbehaving.
const EXACT_INPUT_SINGLE_PARAMS_ABI_TYPE = {
  type: "tuple",
  components: [
    { ...POOL_KEY_ABI_TYPE, name: "poolKey" },
    { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" },
    { name: "amountOutMinimum", type: "uint128" },
    { name: "minHopPriceX36", type: "uint256" },
    { name: "hookData", type: "bytes" },
  ],
} as const;

type V4PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};

/** Every CLOG v4 pool has native ETH as currency0 and the meme token as
 * currency1 by construction (PoolManager.initialize requires currency0 <
 * currency1, and native ETH - address(0) - is the lowest possible address).
 * Confirmed directly against ClogV4Hook.sol's own contract-level notes, not
 * assumed here independently. */
function buildV4PoolKey(tokenAddress: Address, hookAddress: Address): V4PoolKey {
  return {
    currency0: "0x0000000000000000000000000000000000000000" as Address,
    currency1: tokenAddress,
    fee: 0,
    tickSpacing: 60,
    hooks: hookAddress,
  };
}

function buildV4SwapCalldata(params: {
  poolKey: V4PoolKey;
  zeroForOne: boolean;
  amountIn: bigint;
  minAmountOut: bigint;
  deadline: bigint;
  settleCurrency: Address;
  takeCurrency: Address;
}): { commands: `0x${string}`; inputs: `0x${string}`[] } {
  const actions = encodePacked(
    ["uint8", "uint8", "uint8"],
    [V4_ACTION_SETTLE, V4_ACTION_SWAP_EXACT_IN_SINGLE, V4_ACTION_TAKE_ALL]
  );

  const settleParams = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "bool" }],
    [params.settleCurrency, params.amountIn, true]
  );
  const swapParams = encodeAbiParameters(
    [EXACT_INPUT_SINGLE_PARAMS_ABI_TYPE],
    [
      {
        poolKey: params.poolKey,
        zeroForOne: params.zeroForOne,
        amountIn: params.amountIn,
        amountOutMinimum: 0n,
        minHopPriceX36: 0n,
        // User-controlled deadline, enforced by ClogV4Hook itself before it
        // ever touches BondingCurveClog - see ClogV4Hook.sol's own
        // beforeSwap for the exact check.
        hookData: encodeAbiParameters([{ type: "uint256" }], [params.deadline]),
      },
    ]
  );
  // Slippage protection lives at the router's own TAKE_ALL minAmount check -
  // the standard v4 pattern (the router, not the pool/hook, enforces the
  // user's minimum received).
  const takeAllParams = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    [params.takeCurrency, params.minAmountOut]
  );

  const v4SwapInput = encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    [actions, [settleParams, swapParams, takeAllParams]]
  );

  const commands = encodePacked(["uint8"], [UNIVERSAL_ROUTER_COMMAND_V4_SWAP]);
  return { commands, inputs: [v4SwapInput] };
}

const NATIVE_ETH_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

/** Real, zero-drift quote for the v4 path: ClogV4Hook.quoteExactInput is a
 * revert-based quoter (the standard v4-periphery Quoter pattern) - it always
 * reverts with QuoteResult(amountOut), by design, so it can safely call the
 * real, state-changing BondingCurveClog.buy()/sell() to get an exact answer
 * and then unwind every state change. Never returns a normal value; the
 * amount is decoded from the revert data. */
export async function quoteV4ExactInput(params: {
  publicClient: NonNullable<ReturnType<typeof usePublicClient>>;
  tokenAddress: Address;
  isBuy: boolean;
  amountIn: bigint;
  account: Address;
}): Promise<bigint> {
  try {
    await params.publicClient.simulateContract({
      address: addresses.clogV4Hook!,
      abi: clogV4HookAbi,
      functionName: "quoteExactInput",
      args: [params.tokenAddress, params.isBuy, params.amountIn],
      value: params.isBuy ? params.amountIn : 0n,
      account: params.account,
    });
    throw new Error("quoteExactInput must always revert with QuoteResult");
  } catch (err) {
    if (err instanceof BaseError) {
      const revertError = err.walk((e) => e instanceof ContractFunctionRevertedError);
      if (revertError instanceof ContractFunctionRevertedError && revertError.data?.errorName === "QuoteResult") {
        const [amountOut] = revertError.data.args as [bigint];
        return amountOut;
      }
    }
    throw err;
  }
}

/** Real exact-input ETH -> meme token, through the real Robinhood Universal
 * Router -> real deployed PoolManager -> ClogV4Hook -> BondingCurveClog. Same
 * 1% slippage tolerance and 600-second, chain-timestamp-derived deadline as
 * the direct path (useBuyToken above) - the deadline is passed to the hook
 * via hookData (abi-encoded uint256), which ClogV4Hook itself enforces
 * against BondingCurveClog's own deadline check before ever touching curve
 * state. */
export function useBuyTokenV4() {
  const { address } = useAccount();
  const { run, status, error, txHash, reset } = useContractWrite(translateV4ContractError);
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (tokenAddress: Address, ethAmount: number) => {
      if (!publicClient || !address) throw new Error("no client");
      if (!addresses.universalRouter || !addresses.clogV4Hook) throw new Error("v4 trading not configured");
      const value = BigInt(Math.round(ethAmount * 1e18));
      const poolKey = buildV4PoolKey(tokenAddress, addresses.clogV4Hook);

      await run(async () => {
        const expectedOut = await quoteV4ExactInput({
          publicClient,
          tokenAddress,
          isBuy: true,
          amountIn: value,
          account: address,
        });
        const minOut = (expectedOut * 99n) / 100n;
        const latestBlock = await publicClient.getBlock();
        const deadline = latestBlock.timestamp + 600n;

        const { commands, inputs } = buildV4SwapCalldata({
          poolKey,
          zeroForOne: true,
          amountIn: value,
          minAmountOut: minOut,
          deadline,
          settleCurrency: NATIVE_ETH_ADDRESS,
          takeCurrency: tokenAddress,
        });

        return writeContractAsync({
          address: addresses.universalRouter!,
          abi: universalRouterAbi,
          functionName: "execute",
          args: [commands, inputs],
          value,
        });
      });
    },
    [address, publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real Permit2 allowance state for the v4 sell path - distinct from
 * useTokenAllowance above (which checks the direct ERC20 allowance to the
 * BondingCurveClog market itself). The v4 path never approves the market or
 * the router directly; it goes through Permit2's own two-step allowance:
 * (1) a standard ERC20 approve from the user to Permit2 itself, (2) a
 * Permit2-level approve from Permit2 granting the Universal Router an
 * allowance for that specific token, with its own expiration. Both are
 * checked here, mirroring useTokenAllowance's own query shape. */
export function usePermit2AllowanceState(tokenAddress: Address | undefined, owner: Address | undefined) {
  const publicClient = usePublicClient();
  const erc20ToPermit2 = useTokenAllowance(tokenAddress, owner, addresses.permit2);

  const permit2ToRouter = useQuery({
    queryKey: ["clog-permit2-router-allowance", tokenAddress, owner, addresses.universalRouter],
    enabled: Boolean(tokenAddress && owner && addresses.permit2 && addresses.universalRouter && publicClient),
    refetchInterval: 15_000,
    queryFn: async (): Promise<{ amount: bigint; expiration: number }> => {
      if (!tokenAddress || !owner || !addresses.permit2 || !addresses.universalRouter || !publicClient) {
        throw new Error("not ready");
      }
      const [amount, expiration] = await publicClient.readContract({
        address: addresses.permit2,
        abi: permit2Abi,
        functionName: "allowance",
        args: [owner, tokenAddress, addresses.universalRouter],
      });
      return { amount, expiration };
    },
  });

  return {
    erc20ToPermit2Allowance: erc20ToPermit2.allowance,
    permit2ToRouterAmount: permit2ToRouter.data?.amount ?? null,
    permit2ToRouterExpiration: permit2ToRouter.data?.expiration ?? null,
    isLoading: erc20ToPermit2.isLoading || permit2ToRouter.isLoading,
  };
}

/** Step 1 of the v4 sell approval: approve the MemeToken to Permit2 itself
 * (standard ERC20 approve, one-time per token, reusable across any
 * Permit2-integrated protocol - not specific to CLOG or to this router). */
export function useApproveTokenToPermit2() {
  const { run, status, error, txHash, reset } = useContractWrite(translateV4ContractError);
  const { writeContractAsync } = useWriteContract();

  const execute = useCallback(
    async (tokenAddress: Address) => {
      if (!addresses.permit2) throw new Error("v4 trading not configured");
      await run(() =>
        writeContractAsync({
          address: tokenAddress,
          abi: memeTokenAbi,
          functionName: "approve",
          args: [addresses.permit2!, maxUint256],
        })
      );
    },
    [run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Step 2 of the v4 sell approval: grant the Universal Router a Permit2-
 * level allowance for the exact amount about to be sold, with a bounded
 * expiration (1 hour) rather than an indefinite one - scoped to this trade,
 * not a standing approval. */
export function useApprovePermit2ForRouter() {
  const { run, status, error, txHash, reset } = useContractWrite(translateV4ContractError);
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (tokenAddress: Address, amount: bigint) => {
      if (!publicClient || !addresses.permit2 || !addresses.universalRouter) throw new Error("v4 trading not configured");
      const latestBlock = await publicClient.getBlock();
      const expiration = Number(latestBlock.timestamp + 3600n);
      await run(() =>
        writeContractAsync({
          address: addresses.permit2!,
          abi: permit2Abi,
          functionName: "approve",
          args: [tokenAddress, addresses.universalRouter!, amount, expiration],
        })
      );
    },
    [publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Real exact-input meme token -> ETH, through real Permit2 -> the real
 * Robinhood Universal Router -> real deployed PoolManager -> ClogV4Hook ->
 * BondingCurveClog. Assumes both Permit2 approval steps above have already
 * succeeded - TradeWidget's own v4 sell flow gates this call on that state,
 * exactly as the direct-path sell flow gates on the direct ERC20 approval. */
export function useSellTokenV4() {
  const { address } = useAccount();
  const { run, status, error, txHash, reset } = useContractWrite(translateV4ContractError);
  const { writeContractAsync } = useWriteContract();
  const publicClient = usePublicClient();

  const execute = useCallback(
    async (tokenAddress: Address, tokenAmountWei: bigint) => {
      if (!publicClient || !address) throw new Error("no client");
      if (!addresses.universalRouter || !addresses.clogV4Hook) throw new Error("v4 trading not configured");
      const poolKey = buildV4PoolKey(tokenAddress, addresses.clogV4Hook);

      await run(async () => {
        const expectedOut = await quoteV4ExactInput({
          publicClient,
          tokenAddress,
          isBuy: false,
          amountIn: tokenAmountWei,
          account: address,
        });
        const minOut = (expectedOut * 99n) / 100n;
        const latestBlock = await publicClient.getBlock();
        const deadline = latestBlock.timestamp + 600n;

        const { commands, inputs } = buildV4SwapCalldata({
          poolKey,
          zeroForOne: false,
          amountIn: tokenAmountWei,
          minAmountOut: minOut,
          deadline,
          settleCurrency: tokenAddress,
          takeCurrency: NATIVE_ETH_ADDRESS,
        });

        return writeContractAsync({
          address: addresses.universalRouter!,
          abi: universalRouterAbi,
          functionName: "execute",
          args: [commands, inputs],
        });
      });
    },
    [address, publicClient, run, writeContractAsync]
  );

  return { execute, status, error, txHash, reset };
}

/** Distinguishes wallet/Permit2/router/hook/curve failures for the v4 path -
 * layered on top of translateContractError, since a v4 trade failure can
 * originate from any of five different contracts, and PoolManager's own
 * Hooks.callHook wraps a reverting hook's error via
 * CustomRevert.bubbleUpAndRevertWith (confirmed directly against the
 * vendored v4-core source this session) rather than bubbling the raw
 * selector - so the underlying reason is nested inside a WrappedError, not
 * available as the top-level revert reason the way it is on the direct
 * path. */
export function translateV4ContractError(err: unknown): string {
  if (err instanceof Error && /user rejected/i.test(err.message)) {
    return "Transaction was rejected in your wallet.";
  }
  if (err instanceof BaseError) {
    const revertError = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revertError instanceof ContractFunctionRevertedError) {
      const name = revertError.data?.errorName;
      if (name === "WrappedError") {
        // The hook's own real reason is nested inside - fall back to a
        // hook-scoped message rather than surfacing the raw wrapper name,
        // since decoding the nested reason requires the hook's own ABI,
        // not generically available here.
        return "The trading hook rejected this swap — it may not recognize this market, or the trade no longer meets its requirements.";
      }
      if (name === "UnregisteredMarket") return "This token isn't registered for v4 trading yet.";
      if (name === "OnlyExactInputSupported") return "Only exact-input trades are supported on the v4 path.";
      if (name === "DeadlineExpired") return "Transaction took too long and expired — try again.";
      if (revertError.reason === "expired") return "Transaction took too long and expired — try again.";
      if (revertError.reason === "slippage") return "Price moved more than expected — try again.";
    }
  }
  // Fall back to the direct-path translator for anything else (ERC20/curve-
  // level reasons reachable through the hook are the same underlying
  // reverts BondingCurveClog itself produces).
  return translateContractError(err);
}
