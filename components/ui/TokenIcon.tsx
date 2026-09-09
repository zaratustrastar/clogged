const PALETTE = ["#2DE3C8", "#F4B740", "#7DA6FF", "#FF9F6B", "#B39CFF", "#6BD98C"];

function colorFor(seed: string) {
  let hash = 0;
  for (let i = 0; i < seed.length; i++) hash = (hash * 31 + seed.charCodeAt(i)) >>> 0;
  return PALETTE[hash % PALETTE.length];
}

export function TokenIcon({ ticker, size = 32 }: { ticker: string; size?: number }) {
  const color = colorFor(ticker);
  return (
    <span
      className="flex shrink-0 items-center justify-center rounded font-display font-semibold text-bg"
      style={{ width: size, height: size, backgroundColor: color, fontSize: size * 0.4 }}
    >
      {ticker.slice(0, 1)}
    </span>
  );
}
