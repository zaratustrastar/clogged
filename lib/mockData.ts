import type {
  TokenSummary,
  TokenDetail,
  RoundStatus,
  DrawResult,
  UserPosition,
  ClaimableReward,
  OwnedTickerNFT,
  Address,
} from "./types";

const ADDR = (n: number): Address =>
  `0x${n.toString(16).padStart(40, "0")}` as Address;

const now = Date.now();
const minutesAgo = (m: number) => new Date(now - m * 60_000).toISOString();
const hoursAgo = (h: number) => new Date(now - h * 3_600_000).toISOString();
const daysAgo = (d: number) => new Date(now - d * 86_400_000).toISOString();
const minutesFromNow = (m: number) => new Date(now + m * 60_000).toISOString();
const daysFromNow = (d: number) => new Date(now + d * 86_400_000).toISOString();

export const MOCK_TOKENS: TokenSummary[] = [
  {
    tokenId: 812,
    ticker: "TOAST",
    name: "Toast",
    imageUrl: null,
    marketAddress: ADDR(812),
    tokenAddress: ADDR(1812),
    creator: ADDR(101),
    createdAt: hoursAgo(3),
    priceEth: 0.0000041,
    marketCapEth: 3.69,
    volume24hEth: 8.42,
    change1hPct: 12.4,
    change24hPct: 88.1,
    curveProgressPct: 41,
    eligibility: "qualified",
    eligibleSinceSeconds: 3120,
  },
  {
    tokenId: 809,
    ticker: "MOSS",
    name: "Moss",
    imageUrl: null,
    marketAddress: ADDR(809),
    tokenAddress: ADDR(1809),
    creator: ADDR(102),
    createdAt: hoursAgo(6),
    priceEth: 0.0000019,
    marketCapEth: 1.71,
    volume24hEth: 2.05,
    change1hPct: -3.1,
    change24hPct: 14.6,
    curveProgressPct: 19,
    eligibility: "qualifying",
    eligibleSinceSeconds: 940,
  },
  {
    tokenId: 803,
    ticker: "GUSH",
    name: "Gush",
    imageUrl: null,
    marketAddress: ADDR(803),
    tokenAddress: ADDR(1803),
    creator: ADDR(103),
    createdAt: hoursAgo(11),
    priceEth: 0.0000082,
    marketCapEth: 7.38,
    volume24hEth: 19.9,
    change1hPct: 4.2,
    change24hPct: -6.8,
    curveProgressPct: 63,
    eligibility: "qualified",
    eligibleSinceSeconds: 5400,
  },
  {
    tokenId: 798,
    ticker: "PEBBLE",
    name: "Pebble",
    imageUrl: null,
    marketAddress: ADDR(798),
    tokenAddress: ADDR(1798),
    creator: ADDR(104),
    createdAt: hoursAgo(20),
    priceEth: 0.0000005,
    marketCapEth: 0.45,
    volume24hEth: 0.31,
    change1hPct: 0,
    change24hPct: -22.4,
    curveProgressPct: 4,
    eligibility: "building",
    eligibleSinceSeconds: null,
  },
  {
    tokenId: 795,
    ticker: "FERAL",
    name: "Feral",
    imageUrl: null,
    marketAddress: ADDR(795),
    tokenAddress: ADDR(1795),
    creator: ADDR(105),
    createdAt: hoursAgo(28),
    priceEth: 0.0000156,
    marketCapEth: 14.04,
    volume24hEth: 41.2,
    change1hPct: 7.9,
    change24hPct: 152.3,
    curveProgressPct: 78,
    eligibility: "qualified",
    eligibleSinceSeconds: 7200,
  },
  {
    tokenId: 790,
    ticker: "DRIFT",
    name: "Drift",
    imageUrl: null,
    marketAddress: ADDR(790),
    tokenAddress: ADDR(1790),
    creator: ADDR(106),
    createdAt: hoursAgo(35),
    priceEth: 0.0000028,
    marketCapEth: 2.52,
    volume24hEth: 1.14,
    change1hPct: -1.2,
    change24hPct: 3.4,
    curveProgressPct: 27,
    eligibility: "drawn",
    eligibleSinceSeconds: null,
  },
  {
    tokenId: 12,
    ticker: "NEWT",
    name: "Newt",
    imageUrl: null,
    marketAddress: ADDR(12),
    tokenAddress: ADDR(1012),
    creator: ADDR(107),
    createdAt: minutesAgo(6),
    priceEth: 0.0000005,
    marketCapEth: 0.45,
    volume24hEth: 0.45,
    change1hPct: null,
    change24hPct: null,
    curveProgressPct: 1,
    eligibility: "too_new",
    eligibleSinceSeconds: null,
  },
];

export const MOCK_TOKEN_DETAILS: Record<string, TokenDetail> = {
  TOAST: {
    ...MOCK_TOKENS[0],
    tickerOwner: ADDR(101),
    tickerTokenId: 812,
    realReserveEth: 3.69,
    clogRemainingTokens: 100_000_000,
    totalSupply: 1_000_000_000,
    curveAllocation: 900_000_000,
    clogAllocation: 100_000_000,
    recentActivity: [
      { id: "a1", type: "buy", address: ADDR(201), amountEth: 0.42, amountTokens: 98_200, timestamp: minutesAgo(4) },
      { id: "a2", type: "buy", address: ADDR(202), amountEth: 0.11, amountTokens: 25_600, timestamp: minutesAgo(19) },
      { id: "a3", type: "qualify", address: ADDR(0), amountEth: null, amountTokens: null, timestamp: minutesAgo(52) },
      { id: "a4", type: "sell", address: ADDR(203), amountEth: 0.06, amountTokens: 14_100, timestamp: minutesAgo(74) },
      { id: "a5", type: "launch", address: ADDR(101), amountEth: 0.002, amountTokens: null, timestamp: hoursAgo(3) },
    ],
    drawHistory: [],
  },
  GUSH: {
    ...MOCK_TOKENS[2],
    tickerOwner: ADDR(103),
    tickerTokenId: 803,
    realReserveEth: 7.38,
    clogRemainingTokens: 100_000_000,
    totalSupply: 1_000_000_000,
    curveAllocation: 900_000_000,
    clogAllocation: 100_000_000,
    recentActivity: [
      { id: "b1", type: "buy", address: ADDR(301), amountEth: 1.1, amountTokens: 132_000, timestamp: minutesAgo(8) },
      { id: "b2", type: "qualify", address: ADDR(0), amountEth: null, amountTokens: null, timestamp: hoursAgo(2) },
    ],
    drawHistory: [],
  },
  DRIFT: {
    ...MOCK_TOKENS[5],
    tickerOwner: ADDR(106),
    tickerTokenId: 790,
    realReserveEth: 2.52,
    clogRemainingTokens: 100_000_000,
    totalSupply: 1_000_000_000,
    curveAllocation: 900_000_000,
    clogAllocation: 100_000_000,
    recentActivity: [
      { id: "c1", type: "sell", address: ADDR(401), amountEth: 0.2, amountTokens: 40_000, timestamp: hoursAgo(5) },
    ],
    drawHistory: [
      {
        roundId: 1042,
        resolvedAt: hoursAgo(9),
        winningTicker: "FERAL",
        candidateCount: 5,
        jackpotEth: 6.14,
      },
    ],
  },
};

export const MOCK_ROUND_STATUS: RoundStatus = {
  roundId: 1058,
  opensAt: minutesAgo(41),
  closesAt: minutesFromNow(19),
  candidateCount: 3,
  minCandidatesToDraw: 3,
};

export const MOCK_RECENT_DRAWS: DrawResult[] = [
  { roundId: 1057, resolvedAt: hoursAgo(1), winningTicker: "GUSH", candidateCount: 4, jackpotEth: 3.21 },
  { roundId: 1056, resolvedAt: hoursAgo(2), winningTicker: "FERAL", candidateCount: 6, jackpotEth: 9.87 },
  { roundId: 1055, resolvedAt: hoursAgo(3), winningTicker: null, candidateCount: 2, jackpotEth: null },
  { roundId: 1054, resolvedAt: hoursAgo(4), winningTicker: "TOAST", candidateCount: 3, jackpotEth: 2.04 },
];

export const MOCK_USER_POSITIONS: UserPosition[] = [
  { token: MOCK_TOKENS[0], balanceTokens: 98_200, balancePctOfSupply: 0.0098 },
  { token: MOCK_TOKENS[2], balanceTokens: 132_000, balancePctOfSupply: 0.0132 },
];

export const MOCK_LAUNCHED: TokenSummary[] = [MOCK_TOKENS[4]];

export const MOCK_CLAIMABLE: ClaimableReward[] = [
  { roundId: 1054, ticker: "TOAST", tokenId: 812, amountEth: 0.612, windowClosesAt: daysFromNow(87) },
];

export const MOCK_CLAIM_HISTORY: ClaimableReward[] = [
  { roundId: 1039, ticker: "GUSH", tokenId: 803, amountEth: 1.204, windowClosesAt: daysAgo(3) },
];

export const MOCK_OWNED_TICKERS: OwnedTickerNFT[] = [
  { tokenId: 795, ticker: "FERAL", openSeaUrl: "https://opensea.io/assets/example/795" },
];

export function findTokenByTicker(ticker: string): TokenDetail | null {
  return MOCK_TOKEN_DETAILS[ticker.toUpperCase()] ?? null;
}
