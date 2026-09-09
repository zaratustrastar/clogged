import { formatAddress, formatTimeAgo } from "@/lib/format";
import type { ActivityEvent } from "@/lib/types";
import clsx from "clsx";

const LABEL: Record<ActivityEvent["type"], string> = {
  buy: "Bought",
  sell: "Sold",
  launch: "Launched",
  qualify: "Qualified for draw",
};

export function ActivityFeed({ events }: { events: ActivityEvent[] }) {
  if (events.length === 0) {
    return <p className="text-sm text-ink-dim">No activity yet.</p>;
  }

  return (
    <div className="overflow-hidden rounded-md border border-border">
      <table className="w-full border-collapse text-sm">
        <tbody>
          {events.map((e) => (
            <tr key={e.id} className="border-b border-border last:border-0">
              <td className="px-4 py-3">
                <span
                  className={clsx(
                    "text-xs font-medium",
                    e.type === "buy" && "text-cyan",
                    e.type === "sell" && "text-danger",
                    e.type === "qualify" && "text-gold",
                    e.type === "launch" && "text-ink-dim"
                  )}
                >
                  {LABEL[e.type]}
                </span>
              </td>
              <td className="px-4 py-3 font-mono text-xs text-ink-dim">
                {e.type === "qualify" ? "—" : formatAddress(e.address)}
              </td>
              <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                {e.amountEth !== null ? `${e.amountEth} ETH` : ""}
              </td>
              <td className="px-4 py-3 text-right text-xs text-ink-faint">{formatTimeAgo(e.timestamp)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
