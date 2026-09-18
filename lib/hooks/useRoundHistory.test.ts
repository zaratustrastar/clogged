import { describe, it, expect } from "vitest";
import { scanRoundHistoryIncremental, createInitialScanState, type RoundScanClient } from "./useRoundHistory";
import type { Log } from "viem";

const ROUND_MANAGER = "0x1000000000000000000000000000000000000d" as `0x${string}`;

function makeLog(roundId: number, winnerTokenId: number, blockNumber: bigint): Log {
  return {
    args: { roundId: BigInt(roundId), winnerTokenId: BigInt(winnerTokenId) },
    blockNumber,
  } as unknown as Log;
}

/** A fake client that tracks every getContractEvents call's own
 * (fromBlock, toBlock) range - the direct evidence needed to prove
 * incremental scanning is real, not just "the return value looks right". */
function makeFakeClient(latestBlock: bigint, logsByRange: (from: bigint, to: bigint) => Log[]): RoundScanClient & { calls: { from: bigint; to: bigint }[] } {
  const calls: { from: bigint; to: bigint }[] = [];
  return {
    calls,
    getBlockNumber: async () => latestBlock,
    getContractEvents: async ({ fromBlock, toBlock }) => {
      calls.push({ from: fromBlock, to: toBlock });
      return logsByRange(fromBlock, toBlock);
    },
  };
}

describe("scanRoundHistoryIncremental", () => {
  it("REQUIREMENT: a second call with the same scanState only requests blocks after the first call's own latest - never deploymentBlock again", async () => {
    const scanState = createInitialScanState(0n);
    const allLogs = [makeLog(1, 10, 100n), makeLog(2, 20, 5_000n)];

    const client1 = makeFakeClient(6_000n, (from, to) => allLogs.filter((l) => l.blockNumber! >= from && l.blockNumber! <= to));
    const result1 = await scanRoundHistoryIncremental(client1, ROUND_MANAGER, scanState, 10_000n);
    expect(result1).toEqual([{ roundId: 2, winnerTokenId: 20 }, { roundId: 1, winnerTokenId: 10 }]);
    expect(client1.calls).toEqual([{ from: 0n, to: 6_000n }]);
    expect(scanState.lastScannedBlock).toBe(6_001n); // advanced past the first call's own latest

    // A NEW round settles between the two calls, at a block only reachable
    // in the second call's own new range.
    const newLog = makeLog(3, 30, 6_500n);
    const client2 = makeFakeClient(7_000n, (from, to) => [newLog].filter((l) => l.blockNumber! >= from && l.blockNumber! <= to));
    const result2 = await scanRoundHistoryIncremental(client2, ROUND_MANAGER, scanState, 10_000n);

    // The second call's own getContractEvents request starts exactly where
    // the first call left off (6_001n) - never 0n (deploymentBlock) again.
    expect(client2.calls).toEqual([{ from: 6_001n, to: 7_000n }]);
    // The result still contains rounds 1 and 2 from the FIRST call, even
    // though the second call's own client never returns them again - proof
    // the accumulated state, not just the latest scan's own logs, is what
    // gets returned.
    expect(result2).toEqual([
      { roundId: 3, winnerTokenId: 30 },
      { roundId: 2, winnerTokenId: 20 },
      { roundId: 1, winnerTokenId: 10 },
    ]);
  });

  it("REQUIREMENT: a failed scan leaves scanState completely unchanged, so the next call retries the exact same range rather than skipping or duplicating blocks", async () => {
    const scanState = createInitialScanState(0n);
    const failingClient: RoundScanClient = {
      getBlockNumber: async () => 5_000n,
      getContractEvents: async () => {
        throw new Error("execution reverted: bad filter"); // non-transient, no retry
      },
    };

    await expect(scanRoundHistoryIncremental(failingClient, ROUND_MANAGER, scanState, 10_000n)).rejects.toThrow(/bad filter/);

    // Completely unchanged - still at the original fromBlock, still empty.
    expect(scanState.lastScannedBlock).toBe(0n);
    expect(scanState.roundsById.size).toBe(0);

    // The next attempt (simulating a retry) requests the SAME range as the
    // failed attempt did, not some already-advanced range that would skip
    // the blocks the failure prevented us from actually scanning.
    const retryClient = makeFakeClient(5_000n, (from, to) => [makeLog(1, 10, 100n)].filter((l) => l.blockNumber! >= from && l.blockNumber! <= to));
    const result = await scanRoundHistoryIncremental(retryClient, ROUND_MANAGER, scanState, 10_000n);
    expect(retryClient.calls).toEqual([{ from: 0n, to: 5_000n }]);
    expect(result).toEqual([{ roundId: 1, winnerTokenId: 10 }]);
  });

  it("no new blocks since the last scan (latest === lastScannedBlock - 1, i.e. nothing new) makes zero getContractEvents calls", async () => {
    const scanState = createInitialScanState(5_001n); // as if a prior scan already advanced past block 5000
    const client = makeFakeClient(5_000n, () => {
      throw new Error("should never be called");
    });
    const result = await scanRoundHistoryIncremental(client, ROUND_MANAGER, scanState, 10_000n);
    expect(result).toEqual([]);
  });

  it("chunking still applies within one incremental call - a range wider than one chunk is split, not requested in a single unbounded call", async () => {
    const scanState = createInitialScanState(0n);
    const client = makeFakeClient(25_000n, () => []);
    await scanRoundHistoryIncremental(client, ROUND_MANAGER, scanState, 10_000n);
    // [0-9999], [10000-19999], [20000-25000] - three chunks, never one call
    // spanning the whole 0-25000 range.
    expect(client.calls).toEqual([
      { from: 0n, to: 9_999n },
      { from: 10_000n, to: 19_999n },
      { from: 20_000n, to: 25_000n },
    ]);
  });

  it("a duplicate RoundSettled log for the same roundId (e.g. from an overlapping re-scan) never produces a duplicate entry - Map keying by roundId de-duplicates", async () => {
    const scanState = createInitialScanState(0n);
    scanState.roundsById.set(1, { roundId: 1, winnerTokenId: 10 });
    scanState.lastScannedBlock = 100n;

    const client = makeFakeClient(200n, () => [makeLog(1, 10, 150n), makeLog(2, 20, 160n)]);
    const result = await scanRoundHistoryIncremental(client, ROUND_MANAGER, scanState, 10_000n);
    expect(result).toEqual([
      { roundId: 2, winnerTokenId: 20 },
      { roundId: 1, winnerTokenId: 10 },
    ]);
    expect(scanState.roundsById.size).toBe(2); // not 3 - round 1 was merged, not duplicated
  });
});
