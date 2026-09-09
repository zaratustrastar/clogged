// Protocol constants. These mirror on-chain constants exactly (see
// TickerRegistry.sol / BondingCurveClog.sol / EligibilityRegistry.sol /
// RewardVault.sol). Keeping them here means the UI never hardcodes a number
// in more than one place, and swapping to live contract reads later is a
// matter of replacing the right-hand side, not hunting through components.

export const LAUNCH_PRICE_ETH = 0.002;
export const MAX_PUBLIC_TICKERS = 7_777;
export const RESERVED_TICKER = "CLOG";

export const TOTAL_SUPPLY = 1_000_000_000;
export const CURVE_ALLOCATION = 900_000_000;
export const CLOG_ALLOCATION = 100_000_000;

export const MIN_TICKER_LENGTH = 2;
export const MAX_TICKER_LENGTH = 10;

export const ROUND_DURATION_SECONDS = 60 * 60; // 1 hour
export const REQUIRED_STREAK_SECONDS = 30 * 60; // 30 minutes continuously above threshold
export const MIN_DRAW_CANDIDATES = 3;

export const CLAIM_WINDOW_DAYS = 90;

export const TICKER_OWNER_FEE_SHARE_PCT = 20;
export const PROTOCOL_FEE_SHARE_PCT = 10;
export const WINNER_POT_FEE_SHARE_PCT = 70;
export const TRADE_TAX_PCT = 0.5;

export const OPENSEA_COLLECTION_URL =
  "https://opensea.io/collection/clog-tickers"; // TODO: replace with the real collection slug once TickerNFT is deployed and indexed

export function openSeaTickerUrl(tickerNftAddress: string, tokenId: number) {
  return `https://opensea.io/assets/${tickerNftAddress}/${tokenId}`;
}
