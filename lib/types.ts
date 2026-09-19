// Core domain types for the CLOG launchpad frontend.
// These mirror the protocol's on-chain shapes closely enough that swapping
// mock data for real contract reads should not require changing consumers.

export type Address = `0x${string}`;

export type EligibilityStage =
  | "building" // trading, but reserve hasn't crossed the qualification threshold yet
  | "qualifying" // above threshold, 30-minute streak in progress
  | "ready" // streak + progress requirements both met, but not yet confirmed by a trade/qualify() call
  | "qualified" // confirmed on-chain as a candidate for the currently open round
  | "drawn"; // was included in a round that has already resolved

export interface TokenSummary {
  tokenId: number;
  ticker: string; // normalized, e.g. "CAT"
  name: string;
  imageUrl: string | null;
  marketAddress: Address;
  tokenAddress: Address;
  creator: Address;
  createdAt: string; // ISO timestamp
  priceEth: number;
  marketCapEth: number;
  volume24hEth: number;
  change1hPct: number | null;
  change24hPct: number | null;
  curveProgressPct: number; // 0-100, share of the 900M curve allocation sold
  eligibility: EligibilityStage;
  eligibleSinceSeconds: number | null; // seconds into the current streak, if qualifying
}

export interface TokenDetail extends TokenSummary {
  tickerOwner: Address;
  tickerTokenId: number;
  realReserveEth: number;
  clogRemainingTokens: number;
  totalSupply: number;
  curveAllocation: number;
  clogAllocation: number;
  recentActivity: ActivityEvent[];
  drawHistory: DrawResult[];
}

export interface ActivityEvent {
  id: string;
  type: "buy" | "sell" | "launch" | "qualify";
  address: Address;
  amountEth: number | null;
  amountTokens: number | null;
  timestamp: string;
}

export interface DrawResult {
  roundId: number;
  resolvedAt: string;
  winningTicker: string | null; // null if the draw was skipped (too few candidates)
  candidateCount: number;
  jackpotEth: number | null;
  yourShareEth?: number; // present only in personalized contexts
}

export interface RoundStatus {
  roundId: number;
  opensAt: string;
  closesAt: string;
  candidateCount: number;
  minCandidatesToDraw: number;
}

export interface UserPosition {
  token: TokenSummary;
  balanceTokens: number;
  balancePctOfSupply: number;
}

export interface ClaimableReward {
  roundId: number;
  ticker: string;
  tokenId: number;
  /** Exact wei value from RewardVault.previewClaim - carried through as a
   * bigint from the contract read all the way to the UI, never round-
   * tripped through a JS float (which cannot represent every wei value
   * exactly and previously lost precision when converted back to a bigint
   * for display). */
  amountWei: bigint;
  windowClosesAt: string; // 5-day claim expiry
}

export interface OwnedTickerNFT {
  tokenId: number;
  ticker: string;
  openSeaUrl: string;
}

export interface LaunchFormState {
  ticker: string;
  name: string;
  imageFile: File | null;
  imagePreviewUrl: string | null;
}

export type TickerAvailability =
  | { status: "idle" }
  | { status: "checking" }
  | { status: "available" }
  | { status: "taken" }
  | { status: "reserved" } // CLOG itself
  | { status: "invalid"; reason: string };
