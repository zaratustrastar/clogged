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

  it("makes exactly 1 getLogs call (Bought+Sold together, consolidated) whether 1 or 5,000 markets are known - request count never scales with market count", async () => {
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

    expect(smallCallCount).toBe(1);
    expect(bigCallCount).toBe(1);
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

describe("TokenWatchlist - RPC resilience: per-chunk 429/5xx retry (scanForTradeActivity)", () => {
  const FAST_RETRY = { maxAttempts: 4, baseDelayMs: 1, maxDelayMs: 5 };
  const MARKET_A = "0x2000000000000000000000000000000000000a" as `0x${string}`;
  const MARKET_B = "0x2000000000000000000000000000000000000b" as `0x${string}`;

  /** A fake trade-log stream spread across a wide block range, plus the
   * ability to fail the first N calls for one specific chunk with a
   * realistic 429-shaped error - the getLogs equivalent of roundLedger.
   * test.ts's own makeFlakyChainClient, since TokenWatchlist's trade scan
   * goes through client.getLogs({events: [...]}) rather than
   * getContractEvents. */
  function makeFlakyTradeClient(latestBlock: bigint, opts: { failChunkFrom: bigint; failChunkTo: bigint; failTimes: number }) {
    const logs = [
      { block: 300n, address: MARKET_A },
      { block: 4_500n, address: MARKET_B }, // lands in the chunk that fails once
      { block: 9_800n, address: MARKET_A },
    ];
    const callCountByChunk = new Map<string, number>();

    return {
      getBlockNumber: async () => latestBlock,
      getContractEvents: async () => [],
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
        const key = `${fromBlock}-${toBlock}`;
        const priorCalls = callCountByChunk.get(key) ?? 0;
        callCountByChunk.set(key, priorCalls + 1);

        if (fromBlock === opts.failChunkFrom && toBlock === opts.failChunkTo && priorCalls < opts.failTimes) {
          throw new Error("HTTP request failed. Status: 429 Too Many Requests");
        }

        return logs.filter((l) => l.block >= fromBlock && l.block <= toBlock).map((l) => ({ address: l.address, args: {} }));
      },
      readContract: async () => 0n, // aboveThresholdSince re-read after a trade - value itself isn't the focus of these tests
      callCountByChunk,
    } as unknown as Parameters<typeof TokenWatchlist.withKnownTokens>[0] & { callCountByChunk: Map<string, number> };
  }

  it("REQUIREMENT (A): a middle chunk 429s once during trade-activity scanning, only that chunk is retried, and the resolved traded tokenIds are exactly correct", async () => {
    const client = makeFlakyTradeClient(10_000n, { failChunkFrom: 4000n, failChunkTo: 4999n, failTimes: 1 });
    const watchlist = TokenWatchlist.withKnownTokens(
      client,
      "0x1000000000000000000000000000000000000e" as `0x${string}`,
      [
        { tokenId: 1n, market: MARKET_A },
        { tokenId: 2n, market: MARKET_B },
      ],
      1000n,
      FAST_RETRY
    );

    const traded = await watchlist.scanForTradeActivity();

    expect(client.callCountByChunk.get("4000-4999")).toBe(2); // one failure + one successful retry
    for (const [key, count] of client.callCountByChunk) {
      if (key === "4000-4999") continue;
      expect(count).toBe(1); // every other chunk called exactly once - not rescanned
    }
    expect(traded.sort()).toEqual([1n, 2n]); // both markets' trades resolved correctly despite the mid-scan failure
  });

  it("REQUIREMENT (B): a chunk that 429s persistently during trade-activity scanning exhausts retries at maxAttempts and fails clearly", async () => {
    const client = makeFlakyTradeClient(10_000n, { failChunkFrom: 4000n, failChunkTo: 4999n, failTimes: Infinity });
    const watchlist = TokenWatchlist.withKnownTokens(
      client,
      "0x1000000000000000000000000000000000000e" as `0x${string}`,
      [{ tokenId: 1n, market: MARKET_A }],
      1000n,
      FAST_RETRY
    );

    await expect(watchlist.scanForTradeActivity()).rejects.toThrow(/429/);
    expect(client.callCountByChunk.get("4000-4999")).toBe(FAST_RETRY.maxAttempts);
  });

  it("REQUIREMENT: one Bought/Sold multi-event getLogs call per chunk, never two separate calls, confirmed directly from real call args (events array, no address filter)", async () => {
    const client = makeFlakyTradeClient(10_000n, { failChunkFrom: 999_999n, failChunkTo: 999_999n, failTimes: 0 }); // never actually fails
    const calls: unknown[] = [];
    const originalGetLogs = client.getLogs;
    client.getLogs = (async (args: unknown) => {
      calls.push(args);
      return originalGetLogs(args as never);
    }) as typeof client.getLogs;

    const watchlist = TokenWatchlist.withKnownTokens(
      client,
      "0x1000000000000000000000000000000000000e" as `0x${string}`,
      [{ tokenId: 1n, market: MARKET_A }],
      1_000_000n // single chunk, so exactly one call total
    );
    await watchlist.scanForTradeActivity();

    expect(calls).toHaveLength(1);
    const callArgs = calls[0] as { events?: unknown[]; event?: unknown; address?: unknown };
    expect(Array.isArray(callArgs.events)).toBe(true);
    expect(callArgs.events).toHaveLength(2); // Bought and Sold together
    expect(callArgs.event).toBeUndefined(); // never the singular form
    expect(callArgs.address).toBeUndefined(); // still no address filter, per the earlier address-less design
  });

  it("test-only overrides do not change the conservative production default when omitted: withKnownTokens' own retryOptions match the real default exactly", () => {
    const watchlist = TokenWatchlist.withKnownTokens({} as unknown as Parameters<typeof TokenWatchlist.withKnownTokens>[0], "0x1000000000000000000000000000000000000e" as `0x${string}`, []);
    expect(watchlist.retryOptionsForTesting).toEqual({ maxAttempts: 5, baseDelayMs: 1000, maxDelayMs: 15_000 });
  });
});
