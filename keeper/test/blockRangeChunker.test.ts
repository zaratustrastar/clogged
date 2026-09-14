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
});
