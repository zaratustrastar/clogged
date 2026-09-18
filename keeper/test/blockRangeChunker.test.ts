import { describe, it, expect } from "vitest";
import { scanBlockRangeInChunks } from "../src/blockRangeChunker.js";

describe("scanBlockRangeInChunks", () => {
  it("a range smaller than the chunk size makes exactly one call", async () => {
    const calls: { from: bigint; to: bigint }[] = [];
    const result = await scanBlockRangeInChunks(100n, 150n, 2000n, async (from, to) => {
      calls.push({ from, to });
      return [`${from}-${to}`];
    });
    expect(calls).toEqual([{ from: 100n, to: 150n }]);
    expect(result).toEqual(["100-150"]);
  });

  it("a range exactly equal to the chunk size makes exactly one call", async () => {
    const calls: { from: bigint; to: bigint }[] = [];
    // 2000 blocks inclusive: 0..1999
    await scanBlockRangeInChunks(0n, 1999n, 2000n, async (from, to) => {
      calls.push({ from, to });
      return [];
    });
    expect(calls).toEqual([{ from: 0n, to: 1999n }]);
  });

  it("a range one block larger than the chunk size makes exactly two calls", async () => {
    const calls: { from: bigint; to: bigint }[] = [];
    // 2001 blocks inclusive: 0..2000
    await scanBlockRangeInChunks(0n, 2000n, 2000n, async (from, to) => {
      calls.push({ from, to });
      return [];
    });
    expect(calls).toEqual([
      { from: 0n, to: 1999n },
      { from: 2000n, to: 2000n },
    ]);
  });

  it("REQUIREMENT: no gap or duplicate at chunk boundaries - every block in the range is covered by exactly one chunk", async () => {
    const covered = new Set<bigint>();
    const chunkRanges: { from: bigint; to: bigint }[] = [];
    await scanBlockRangeInChunks(0n, 10_037n, 1000n, async (from, to) => {
      chunkRanges.push({ from, to });
      for (let b = from; b <= to; b++) covered.add(b);
      return [];
    });

    // Every block from 0 to 10037 inclusive is covered exactly once.
    for (let b = 0n; b <= 10_037n; b++) {
      expect(covered.has(b)).toBe(true);
    }
    expect(covered.size).toBe(10_038); // 0..10037 inclusive, no duplicates counted twice in a Set

    // Consecutive chunks are contiguous: each chunk's start is exactly the
    // previous chunk's end + 1 - the direct proof of "no gap, no overlap"
    // rather than just re-deriving it from the covered set above.
    for (let i = 1; i < chunkRanges.length; i++) {
      expect(chunkRanges[i].from).toBe(chunkRanges[i - 1].to + 1n);
    }
    expect(chunkRanges[0].from).toBe(0n);
    expect(chunkRanges[chunkRanges.length - 1].to).toBe(10_037n);
  });

  it("REQUIREMENT: results from multiple chunks equal the same conceptual single full-range call", async () => {
    // A fake "chain" of 5000 blocks, each with a deterministic fake log,
    // so we can compare chunked-vs-single results item for item without
    // any real RPC involved.
    const fakeLogsByBlock = new Map<bigint, string>();
    for (let b = 0n; b <= 4999n; b++) fakeLogsByBlock.set(b, `log-at-${b}`);

    const fetchRange = async (from: bigint, to: bigint): Promise<string[]> => {
      const logs: string[] = [];
      for (let b = from; b <= to; b++) {
        const log = fakeLogsByBlock.get(b);
        if (log) logs.push(log);
      }
      return logs;
    };

    const chunkedResult = await scanBlockRangeInChunks(0n, 4999n, 777n, fetchRange);
    const singleCallResult = await fetchRange(0n, 4999n); // the "one conceptual full-history call"

    expect(chunkedResult).toEqual(singleCallResult);
    expect(chunkedResult).toHaveLength(5000);
  });

  it("an empty range (fromBlock > toBlock) makes zero calls", async () => {
    let callCount = 0;
    const result = await scanBlockRangeInChunks(100n, 50n, 10n, async () => {
      callCount++;
      return [];
    });
    expect(callCount).toBe(0);
    expect(result).toEqual([]);
  });

  it("a single-block range makes exactly one call covering just that block", async () => {
    const calls: { from: bigint; to: bigint }[] = [];
    await scanBlockRangeInChunks(500n, 500n, 2000n, async (from, to) => {
      calls.push({ from, to });
      return [];
    });
    expect(calls).toEqual([{ from: 500n, to: 500n }]);
  });

  it("rejects a non-positive chunk size rather than looping forever", async () => {
    await expect(scanBlockRangeInChunks(0n, 100n, 0n, async () => [])).rejects.toThrow(/chunkSizeBlocks must be positive/);
    await expect(scanBlockRangeInChunks(0n, 100n, -5n, async () => [])).rejects.toThrow(/chunkSizeBlocks must be positive/);
  });

  describe("interChunkDelayMs pacing semantics", () => {
    // A small real delay (not vi.useFakeTimers) - fast enough to keep the
    // suite quick, large enough to reliably distinguish "a delay
    // happened" from normal synchronous overhead between calls.
    const DELAY_MS = 30;

    it("REQUIREMENT: delay occurs between chunks only - never before the first, never after the last (chunk1, delay, chunk2, delay, chunk3, no trailing delay)", async () => {
      const callTimestamps: number[] = [];
      const start = Date.now();

      await scanBlockRangeInChunks(0n, 2999n, 1000n, async () => {
        callTimestamps.push(Date.now() - start);
        return [];
      }, DELAY_MS);
      const totalElapsed = Date.now() - start;

      expect(callTimestamps).toHaveLength(3); // 3 chunks: [0-999],[1000-1999],[2000-2999]

      // No delay before the first fetch - it happens essentially
      // immediately (well under one delay interval).
      expect(callTimestamps[0]).toBeLessThan(DELAY_MS);
      // A real delay elapsed BETWEEN chunk 1's fetch and chunk 2's fetch.
      expect(callTimestamps[1] - callTimestamps[0]).toBeGreaterThanOrEqual(DELAY_MS * 0.8);
      // A real delay elapsed BETWEEN chunk 2's fetch and chunk 3's fetch.
      expect(callTimestamps[2] - callTimestamps[1]).toBeGreaterThanOrEqual(DELAY_MS * 0.8);
      // NO trailing delay after the last (3rd) chunk's fetch - the whole
      // function returns almost immediately afterward, not one more
      // DELAY_MS later.
      expect(totalElapsed - callTimestamps[2]).toBeLessThan(DELAY_MS);
    });

    it("a single-chunk scan never delays at all, regardless of interChunkDelayMs - there is no second chunk to pace against", async () => {
      const start = Date.now();
      await scanBlockRangeInChunks(0n, 500n, 2000n, async () => [], DELAY_MS);
      expect(Date.now() - start).toBeLessThan(DELAY_MS);
    });

    it("interChunkDelayMs=0 (the default) never delays, even across many chunks", async () => {
      const start = Date.now();
      await scanBlockRangeInChunks(0n, 9999n, 1000n, async () => [], 0);
      expect(Date.now() - start).toBeLessThan(DELAY_MS); // 10 chunks, still fast - no pacing applied
    });

    it("chunk boundaries remain exactly correct (contiguous, no gap, no duplicate) with pacing enabled - pacing never perturbs the range math", async () => {
      const chunkRanges: { from: bigint; to: bigint }[] = [];
      await scanBlockRangeInChunks(0n, 3_247n, 1000n, async (from, to) => {
        chunkRanges.push({ from, to });
        return [];
      }, 1); // minimal real delay, just to prove it coexists correctly with the range math
      expect(chunkRanges[0].from).toBe(0n);
      for (let i = 1; i < chunkRanges.length; i++) {
        expect(chunkRanges[i].from).toBe(chunkRanges[i - 1].to + 1n);
      }
      expect(chunkRanges[chunkRanges.length - 1].to).toBe(3_247n);
    });
  });
});
