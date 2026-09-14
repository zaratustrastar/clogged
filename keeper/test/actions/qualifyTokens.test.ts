import { describe, it, expect } from "vitest";
import { qualifyMaturedTokens } from "../../src/actions/qualifyTokens.js";
import { TokenWatchlist } from "../../src/tokenWatchlist.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

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
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

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
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("aboveThresholdSince == 0 (never above threshold, or reset by a dip) -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": 0n,
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("above threshold but not for long enough yet (not mature) -> does nothing", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 10n, // only 10s so far, needs 60s
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("never brute-forces the tokenId space: with a watchlist of 2 known tokens, exactly 2 tokens are read, regardless of nextTokenId", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": true,
      "aboveThresholdSince:42": 0n,
      // nextTokenId is deliberately NOT mocked at all - if the
      // implementation ever falls back to reading it and looping, this
      // test throws immediately (see testHelpers.ts's "no mocked
      // response" error) rather than silently passing.
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n, 42n]);

    await qualifyMaturedTokens(config, clients, lock as never, watchlist);

    const readContractMock = clients.robinhoodPublic.readContract as unknown as { mock: { calls: unknown[][] } };
    const calledFunctionNames = readContractMock.mock.calls.map((call) => (call[0] as { functionName: string }).functionName);
    expect(calledFunctionNames).not.toContain("nextTokenId");
  });

  it("once qualified for a round, the watchlist stops re-reading that token for the same round (small active watch list)", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients } = makeMockClients({
      requiredAbsoluteSeconds: 60n,
      currentRoundId: 3n,
      "aboveThresholdSince:1": nowSec - 120n,
      "isCandidate:3,1": false,
    });
    const lock = makeNoOpLock();
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

    await qualifyMaturedTokens(config, clients, lock as never, watchlist);
    // token 1 is now marked qualified for round 3 - tokensToCheck for
    // round 3 should no longer include it.
    expect(watchlist.tokensToCheck(3n)).toEqual([]);
    // but it's still tracked for a future round.
    expect(watchlist.tokensToCheck(4n)).toEqual([1n]);
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
    const watchlist = TokenWatchlist.withKnownIds(clients.robinhoodPublic, config.eligibilityRegistry, [1n]);

    const results = await qualifyMaturedTokens(config, clients, lock as never, watchlist);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });
});
