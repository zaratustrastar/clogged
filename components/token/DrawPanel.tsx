"use client";

import Link from "next/link";
import { PhysicalButton, StatusLamp } from "@/components/machine/PhysicalButton";
import { txMotionState } from "@/components/machine/motion";

export type QualificationState =
  | { kind: "building"; curvePct: number }
  | { kind: "qualifying"; remainingLabel: string }
  | { kind: "ready" }
  | { kind: "qualified"; oddsLabel: string };

/** Qualification as prize-pool membership. The four branches are the ones the current
 *  DrawPanel already has — only presentation changed.
 *
 *  PATCH P0-2 APPLIED HERE: qualification flips to "qualified" only when the caller's
 *  status is "success" (receipt confirmed). There is no local justQualified optimism.
 *
 *  FIXME(eligibleSinceSeconds): the caller still computes remainingLabel with the repo's
 *  existing arithmetic. lib/types.ts documents the field as "seconds into the current
 *  streak" but DrawPanel/TokenTable both treat it as a unix timestamp. Resolve before
 *  trusting this countdown — see §8 of the runbook. */
export function DrawPanel({
  ticker,
  roundNumber,
  jackpotEth,
  countdown,
  state,
  status = "idle",
  hash,
  errorMessage,
  onQualify,
}: {
  ticker: string;
  roundNumber: number | null;
  jackpotEth: string | null;
  countdown: string | null;
  state: QualificationState;
  status?: "idle" | "pending" | "success" | "error";
  hash?: `0x${string}` | null;
  errorMessage?: string | null;
  onQualify?: () => void;
}) {
  const motion = txMotionState({ status, hash });

  const head = {
    building: { lamp: "neutral" as const, title: "Not in the pool yet", body: `${ticker} needs more curve progress before it can qualify for a draw.` },
    qualifying: { lamp: "wait" as const, title: "Qualifying", body: "The reserve threshold is holding. Stay above it for the full window to enter the pool." },
    ready: { lamp: "wait" as const, title: "Ready to qualify", body: "Conditions are met. One transaction enters it into the prize pool." },
    qualified: { lamp: "ok" as const, title: "In the prize pool", body: "If the claw picks it at round close, the pot splits across holders by share at settlement." },
  }[state.kind];

  return (
    <div className="flex flex-col gap-3 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-[18px]">
      <div className="flex items-center justify-between gap-2.5">
        <span className="font-mono text-label text-ink-500">DRAW STATUS</span>
        <span className="font-mono text-label text-ink-500">
          {roundNumber != null ? `ROUND #${roundNumber}` : "ROUND —"}
        </span>
      </div>

      <StatusLamp tone={head.lamp} label={head.title.toUpperCase()} />
      <p className="m-0 font-display text-[17px]">{head.title}</p>
      <p className="m-0 text-[13px] leading-[1.55] text-ink-400 text-pretty">{head.body}</p>

      <dl className="m-0 flex flex-col gap-2 font-mono text-[11.5px] text-ink-400">
        {state.kind === "qualified" ? (
          <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
            <dt>ODDS THIS ROUND</dt><dd className="m-0 whitespace-nowrap text-ink-100">{state.oddsLabel}</dd>
          </div>
        ) : null}
        {state.kind === "qualifying" ? (
          <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
            <dt>THRESHOLD HELD FOR</dt><dd className="m-0 whitespace-nowrap text-amber">{state.remainingLabel}</dd>
          </div>
        ) : null}
        {state.kind === "building" ? (
          <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
            <dt>CURVE PROGRESS</dt><dd className="m-0 whitespace-nowrap text-ink-100">{state.curvePct}%</dd>
          </div>
        ) : null}
        <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
          <dt>JACKPOT</dt><dd className="m-0 whitespace-nowrap text-amber">{jackpotEth ?? "—"}</dd>
        </div>
        <div className="flex justify-between gap-2.5">
          <dt>CLOSES IN</dt><dd className="m-0 whitespace-nowrap text-bulb">{countdown ?? "—:—"}</dd>
        </div>
      </dl>

      {errorMessage ? <p className="m-0 break-words font-mono text-[11px] text-bad">{errorMessage}</p> : null}

      {state.kind === "ready" && onQualify ? (
        <PhysicalButton state={motion} onPress={onQualify} className="w-full">
          ENTER THE POOL
        </PhysicalButton>
      ) : (
        <Link
          href="/round"
          className="border border-amber/40 bg-amber/[0.07] px-3 py-3 text-center font-mono text-meta text-amber no-underline"
        >
          WATCH THE DRAW
        </Link>
      )}
    </div>
  );
}
