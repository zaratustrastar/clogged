import { describe, it, expect, vi } from "vitest";
import { TokenWatchlist } from "../src/tokenWatchlist.js";
import { makeMockClients } from "./testHelpers.js";

const config = { eligibilityRegistry: "0x1000000000000000000000000000000000000c" as `0x${string}` };

describe("TokenWatchlist.scanForTradeActivity - address-less log queries (Part A fix)", () => {
  it("never passes an address filter to getLogs, regardless of how many markets are known", async () => {
    const { clients } = makeMockClients({});
    const tokens = [];
    for (let i = 1n; i <= 5000n; i++) {
      tokens.push({ tokenId: i, market: `0x${i.toString(16).padStart(40, "0")}` as `0x${string}` });
    }
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, tokens);

    await watchlist.scanForTradeActivity();

    const getLogsMock = clients.robinhoodPublic.getLogs as unknown as { mock: { calls: unknown[][] } };
    expect(getLogsMock.mock.calls.length).toBeGreaterThan(0);
    for (const call of getLogsMock.mock.calls) {
      const args = call[0] as Record<string, unknown>;
      expect(args).not.toHaveProperty("address");
    }
  });

  it("makes exactly 2 getLogs calls (Bought, Sold) whether 1 or 5,000 markets are known - request count never scales with market count", async () => {
    const { clients: smallClients } = makeMockClients({});
    const smallWatchlist = TokenWatchlist.withKnownTokens(smallClients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: "0x2000000000000000000000000000000000000a" as `0x${string}` },
    ]);
    await smallWatchlist.scanForTradeActivity();
    const smallCallCount = (smallClients.robinhoodPublic.getLogs as unknown as { mock: { calls: unknown[] } }).mock.calls.length;

    const { clients: bigClients } = makeMockClients({});
    const bigTokens = [];
    for (let i = 1n; i <= 5000n; i++) {
      bigTokens.push({ tokenId: i, market: `0x${i.toString(16).padStart(40, "0")}` as `0x${string}` });
    }
    const bigWatchlist = TokenWatchlist.withKnownTokens(bigClients.robinhoodPublic, config.eligibilityRegistry, bigTokens);
    await bigWatchlist.scanForTradeActivity();
    const bigCallCount = (bigClients.robinhoodPublic.getLogs as unknown as { mock: { calls: unknown[] } }).mock.calls.length;

    expect(smallCallCount).toBe(2);
    expect(bigCallCount).toBe(2);
    expect(bigCallCount).toBe(smallCallCount);
  });

  it("filters out logs from addresses not in the market map (e.g. an unrelated contract's same-shaped event) rather than misattributing them", async () => {
    const { clients } = makeMockClients({});
    const unrelatedLog = { address: "0x9999999999999999999999999999999999999a" as `0x${string}`, args: {} };
    (clients.robinhoodPublic.getLogs as unknown as { mockResolvedValue: (v: unknown[]) => void }).mockResolvedValue([unrelatedLog]);

    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: "0x2000000000000000000000000000000000000a" as `0x${string}` },
    ]);

    const traded = await watchlist.scanForTradeActivity();
    expect(traded).toEqual([]);
    expect(watchlist.activeStreakCount).toBe(0);
  });

  it("a real trade log (address matches a known market) correctly resolves to that market's tokenId", async () => {
    const { clients } = makeMockClients({
      "aboveThresholdSince:1": 500n,
    });
    const knownMarketLog = { address: "0x2000000000000000000000000000000000000a" as `0x${string}`, args: {} };
    (clients.robinhoodPublic.getLogs as unknown as { mockResolvedValue: (v: unknown[]) => void }).mockResolvedValue([knownMarketLog]);

    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: "0x2000000000000000000000000000000000000a" as `0x${string}` },
    ]);

    const traded = await watchlist.scanForTradeActivity();
    expect(traded).toEqual([1n]);
  });
});
