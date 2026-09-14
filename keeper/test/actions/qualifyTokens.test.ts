import { describe, it, expect } from "vitest";
import { qualifyMaturedTokens } from "../../src/actions/qualifyTokens.js";
import { TokenWatchlist } from "../../src/tokenWatchlist.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

const MARKET_1 = "0x2000000000000000000000000000000000000a" as `0x${string}`;
const MARKET_42 = "0x2000000000000000000000000000000000002a" as `0x${string}`;

describe("qualifyMaturedTokens decision path", () => {
  it("mature token (above threshold long enough, not yet a candidate) -> qualifies it", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n, // above threshold for 120s, needs only 60s
      "isCandidate:3,1": false,
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n },
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(writeContract).toHaveBeenCalledTimes(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "qualify", args: [1n] });
  });

  it("already a candidate this round -> does nothing, sends no transaction", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": true, // already qualified
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n },
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("no active streak (never above threshold) -> not in dueForCheck at all, no reads beyond the watchlist scans", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      // aboveThresholdSince:1 deliberately NOT mocked - if the implementation
      // ever reads it for a token with no active streak, this test throws
      // immediately rather than silently passing.
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1 }, // no aboveThresholdSince - never active
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("active streak but not for long enough yet (not mature) -> does nothing", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 10n, // only 10s so far, needs 60s
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 10n },
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("REQUIREMENT: never reads aboveThresholdSince/isCandidate for every known token - only for tokens with an active streak that are actually due", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": true,
      // token 42 has NO active streak (not seeded below) - if the
      // implementation reads aboveThresholdSince:42 or isCandidate for it
      // anyway, this test throws immediately (no mock supplied for it).
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n },
      { tokenId: 42n, market: MARKET_42 }, // known, but never traded/active
    ]);

    await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    const readContractMock = clients.robinhoodPublic.readContract as unknown as { mock: { calls: unknown[][] } };
    const calledFunctionNames = readContractMock.mock.calls.map((call) => (call[0] as { functionName: string }).functionName);
    expect(calledFunctionNames).not.toContain("nextTokenId");
    // Exactly one aboveThresholdSince read (the re-confirm read for token
    // 1, the only due token) plus the two scalar reads
    // (requiredAbsoluteSeconds, currentRoundId) plus one isCandidate read -
    // never a second aboveThresholdSince/isCandidate pair for token 42.
    const aboveThresholdSinceCalls = readContractMock.mock.calls.filter((c) => (c[0] as { functionName: string }).functionName === "aboveThresholdSince");
    expect(aboveThresholdSinceCalls).toHaveLength(1);
  });

  it("trade activity discovers a NEWLY active token via a Bought event - the watchlist did not know about it being active before this poll", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const boughtLog = { address: MARKET_1, args: {} };
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n, // now active, re-read after the trade is observed
      "isCandidate:3,1": false,
    });
    (clients.robinhoodPublic.getLogs as unknown as { mockImplementation: (fn: (args: { event: { name: string } }) => Promise<unknown[]>) => void }).mockImplementation(
      async ({ event }: { event: { name: string } }) => (event.name === "Bought" ? [boughtLog] : [])
    );
    const lock = makeNoOpLock();
    // Token 1 known, but with NO initial active streak - it must be
    // discovered via the Bought event during scanForTradeActivity, not
    // pre-seeded.
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1 },
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(writeContract).toHaveBeenCalledTimes(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "qualify", args: [1n] });
  });

  it("a Sold event that resets the streak to 0 removes the token from the active set - no qualify call, even though it was previously active", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const soldLog = { address: MARKET_1, args: {} };
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": 0n, // the sell reset it - confirmed by the re-read after the Sold event
    });
    (clients.robinhoodPublic.getLogs as unknown as { mockImplementation: (fn: (args: { event: { name: string } }) => Promise<unknown[]>) => void }).mockImplementation(
      async ({ event }: { event: { name: string } }) => (event.name === "Sold" ? [soldLog] : [])
    );
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n }, // was active going into this poll
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
    expect(watchlist.activeStreakCount).toBe(0);
  });

  it("once qualified for a round, the token is excluded from dueForCheck for that same round (small active watch list)", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": false,
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n },
    ]);

    await qualifyMaturedTokens(config, clients, lock as never, watchlist);
    // token 1 is now marked qualified for round 3 - dueForCheck for round
    // 3 should no longer include it, even though its streak is still active.
    expect(watchlist.dueForCheck(3n, nowSec, 60n)).toEqual([]);
    // but a NEW round still requires one fresh qualify - the still-active
    // matured streak makes it due again under a different roundId.
    expect(watchlist.dueForCheck(4n, nowSec, 60n)).toEqual([1n]);
  });

  it("a qualify already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": false,
    });
    const lock = { isInFlight: async () => true, acquire: () => {}, release: () => {} };
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, [
      { tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n },
    ]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("worst case at scale: 500 known tokens, only 1 with an active streak -> only that 1 token's state is ever read", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": false,
      // No mocks for tokens 2..500 at all - if any of their state is ever
      // read, this test throws immediately.
    });
    const lock = makeNoOpLock();
    const tokens: { tokenId: bigint; market: `0x${string}`; aboveThresholdSince?: bigint }[] = [{ tokenId: 1n, market: MARKET_1, aboveThresholdSince: nowSec - 120n }];
    for (let i = 2n; i <= 500n; i++) {
      tokens.push({ tokenId: i, market: `0x${i.toString(16).padStart(40, "0")}` as `0x${string}` });
    }
    const watchlist = TokenWatchlist.withKnownTokens(clients.robinhoodPublic, config.eligibilityRegistry, tokens);

    expect(watchlist.size).toBe(500);
    expect(watchlist.activeStreakCount).toBe(1);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);
    expect(results.filter((r) => r.acted)).toHaveLength(1);
    expect(writeContract).toHaveBeenCalledTimes(1);

    const readContractMock = clients.robinhoodPublic.readContract as unknown as { mock: { calls: unknown[][] } };
    const aboveThresholdSinceCalls = readContractMock.mock.calls.filter((c) => (c[0] as { functionName: string }).functionName === "aboveThresholdSince");
    expect(aboveThresholdSinceCalls).toHaveLength(1); // only token 1's, never the other 499
  });
});
