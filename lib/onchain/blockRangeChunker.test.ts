import { describe, it, expect, vi } from "vitest";
import { scanBlockRangeInChunks, retryTransient, isTransientRpcError } from "./blockRangeChunker";

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

  it("REQUIREMENT: no gap or duplicate at chunk boundaries - every block covered by exactly one chunk", async () => {
    const covered = new Set<bigint>();
    const chunkRanges: { from: bigint; to: bigint }[] = [];
    await scanBlockRangeInChunks(0n, 6_500n, 1000n, async (from, to) => {
      chunkRanges.push({ from, to });
      for (let b = from; b <= to; b++) covered.add(b);
      return [];
    });
    for (let b = 0n; b <= 6_500n; b++) expect(covered.has(b)).toBe(true);
    expect(covered.size).toBe(6_501);
    for (let i = 1; i < chunkRanges.length; i++) {
      expect(chunkRanges[i].from).toBe(chunkRanges[i - 1].to + 1n);
    }
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

  it("REQUIREMENT: an early event (e.g. Round 1's RoundSettled, near deploymentBlock) is found even when the full scan requires many chunks", async () => {
    // Simulates the real Round 1 case: an event near the very start of a
    // long deploymentBlock -> latest range, which a small chunk size
    // splits into many separate calls.
    const fakeEventBlock = 61564300n; // just after the real deploymentBlock, 61564258
    const latest = 61574258n; // 10,000 blocks of history
    const found = await scanBlockRangeInChunks(61564258n, latest, 1000n, async (from, to) =>
      fakeEventBlock >= from && fakeEventBlock <= to ? [{ roundId: 1 }] : []
    );
    expect(found).toEqual([{ roundId: 1 }]);
  });
});

describe("isTransientRpcError", () => {
  it("recognizes a 429 status code", () => {
    expect(isTransientRpcError({ status: 429, message: "rate limited" })).toBe(true);
  });

  it("recognizes '429 Too Many Requests' in a message with no structured status", () => {
    expect(isTransientRpcError(new Error("HTTP request failed: 429 Too Many Requests"))).toBe(true);
  });

  it("recognizes a network/timeout error message", () => {
    expect(isTransientRpcError(new Error("fetch failed: ETIMEDOUT"))).toBe(true);
  });

  it("does NOT treat a real application error (e.g. a revert) as transient", () => {
    expect(isTransientRpcError(new Error("execution reverted: insufficient balance"))).toBe(false);
  });
});

describe("retryTransient", () => {
  it("REQUIREMENT: a transient 429 followed by success - retries once and returns the eventual successful result", async () => {
    let attempts = 0;
    const fn = vi.fn(async () => {
      attempts++;
      if (attempts === 1) {
        const err = new Error("429 Too Many Requests");
        throw err;
      }
      return "success-on-retry";
    });

    const result = await retryTransient(fn, { baseDelayMs: 1, maxDelayMs: 2 });

    expect(result).toBe("success-on-retry");
    expect(attempts).toBe(2);
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("retries multiple consecutive transient failures before eventually succeeding", async () => {
    let attempts = 0;
    const fn = vi.fn(async () => {
      attempts++;
      if (attempts < 3) throw new Error("503 Service Unavailable");
      return "eventually-succeeded";
    });

    const result = await retryTransient(fn, { maxAttempts: 4, baseDelayMs: 1, maxDelayMs: 2 });

    expect(result).toBe("eventually-succeeded");
    expect(attempts).toBe(3);
  });

  it("a non-transient error is thrown immediately, with no retry at all", async () => {
    const fn = vi.fn(async () => {
      throw new Error("execution reverted: bad input");
    });

    await expect(retryTransient(fn, { baseDelayMs: 1, maxDelayMs: 2 })).rejects.toThrow(/execution reverted/);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("gives up and rethrows after exhausting maxAttempts on persistent transient failures", async () => {
    const fn = vi.fn(async () => {
      throw new Error("429 Too Many Requests");
    });

    await expect(retryTransient(fn, { maxAttempts: 3, baseDelayMs: 1, maxDelayMs: 2 })).rejects.toThrow(/429/);
    expect(fn).toHaveBeenCalledTimes(3);
  });
});
