import clsx from "clsx";
import type { EligibilityStage } from "@/lib/types";

const CONFIG: Record<EligibilityStage, { label: string; dot: string; text: string }> = {
  building: { label: "Building", dot: "bg-ink-faint", text: "text-ink-dim" },
  qualifying: { label: "Qualifying", dot: "bg-cyan animate-pulse", text: "text-cyan" },
  ready: { label: "Ready to qualify", dot: "bg-gold animate-pulse", text: "text-gold" },
  qualified: { label: "Qualified", dot: "bg-cyan", text: "text-cyan" },
  drawn: { label: "In a past draw", dot: "bg-ink-faint", text: "text-ink-dim" },
};

export function EligibilityBadge({ stage, compact }: { stage: EligibilityStage; compact?: boolean }) {
  const c = CONFIG[stage];
  return (
    <span className={clsx("inline-flex items-center gap-1.5 text-xs font-medium", c.text)}>
      <span className={clsx("h-1.5 w-1.5 rounded-full shrink-0", c.dot)} />
      {c.label}
    </span>
  );
}
