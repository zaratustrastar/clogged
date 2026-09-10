import { colorForTicker } from "@/lib/tickerColor";

export function TokenIcon({ ticker, size = 32 }: { ticker: string; size?: number }) {
  const color = colorForTicker(ticker);
  return (
    <span
      className="flex shrink-0 items-center justify-center rounded font-display font-semibold text-bg"
      style={{ width: size, height: size, backgroundColor: color, fontSize: size * 0.4 }}
    >
      {ticker.slice(0, 1)}
    </span>
  );
}
