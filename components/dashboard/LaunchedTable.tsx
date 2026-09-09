import Link from "next/link";
import { TokenIcon } from "@/components/ui/TokenIcon";
import { EligibilityBadge } from "@/components/ui/EligibilityBadge";
import { EmptyState } from "@/components/ui/EmptyState";
import { Button } from "@/components/ui/Button";
import { formatCompact } from "@/lib/format";
import type { TokenSummary } from "@/lib/types";

export function LaunchedTable({ tokens }: { tokens: TokenSummary[] }) {
  if (tokens.length === 0) {
    return (
      <EmptyState
        title="Nothing launched yet"
        description="Launch a meme and you'll hold its TickerNFT — earning a share of its trading fees."
        action={
          <Link href="/launch">
            <Button size="sm">Launch a token</Button>
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
            <th className="px-4 py-3 text-right font-medium">Volume</th>
            <th className="px-4 py-3 text-right font-medium">Mcap</th>
            <th className="px-4 py-3 text-right font-medium">Eligibility</th>
          </tr>
        </thead>
        <tbody>
          {tokens.map((t) => (
            <tr key={t.tokenId} className="border-b border-border last:border-0 hover:bg-surface">
              <td className="px-4 py-3">
                <Link href={`/token/${t.ticker.toLowerCase()}`} className="flex items-center gap-2.5">
                  <TokenIcon ticker={t.ticker} size={26} />
                  <div>
                    <div className="text-sm font-medium text-ink">{t.name}</div>
                    <div className="text-xs text-ink-faint">{t.ticker}</div>
                  </div>
                </Link>
              </td>
              <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                {formatCompact(t.volume24hEth)} ETH
              </td>
              <td className="px-4 py-3 text-right font-mono tabular text-xs text-ink">
                {formatCompact(t.marketCapEth)} ETH
              </td>
              <td className="px-4 py-3 text-right">
                <EligibilityBadge stage={t.eligibility} compact />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
