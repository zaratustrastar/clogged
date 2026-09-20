import { describe, it, expect } from "vitest";
import { enrichTokensWithProfiles } from "@/lib/hooks/useTokenDiscovery";
import type { TokenSummary } from "@/lib/types";
import type { TokenProfile } from "@/lib/metadata/TokenProfileStore";

function makeToken(overrides: Partial<TokenSummary> = {}): TokenSummary {
  return {
    tokenId: 1,
    ticker: "DOG",
    name: "DOG", // the existing onchain-only fallback: name mirrors ticker
    imageUrl: null, // the existing onchain-only fallback: no image metadata onchain
    marketAddress: "0x1111111111111111111111111111111111111a",
    tokenAddress: "0x2222222222222222222222222222222222222b",
    creator: "0x3333333333333333333333333333333333333c",
    createdAt: new Date(0).toISOString(),
    priceEth: 0.001,
    marketCapEth: 1_000_000,
    volume24hEth: 0,
    change1hPct: null,
    change24hPct: null,
    curveProgressPct: 10,
    eligibility: "building",
    eligibleSinceSeconds: null,
    ...overrides,
  };
}

describe("enrichTokensWithProfiles", () => {
  it("a token with no matching profile keeps its exact onchain fallback (imageUrl: null, name: ticker)", () => {
    const tokens = [makeToken({ tokenId: 1, ticker: "DOG", name: "DOG" })];
    const result = enrichTokensWithProfiles(tokens, new Map());
    expect(result[0].imageUrl).toBeNull();
    expect(result[0].name).toBe("DOG");
  });

  it("a token with a saved profile that has both imageUrl and displayName uses both", () => {
    const tokens = [makeToken({ tokenId: 1 })];
    const profiles = new Map<number, TokenProfile>([
      [1, { tokenId: 1, imageUrl: "/uploads/dog.png", displayName: "Good Boy Coin" }],
    ]);
    const result = enrichTokensWithProfiles(tokens, profiles);
    expect(result[0].imageUrl).toBe("/uploads/dog.png");
    expect(result[0].name).toBe("Good Boy Coin");
  });

  it("a saved profile with only a displayName (no image ever uploaded) leaves imageUrl at its onchain fallback (null), never a stale or fabricated URL", () => {
    const tokens = [makeToken({ tokenId: 1 })];
    const profiles = new Map<number, TokenProfile>([[1, { tokenId: 1, displayName: "Good Boy Coin" }]]);
    const result = enrichTokensWithProfiles(tokens, profiles);
    expect(result[0].imageUrl).toBeNull();
    expect(result[0].name).toBe("Good Boy Coin");
  });

  it("a saved profile with only an imageUrl (launcher skipped the name field) leaves name at its onchain fallback (the ticker)", () => {
    const tokens = [makeToken({ tokenId: 1, ticker: "DOG", name: "DOG" })];
    const profiles = new Map<number, TokenProfile>([[1, { tokenId: 1, imageUrl: "/uploads/dog.png" }]]);
    const result = enrichTokensWithProfiles(tokens, profiles);
    expect(result[0].imageUrl).toBe("/uploads/dog.png");
    expect(result[0].name).toBe("DOG");
  });

  it("an empty profiles map (e.g. the batch fetch failed) leaves every token completely unenriched - never throws, never drops a token", () => {
    const tokens = [makeToken({ tokenId: 1 }), makeToken({ tokenId: 2, ticker: "CAT", name: "CAT" })];
    const result = enrichTokensWithProfiles(tokens, new Map());
    expect(result).toHaveLength(2);
    expect(result[0].imageUrl).toBeNull();
    expect(result[1].imageUrl).toBeNull();
    expect(result[1].name).toBe("CAT");
  });

  it("each token is matched to its own profile by tokenId only - never mixed up across tokens, even when profiles are supplied out of order", () => {
    const tokens = [makeToken({ tokenId: 5, ticker: "FIVE", name: "FIVE" }), makeToken({ tokenId: 3, ticker: "THREE", name: "THREE" })];
    const profiles = new Map<number, TokenProfile>([
      [3, { tokenId: 3, imageUrl: "/uploads/three.png" }],
      [5, { tokenId: 5, imageUrl: "/uploads/five.png" }],
    ]);
    const result = enrichTokensWithProfiles(tokens, profiles);
    const byTicker = new Map(result.map((t) => [t.ticker, t]));
    expect(byTicker.get("FIVE")?.imageUrl).toBe("/uploads/five.png");
    expect(byTicker.get("THREE")?.imageUrl).toBe("/uploads/three.png");
  });

  it("every other field on the token is passed through completely unchanged - enrichment only ever touches imageUrl and name", () => {
    const tokens = [makeToken({ tokenId: 1, priceEth: 0.042, curveProgressPct: 73.5, eligibility: "qualified" })];
    const result = enrichTokensWithProfiles(tokens, new Map());
    expect(result[0].priceEth).toBe(0.042);
    expect(result[0].curveProgressPct).toBe(73.5);
    expect(result[0].eligibility).toBe("qualified");
    expect(result[0].marketAddress).toBe(tokens[0].marketAddress);
  });

  it("an empty tokens array returns an empty array", () => {
    expect(enrichTokensWithProfiles([], new Map())).toEqual([]);
  });
});
