"use client";

import { Cabinet } from "@/components/machine/Cabinet";
import { PhysicalButton, StatusLamp } from "@/components/machine/PhysicalButton";
import { txMotionState } from "@/components/machine/motion";
import { ErrorPlate, EmptyChute, NoSignal } from "@/components/machine/States";
import { prizeSkin } from "@/components/machine/Claw";
import { formatEthPrecise } from "@/lib/format";

export type ClaimRow = {
  roundNumber: number;
  ticker: string;
  /** wei — pass the bigint, never a pre-rounded float (fix F1) */
  amountWei: bigint;
  shareLabel: string;
  /** true ONLY when a claim receipt has confirmed for this round (patch P0-1) */
  claimed: boolean;
  onClaim: () => void;
  status: "idle" | "pending" | "success" | "error";
  hash?: `0x${string}` | null;
  errorMessage?: string | null;
};

/** The prize chute — first block on the dashboard.
 *
 *  THREE FIXES LIVE HERE:
 *  P0-1  "Claimed" is driven by a confirmed receipt, never set optimistically after await.
 *  P0-3  A failed vault read renders ErrorPlate + retry — never the empty state.
 *  F1    Amounts render via formatEthPrecise, so a sub-0.0001 ETH reward never reads 0.0000. */
export function PrizeChute({
  rows,
  isLoading,
  error,
  onRetry,
  claimAll,
}: {
  rows: ClaimRow[];
  isLoading?: boolean;
  error?: { message: string } | null;
  onRetry?: () => void;
  claimAll?: { onClaim: () => void; status: "idle" | "pending" | "success" | "error"; hash?: `0x${string}` | null };
}) {
  const totalWei = rows.reduce((a, r) => a + (r.claimed ? 0n : r.amountWei), 0n);
  const motion = claimAll ? txMotionState({ status: claimAll.status, hash: claimAll.hash }) : "idle";

  return (
    <Cabinet state={motion}>
      <div className="flex flex-wrap items-center justify-between gap-3.5 rounded-md border border-edge-hard bg-gradient-to-b from-chassis-700 to-chassis-900 px-[18px] py-3.5">
        <p className="m-0 font-mono text-label text-ink-500">PRIZE CHUTE</p>
        <p className="m-0 font-mono text-label text-ink-600">REWARDVAULT · PREVIEWCLAIM</p>
      </div>

      <div className="mt-3 flex flex-col gap-4 rounded-md border border-edge-hair bg-chassis-900 p-5 shadow-display">
        {isLoading ? (
          <NoSignal lines={4} />
        ) : error ? (
          /* P0-3: a read failure is NOT "no winnings". */
          <ErrorPlate
            title="Could not read your winnings"
            detail={`${error.message} — your winnings are safe onchain and nothing expired.`}
            onRetry={onRetry}
          />
        ) : rows.length === 0 ? (
          <EmptyChute
            label="CHUTE EMPTY"
            body="No settled round has paid out to your holdings yet. Quiet on purpose — no zeros dressed up as results."
          />
        ) : (
          <>
            <div className="flex flex-wrap items-end justify-between gap-4">
              <div>
                <p className="m-0 font-mono text-label text-ink-500">CLAIMABLE TOTAL</p>
                <p className="clog-fig m-0 mt-1.5 whitespace-nowrap text-[clamp(28px,4vw,40px)] leading-none text-amber">
                  {formatEthPrecise(totalWei)} ETH
                </p>
                <p className="mt-1.5 text-[12.5px] text-ink-500">
                  Across {rows.filter((r) => !r.claimed).length} settled rounds.
                </p>
              </div>
              {claimAll ? (
                <PhysicalButton state={motion} onPress={claimAll.onClaim} className="min-w-[190px]">
                  {claimAll.status === "success" ? "CLAIMED" : "CLAIM ALL"}
                </PhysicalButton>
              ) : null}
            </div>

            <div className="flex flex-col gap-2">
              {rows.map((r) => {
                const rowMotion = txMotionState({ status: r.status, hash: r.hash, disabled: r.claimed });
                return (
                  <div key={r.roundNumber} className="flex flex-wrap items-center gap-3 border border-edge-hair bg-chassis-800 px-3.5 py-3.5">
                    <span aria-hidden className="h-[34px] w-[34px] flex-none rounded-lg" style={{ background: prizeSkin(r.ticker) }} />
                    <span className="min-w-0 flex-[1_1_130px]">
                      <span className="clog-fig block text-[13px] text-ink-100">{r.ticker}</span>
                      <span className="clog-fig block text-[10.5px] text-ink-500">
                        ROUND #{r.roundNumber} · {r.shareLabel}
                      </span>
                    </span>
                    <span className="clog-fig whitespace-nowrap text-[14.5px] text-amber">
                      {formatEthPrecise(r.amountWei)} ETH
                    </span>
                    {r.errorMessage ? (
                      <span className="w-full break-words font-mono text-[11px] text-bad">{r.errorMessage}</span>
                    ) : null}
                    {/* P0-1: label follows the receipt, not the click. */}
                    {r.claimed ? (
                      <span className="whitespace-nowrap border border-edge-hair bg-chassis-900 px-3 py-2 font-mono text-[10.5px] text-ok">
                        CLAIMED
                      </span>
                    ) : (
                      <PhysicalButton state={rowMotion} onPress={r.onClaim} className="!px-4 !py-2.5 !text-xs">
                        {rowMotion === "pending" ? "CLAIMING…" : rowMotion === "awaiting-signature" ? "WALLET…" : "CLAIM"}
                      </PhysicalButton>
                    )}
                  </div>
                );
              })}
            </div>

            <StatusLamp
              tone="neutral"
              label="A CLAIM MARKS AS CLAIMED ONLY WHEN ITS RECEIPT CONFIRMS"
            />
          </>
        )}
      </div>
    </Cabinet>
  );
}
