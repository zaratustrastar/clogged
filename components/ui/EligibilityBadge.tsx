import clsx from "clsx";
import type { EligibilityStage } from "@/lib/types";

const CONFIG: Record<EligibilityStage, { label: string; dot: string; text: string }> = {
  too_new: { label: "Too new", dot: "bg-ink-faint", text: "text-ink-dim" },
  building: { label: "Building activity", dot: "bg-ink-dim", text: "text-ink-dim" },
  qualifying: { label: "Qualifying", dot: "bg-cyan animate-pulse", text: "text-cyan" },
  qualified: { label: "Qualified for next draw", dot: "bg-cyan", text: "text-cyan" },
  drawn: { label: "Included in past draw", dot: "bg-ink-faint", text: "text-ink-dim" },
};

export function EligibilityBadge({ stage, compact }: { stage: EligibilityStage; compact?: boolean }) {
  const c = CONFIG[stage];
  return (
    <span className={clsx("inline-flex items-center gap-1.5 text-xs font-medium", c.text)}>
      <span className={clsx("h-1.5 w-1.5 rounded-full shrink-0", c.dot)} />
      {compact ? (stage === "qualified" ? "Qualified" : c.label) : c.label}
    </span>
  );
}
