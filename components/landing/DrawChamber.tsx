"use client";

import Link from "next/link";
import { useReadContract } from "wagmi";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { CountdownClock } from "@/components/ui/CountdownClock";
import { Skeleton } from "@/components/ui/Skeleton";
import { useTokenList, useRoundStatus } from "@/lib/hooks/useTokenData";
import { formatEth } from "@/lib/format";
import { addresses } from "@/lib/web3/addresses";
import { isProtocolConfigured } from "@/lib/web3/env";
import { rewardVaultAbi } from "@/lib/web3/abis/rewardVault";

const RING_SLOTS = 6;

export function DrawChamber() {
  const { data: tokens } = useTokenList();
  const { data: round } = useRoundStatus();
  const allQualified = (tokens ?? []).filter((t) => t.eligibility === "qualified");

  const { data: unallocatedPool } = useReadContract({
    address: addresses.rewardVault,
    abi: rewardVaultAbi,
    functionName: "unallocatedPool",
    query: { enabled: isProtocolConfigured && Boolean(addresses.rewardVault), refetchInterval: 15_000 },
  });
  const jackpotEth = unallocatedPool !== undefined ? Number(unallocatedPool) / 1e18 : null;

  const count = allQualified.length;
  const oddsLabel = count > 0 ? `${(100 / count).toFixed(0)}%` : "—";
  const slots = Array.from({ length: RING_SLOTS }, (_, i) => allQualified[i] ?? null);

  return (
    <div className="relative mx-auto aspect-square w-full max-w-[380px]">
      {/* outer slow-rotating ring */}
      <div
        className="absolute inset-0 rounded-full opacity-70"
        style={{
          background:
            "conic-gradient(from 0deg, rgba(31,240,212,0.35), rgba(185,140,255,0.25), rgba(31,240,212,0.1), rgba(31,240,212,0.35))",
          animation: "spin 50s linear infinite",
          WebkitMask: "radial-gradient(farthest-side, transparent calc(100% - 2px), #000 calc(100% - 2px))",
          mask: "radial-gradient(farthest-side, transparent calc(100% - 2px), #000 calc(100% - 2px))",
        }}
      />

      {/* candidate discs orbiting the ring */}
      {slots.map((t, i) => {
        const angle = (360 / RING_SLOTS) * i - 90;
        const radius = 46; // percent of container
        const rad = (angle * Math.PI) / 180;
        const x = 50 + radius * Math.cos(rad);
        const y = 50 + radius * Math.sin(rad);
        return (
          <div
            key={i}
            className="absolute -translate-x-1/2 -translate-y-1/2"
            style={{
              left: `${x}%`,
              top: `${y}%`,
              animation: t ? `float-disc 4s ease-in-out ${i * 0.3}s infinite` : undefined,
            }}
          >
            {t ? (
              <Link href={`/token/${t.ticker.toLowerCase()}`} className="block">
                <div className="flex h-11 w-11 items-center justify-center rounded-full border border-cyan/40 bg-surface shadow-glow-cyan">
                  <TokenIcon ticker={t.ticker} size={28} />
                </div>
              </Link>
            ) : (
              <div className="h-11 w-11 rounded-full border border-dashed border-border" />
            )}
          </div>
        );
      })}

      {/* center content */}
      <div className="absolute inset-[18%] flex flex-col items-center justify-center rounded-full border border-border bg-surface/95 text-center backdrop-blur">
        <p className="text-[10px] uppercase tracking-wider text-ink-faint">Next draw</p>
        {round ? (
          <CountdownClock targetIso={round.closesAt} size="sm" />
        ) : (
          <Skeleton className="mt-1 h-7 w-20" />
        )}
        <div className="mt-2 flex items-center gap-3 text-xs">
          <div>
            <p className="font-mono font-semibold text-gold">
              {jackpotEth === null ? "—" : formatEth(jackpotEth, { decimals: 2 })}
            </p>
            <p className="text-[10px] text-ink-faint">jackpot</p>
          </div>
          <div className="h-6 w-px bg-border" />
          <div>
            <p className="font-mono font-semibold text-cyan">{tokens ? count : "—"}</p>
            <p className="text-[10px] text-ink-faint">qualified</p>
          </div>
          <div className="h-6 w-px bg-border" />
          <div>
            <p className="font-mono font-semibold text-ink">{oddsLabel}</p>
            <p className="text-[10px] text-ink-faint">each</p>
          </div>
        </div>
        {tokens && count === 0 && (
          <p className="mt-2 px-4 text-[11px] text-ink-faint">Waiting for qualified memes</p>
        )}
      </div>

      <style jsx>{`
        @keyframes spin {
          to {
            transform: rotate(360deg);
          }
        }
        @keyframes float-disc {
          0%,
          100% {
            transform: translate(-50%, -50%) translateY(0px);
          }
          50% {
            transform: translate(-50%, -50%) translateY(-4px);
          }
        }
      `}</style>
    </div>
  );
}
