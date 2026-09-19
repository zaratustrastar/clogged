// Protocol constants, extracted directly from the deployed contract source
// (src/TickerRegistry.sol, src/EligibilityRegistry.sol, src/RoundManager.sol,
// src/BondingCurveClog.sol, src/RewardVault.sol) - not invented. These are
// Solidity `constant` values (compile-time, identical across every deployed
// instance), so hardcoding the derived numbers here is safe; if a future
// contract version changes any of them, this file needs a matching update.

export const LAUNCH_PRICE_ETH = 0.002; // TickerRegistry.LAUNCH_PRICE
export const MAX_PUBLIC_TICKERS = 7_777; // TickerRegistry.MAX_PUBLIC_TICKERS
export const RESERVED_TICKER = "CLOG";

export const TOTAL_SUPPLY = 1_000_000_000; // MemeToken.TOTAL_SUPPLY
export const CURVE_ALLOCATION = 900_000_000; // BondingCurveClog.CURVE_ALLOCATION
export const CLOG_ALLOCATION = 100_000_000; // BondingCurveClog.CLOG_ALLOCATION

export const MIN_TICKER_LENGTH = 2; // TickerRegistry.MIN_TICKER_LENGTH
export const MAX_TICKER_LENGTH = 10; // TickerRegistry.MAX_TICKER_LENGTH
export const MIN_REVEAL_DELAY_SECONDS = 60; // TickerRegistry.MIN_REVEAL_DELAY
export const REVEAL_WINDOW_SECONDS = 86_400; // TickerRegistry.REVEAL_WINDOW (1 day)

export const ROUND_DURATION_SECONDS = 3_600; // RoundManager.ROUND_DURATION (1 hour)
export const MIN_DRAW_CANDIDATES = 3; // RoundManager.MIN_DRAW_CANDIDATES

// EligibilityRegistry's two INDEPENDENT qualification gates - not one
// combined threshold. See EligibilityRegistry.sol's _maybeQualify/_touch:
// the 30-minute timer tracks `realReserve() >= MIN_RESERVE_THRESHOLD`
// continuously; `progressBps() >= MIN_PROGRESS_BPS` is checked separately,
// at the moment of qualification, with no timer of its own.
export const MIN_PROGRESS_BPS = 500; // EligibilityRegistry.MIN_PROGRESS_BPS (5%)
export const MIN_RESERVE_THRESHOLD_ETH = 0.229; // EligibilityRegistry.MIN_RESERVE_THRESHOLD
export const REQUIRED_STREAK_SECONDS = 1_800; // EligibilityRegistry.REQUIRED_ABSOLUTE_SECONDS (30 min)

export const CLAIM_WINDOW_DAYS = 5; // RewardVault.CLAIM_WINDOW

// BondingCurveClog's trading fee: 0.6% total, split three ways. The split is
// BPS-of-the-tax (TICKER_OWNER_TAX_BPS=4000 means 40% of the 0.6% tax, i.e.
// 0.24% of trade value) - not 40% of trade value. Expressed here as direct
// percentages of trade value to avoid that exact confusion in the UI.
export const TRADE_TAX_PCT = 0.6; // BUY_TAX_BPS / SELL_TAX_BPS, each 60 bps of trade value
export const TICKER_OWNER_FEE_PCT_OF_TRADE = 0.24; // 0.6% * (4000/10000)
export const PROTOCOL_FEE_PCT_OF_TRADE = 0.06; // 0.6% * (1000/10000)
export const WINNER_POT_FEE_PCT_OF_TRADE = 0.3; // 0.6% * (5000/10000)

export function openSeaTickerUrl(tickerNftAddress: string, tokenId: number) {
  return `https://opensea.io/assets/${tickerNftAddress}/${tokenId}`;
}
