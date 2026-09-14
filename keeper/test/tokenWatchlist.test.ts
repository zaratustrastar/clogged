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
    // chunkSizeBlocks explicitly large enough that the mock's fixed
    // getBlockNumber() (2000n) fits in a single chunk here - this test is
    // about call count not scaling with MARKET count, not about chunk-size
    // boundary behavior, which blockRangeChunker.test.ts covers directly.
    const { clients: smallClients } = makeMockClients({});
    const smallWatchlist = TokenWatchlist.withKnownTokens(
      smallClients.robinhoodPublic,
      config.eligibilityRegistry,
      [{ tokenId: 1n, market: "0x2000000000000000000000000000000000000a" as `0x${string}` }],
      1_000_000n
    );
    await smallWatchlist.scanForTradeActivity();
    const smallCallCount = (smallClients.robinhoodPublic.getLogs as unknown as { mock: { calls: unknown[] } }).mock.calls.length;

    const { clients: bigClients } = makeMockClients({});
    const bigTokens = [];
    for (let i = 1n; i <= 5000n; i++) {
      bigTokens.push({ tokenId: i, market: `0x${i.toString(16).padStart(40, "0")}` as `0x${string}` });
    }
    const bigWatchlist = TokenWatchlist.withKnownTokens(bigClients.robinhoodPublic, config.eligibilityRegistry, bigTokens, 1_000_000n);
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

describe("TokenWatchlist - chunked historical reconstruction (bounded block-range chunker)", () => {
  /** A tiny fake chain: TokenRegistered events for several tokens spread
   * across a wide block range, keyed by which block they "happened" at -
   * used to simulate a real getContractEvents call that only returns logs
   * actually within the requested [fromBlock, toBlock] window, so a
   * chunked scan is forced to genuinely combine multiple chunks to see
   * the full picture. */
  function makeFakeChainClient(latestBlock: bigint, aboveThresholdSinceByToken: Map<bigint, bigint>) {
    const registrations = [
      { block: 50n, tokenId: 1n, market: "0x1000000000000000000000000000000000000a" as `0x${string}` },
      { block: 3_200n, tokenId: 2n, market: "0x1000000000000000000000000000000000000b" as `0x${string}` },
      { block: 7_900n, tokenId: 3n, market: "0x1000000000000000000000000000000000000c" as `0x${string}` },
    ];

    return {
      getBlockNumber: async () => latestBlock,
      getContractEvents: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) =>
        registrations
          .filter((r) => r.block >= fromBlock && r.block <= toBlock)
          .map((r) => ({ args: { tokenId: r.tokenId, market: r.market } })),
      getLogs: async () => [],
      readContract: async ({ args }: { args: [bigint] }) => aboveThresholdSinceByToken.get(args[0]) ?? 0n,
    } as unknown as Parameters<typeof TokenWatchlist.build>[0];
  }

  it("REQUIREMENT: historical reconstruction over multiple chunks produces the same state as one conceptual full-history scan", async () => {
    const activeStreaks = new Map([[2n, 12345n]]); // only token 2 currently above threshold

    const chunkedClient = makeFakeChainClient(10_000n, activeStreaks);
    const chunkedWatchlist = await TokenWatchlist.build(chunkedClient, config.eligibilityRegistry, 0n, 1000n); // 10 chunks

    const fullRangeClient = makeFakeChainClient(10_000n, activeStreaks);
    const fullRangeWatchlist = await TokenWatchlist.build(fullRangeClient, config.eligibilityRegistry, 0n, 1_000_000n); // 1 chunk

    expect(chunkedWatchlist.size).toBe(fullRangeWatchlist.size);
    expect(chunkedWatchlist.size).toBe(3);
    expect(chunkedWatchlist.activeStreakCount).toBe(fullRangeWatchlist.activeStreakCount);
    expect(chunkedWatchlist.activeStreakCount).toBe(1);

    // Concretely identical dueForCheck output between the two reconstructions.
    expect(chunkedWatchlist.dueForCheck(1n, 999_999n, 60n)).toEqual(fullRangeWatchlist.dueForCheck(1n, 999_999n, 60n));
    expect(chunkedWatchlist.dueForCheck(1n, 999_999n, 60n)).toEqual([2n]);
  });

  it("REQUIREMENT: restart reconstructs old token registrations correctly even when the history requires multiple chunks", async () => {
    // Token 1 registered at block 50 - near the very start of a
    // 10,000-block history - must be found exactly as reliably as more
    // recently registered tokens, even with a small chunk size forcing 20
    // separate chunk calls.
    const client = makeFakeChainClient(10_000n, new Map());
    const watchlist = await TokenWatchlist.build(client, config.eligibilityRegistry, 0n, 500n);

    expect(watchlist.size).toBe(3);
    // Indirect proof token 1 specifically was found: dueForCheck never
    // includes it (no active streak seeded for it here), but size
    // includes all three - the direct, positive check is that the
    // reconstruction didn't silently drop the earliest one.
  });
});
