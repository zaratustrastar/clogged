/**
 * A block range from `deploymentBlock` to `latest` starts small but grows
 * forever as protocol history accumulates - and the Robinhood public RPC
 * has now demonstrated real rate limiting (429 Too Many Requests) on an
 * unbounded single getContractEvents/getLogs call spanning that entire
 * range, observed directly during keeper historical log reconstruction
 * (see keeper/src/blockRangeChunker.ts, which this mirrors for the
 * frontend - same shared problem, same fix, applied here independently
 * since the frontend and keeper are separate runtimes/bundles with no
 * shared package to import from).
 *
 * Chunks are contiguous and non-overlapping by construction: chunk N+1
 * always starts at exactly (chunk N's end + 1), so every block in
 * [fromBlock, toBlock] is covered by exactly one chunk - never zero (a
 * gap) and never more than one (a duplicate).
 */
export async function scanBlockRangeInChunks<T>(
  fromBlock: bigint,
  toBlock: bigint,
  chunkSizeBlocks: bigint,
  fetchChunk: (chunkFromBlock: bigint, chunkToBlock: bigint) => Promise<T[]>
): Promise<T[]> {
  if (fromBlock > toBlock) return [];
  if (chunkSizeBlocks <= 0n) {
    throw new Error(`scanBlockRangeInChunks: chunkSizeBlocks must be positive, got ${chunkSizeBlocks}`);
  }

  const results: T[] = [];
  let chunkStart = fromBlock;
  while (chunkStart <= toBlock) {
    const chunkEnd = chunkStart + chunkSizeBlocks - 1n > toBlock ? toBlock : chunkStart + chunkSizeBlocks - 1n;
    const chunkResults = await fetchChunk(chunkStart, chunkEnd);
    results.push(...chunkResults);
    chunkStart = chunkEnd + 1n;
  }
  return results;
}

/** Matches a transient failure worth retrying (rate limiting, a dropped
 * connection, a momentary gateway error) - never a real application error
 * (a malformed request, a contract revert), which should surface
 * immediately rather than being retried into a longer delay before the
 * user sees it. Checks both a raw HTTP status (if the client/transport
 * surfaces one) and the error message text, since viem's own HTTP
 * transport wraps the underlying fetch error in ways that don't always
 * preserve a clean numeric status. */
export function isTransientRpcError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  const status = (error as { status?: number; code?: number })?.status ?? (error as { status?: number; code?: number })?.code;
  if (status === 429 || status === 503 || status === 502 || status === 504) return true;
  return /\b429\b|\b502\b|\b503\b|\b504\b|too many requests|rate limit|service unavailable|bad gateway|gateway timeout|timeout|timed out|ECONNRESET|ETIMEDOUT|fetch failed|network/i.test(message);
}

/** Exponential backoff with a small amount of jitter, retrying only
 * transient failures (see isTransientRpcError) - a real application error
 * (a bad request, a contract revert) is rethrown immediately on the first
 * attempt rather than retried into a longer delay before the caller finds
 * out. */
export async function retryTransient<T>(
  fn: () => Promise<T>,
  opts: { maxAttempts?: number; baseDelayMs?: number; maxDelayMs?: number } = {}
): Promise<T> {
  const { maxAttempts = 4, baseDelayMs = 500, maxDelayMs = 8_000 } = opts;
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (!isTransientRpcError(error) || attempt === maxAttempts) throw error;
      const delay = Math.min(maxDelayMs, baseDelayMs * 2 ** (attempt - 1)) * (0.75 + Math.random() * 0.5);
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
  throw lastError;
}
