import Link from "next/link";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { EligibilityBadge } from "@/components/ui/EligibilityBadge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Button } from "@/components/ui/Button";
import { formatCompact } from "@/lib/format";
import type { UserPosition } from "@/lib/types";

export function HoldingsTable({ positions }: { positions: UserPosition[] }) {
  if (positions.length === 0) {
    return (
      <EmptyState
        title="No tokens held"
        description="Tokens you buy will show up here, along with their draw status."
        action={
          <Link href="/explore">
            <Button size="sm">Explore tokens</Button>
          </Link>
        }
      />
    );
  }

  return (
    <div className="overflow-x-auto rounded-md border border-border">
      <table className="w-full min-w-[560px] border-collapse text-sm">
        <thead>
          <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-ink-faint">
            <th className="px-4 py-3 font-medium">Token</th>
            <th className="px-4 py-3 text-right font-medium">Balance</th>
            <th className="px-4 py-3 text-right font-medium">Value</th>
            <th className="px-4 py-3 text-right font-medium">Round status</th>
          </tr>
        </thead>
        <tbody>
          {positions.map((p) => (
            <tr key={p.token.tokenId} className="border-b border-border last:border-0 hover:bg-surface">
              <td className="px-4 py-3">
                <Link href={`/token/${p.token.ticker.toLowerCase()}`} className="flex items-center gap-2.5">
                  <TokenIcon ticker={p.token.ticker} size={26} />
                  <div>
                    <div className="text-sm font-medium text-ink">{p.token.name}</div>
                    <div className="text-xs text-ink-faint">{p.token.ticker}</div>
                  </div>
                </Link>
              </td>
              <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                {formatCompact(p.balanceTokens)}
              </td>
              <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                {formatCompact(p.balanceTokens * p.token.priceEth)} ETH
              </td>
              <td className="px-4 py-3 text-right">
                <EligibilityBadge stage={p.token.eligibility} compact />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
