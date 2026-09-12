"use client";

import { useEffect, useState } from "react";
import { useAccount, useSimulateContract } from "wagmi";
import { parseUnits } from "viem";
import { Button } from "@/components/ui/Button";
import { useBuyToken, useSellToken, useTokenAllowance, useApproveToken, computeSellApprovalState, useBuyTokenV4, useSellTokenV4, useApproveTokenToPermit2, useApprovePermit2ForRouter, usePermit2AllowanceState, translateV4ContractError } from "@/lib/hooks/useProtocolActions";
import { TRADE_TAX_PCT } from "@/lib/constants";
import { bondingCurveClogAbi } from "@/lib/web3/abis/bondingCurveClog";
import { env, isV4TradingConfigured } from "@/lib/web3/env";
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

  // v4 path: wallet -> real Robinhood Universal Router -> real deployed
  // PoolManager -> the universal ClogV4Hook -> canonical BondingCurveClog.
  // Active only when isV4TradingConfigured (NEXT_PUBLIC_V4_TRADING_ENABLED
  // plus every required address actually present - see lib/web3/env.ts).
  // The direct path below remains fully intact as the exact fallback when
  // the flag is off, unchanged from before this feature existed.
  const directBuy = useBuyToken();
  const directSell = useSellToken();
  const v4Buy = useBuyTokenV4();
  const v4Sell = useSellTokenV4();
  const buy = isV4TradingConfigured ? v4Buy : directBuy;
  const sell = isV4TradingConfigured ? v4Sell : directSell;
  const approve = useApproveToken();
  const approveToPermit2 = useApproveTokenToPermit2();
  const approvePermit2ForRouter = useApprovePermit2ForRouter();
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

  // Direct path: BondingCurveClog.sell() calls token.transferFrom(msg.sender,
  // address(this), tokenAmount) internally - the market must be an approved
  // spender first. v4 path: the user never approves the market or the
  // router directly - approval goes through Permit2's own two-step
  // allowance (ERC20 -> Permit2, then Permit2 -> Universal Router).
  const directAllowance = useTokenAllowance(
    side === "sell" && !isV4TradingConfigured ? token.tokenAddress : undefined,
    address,
    side === "sell" && !isV4TradingConfigured ? token.marketAddress : undefined
  );
  const permit2Allowance = usePermit2AllowanceState(
    side === "sell" && isV4TradingConfigured ? token.tokenAddress : undefined,
    address
  );

  const allowanceKnown = isV4TradingConfigured
    ? permit2Allowance.erc20ToPermit2Allowance !== null && permit2Allowance.permit2ToRouterAmount !== null
    : directAllowance.allowance !== null;

  const directApprovalState = computeSellApprovalState({
    allowance: directAllowance.allowance,
    sellAmountWei,
  });
  // v4 approval is "enough" only once BOTH Permit2 steps are satisfied for
  // at least the amount being sold - the ERC20->Permit2 approval is
  // typically a one-time max approval (checked as nonzero and sufficient),
  // and the Permit2->Router allowance must cover this exact sell amount and
  // not have expired.
  const needsErc20ToPermit2 =
    sellAmountWei !== null && (permit2Allowance.erc20ToPermit2Allowance ?? 0n) < sellAmountWei;
  const needsPermit2ToRouter =
    sellAmountWei !== null &&
    ((permit2Allowance.permit2ToRouterAmount ?? 0n) < sellAmountWei ||
      (permit2Allowance.permit2ToRouterExpiration ?? 0) * 1000 < Date.now());
  const { checkingAllowance, hasEnoughAllowance, needsApproval } = isV4TradingConfigured
    ? {
        checkingAllowance: sellAmountWei !== null && !allowanceKnown,
        hasEnoughAllowance: sellAmountWei !== null && !needsErc20ToPermit2 && !needsPermit2ToRouter,
        needsApproval: needsErc20ToPermit2 || needsPermit2ToRouter,
      }
    : directApprovalState;

  const quote = useTradeQuote(token.marketAddress, side, numericAmount, sellAmountWei, hasEnoughAllowance);

  async function onApprove() {
    if (!sellAmountWei) return;
    if (isV4TradingConfigured) {
      // Two real, separate transactions - never combined into one, since
      // each is independently useful (the ERC20->Permit2 step is a
      // one-time, reusable-across-any-Permit2-protocol approval) and each
      // has its own on-chain confirmation the UI should reflect.
      if (needsErc20ToPermit2) {
        await approveToPermit2.execute(token.tokenAddress);
      }
      await approvePermit2ForRouter.execute(token.tokenAddress, sellAmountWei);
    } else {
      await approve.execute(token.tokenAddress, token.marketAddress, sellAmountWei);
    }
  }

  async function onSubmit() {
    if (side === "buy") {
      if (isV4TradingConfigured) await v4Buy.execute(token.tokenAddress, numericAmount);
      else await directBuy.execute(token.marketAddress, numericAmount);
    } else if (sellAmountWei !== null) {
      if (isV4TradingConfigured) await v4Sell.execute(token.tokenAddress, sellAmountWei);
      else await directSell.execute(token.marketAddress, sellAmountWei);
    }
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
      {side === "sell" && isV4TradingConfigured && needsApproval && (
        <p className="mt-2 text-xs text-ink-faint">
          {needsErc20ToPermit2
            ? "Step 1 of 2: approve this token to Permit2 (one-time, reusable for any Permit2 trade)."
            : "Step 2 of 2: authorize the Universal Router via Permit2 for this trade."}
        </p>
      )}
      {side === "sell" && approve.status === "success" && needsApproval && (
        <p className="mt-3 text-xs text-cyan">Approval confirmed — updating…</p>
      )}
      {side === "sell" && approveToPermit2.status === "success" && needsErc20ToPermit2 && (
        <p className="mt-3 text-xs text-cyan">Permit2 approval confirmed — updating…</p>
      )}
      {side === "sell" && approvePermit2ForRouter.status === "success" && needsPermit2ToRouter && (
        <p className="mt-3 text-xs text-cyan">Universal Router authorization confirmed — updating…</p>
      )}
      {approve.error && <p className="mt-3 text-xs text-danger">ERC20 approval failed: {approve.error}</p>}
      {approveToPermit2.error && (
        <p className="mt-3 text-xs text-danger">Permit2 approval failed: {approveToPermit2.error}</p>
      )}
      {approvePermit2ForRouter.error && (
        <p className="mt-3 text-xs text-danger">Universal Router authorization failed: {approvePermit2ForRouter.error}</p>
      )}
      {active.error && (
        <p className="mt-3 text-xs text-danger">
          {isV4TradingConfigured ? "Trade failed: " : ""}
          {active.error}
        </p>
      )}

      {side === "sell" && needsApproval ? (
        <Button
          fullWidth
          size="lg"
          className="mt-4"
          variant="secondary"
          disabled={
            !isConnected ||
            sellAmountWei === null ||
            sellAmountWei <= 0n ||
            approve.status === "pending" ||
            approveToPermit2.status === "pending" ||
            approvePermit2ForRouter.status === "pending"
          }
          onClick={onApprove}
        >
          {isV4TradingConfigured
            ? needsErc20ToPermit2
              ? approveToPermit2.status === "pending"
                ? "Confirm in wallet…"
                : `Approve ${token.ticker} for Permit2`
              : approvePermit2ForRouter.status === "pending"
                ? "Confirm in wallet…"
                : "Authorize Universal Router"
            : approve.status === "pending"
              ? "Confirm in wallet…"
              : `Approve ${token.ticker}`}
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
