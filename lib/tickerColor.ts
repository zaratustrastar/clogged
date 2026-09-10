export const TICKER_COLOR_PALETTE = ["#1FF0D4", "#FFB238", "#7DA6FF", "#FF9F6B", "#B98CFF", "#6BD98C"];

export function colorForTicker(ticker: string): string {
  let hash = 0;
  for (let i = 0; i < ticker.length; i++) hash = (hash * 31 + ticker.charCodeAt(i)) >>> 0;
  return TICKER_COLOR_PALETTE[hash % TICKER_COLOR_PALETTE.length];
}
