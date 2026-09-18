export function formatEth(value: number, opts: { decimals?: number } = {}) {
  const { decimals = 4 } = opts;
  if (value === 0) return "0 ETH";
  if (Math.abs(value) < 0.0001) return "<0.0001 ETH";
  return `${value.toFixed(decimals).replace(/0+$/, "").replace(/\.$/, "")} ETH`;
}

export function formatCompact(value: number) {
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

export function formatPct(value: number | null, opts: { signed?: boolean } = {}) {
  if (value === null) return "—";
  const { signed = true } = opts;
  const sign = signed && value > 0 ? "+" : "";
  return `${sign}${value.toFixed(1)}%`;
}

export function formatAddress(address: string, chars = 4) {
  if (!address || address.length < chars * 2 + 2) return address;
  return `${address.slice(0, chars + 2)}…${address.slice(-chars)}`;
}

export function formatTimeAgo(iso: string) {
  const diffMs = Date.now() - new Date(iso).getTime();
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  return `${diffDay}d ago`;
}

export function formatCountdown(targetIso: string, nowMs: number) {
  const diff = Math.max(0, new Date(targetIso).getTime() - nowMs);
  const totalSec = Math.floor(diff / 1000);
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export function formatEthPrecise(
  value: bigint | number | string,
  opts: { maxDecimals?: number; sigDigits?: number } = {},
): string {
  const { maxDecimals = 18, sigDigits = 3 } = opts;
  const n =
    typeof value === "bigint" ? Number(value) / 1e18 : typeof value === "string" ? Number(value) : value;

  if (!Number.isFinite(n)) return "—";
  if (n === 0) return "0";
  if (n >= 1) return n.toFixed(4).replace(/\.?0+$/, "");
  if (n >= 0.0001) return n.toFixed(6).replace(/\.?0+$/, "");

  // below 4dp: keep sigDigits significant figures so nonzero never reads as zero
  const exp = Math.floor(Math.log10(Math.abs(n)));
  const decimals = Math.min(maxDecimals, Math.max(0, sigDigits - 1 - exp));
  const out = n.toFixed(decimals).replace(/\.?0+$/, "");
  return out === "0" ? "<0.000001" : out;
}

/** True when a toFixed(4) render would lie about a nonzero amount. */
export function isDustEth(value: bigint | number): boolean {
  const n = typeof value === "bigint" ? Number(value) / 1e18 : value;
  return n > 0 && n < 0.0001;
}
