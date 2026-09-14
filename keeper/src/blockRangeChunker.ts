/**
 * A block range from `deploymentBlock` to `latest` starts small but grows
 * forever as protocol history accumulates - the address-count fix already
 * applied to trade-event scanning (no address filter at all, see
 * tokenWatchlist.ts) does nothing about THIS dimension of the same class
 * of problem: many real RPC providers cap either the block range or the
 * number of logs a single eth_getLogs call may span/return (limits vary
 * by provider and are frequently undocumented or silently enforced),
 * regardless of how many addresses are involved. A single unbounded
 * `[deploymentBlock, latest]` call is exactly the kind of assumption that
 * eventually breaks once the chain has enough history behind it, even
 * though it works fine on day one.
 *
 * This chunker is deliberately the ONE place that walks a block range in
 * bounded pieces, shared by every historical reconstruction
 * (TokenWatchlist.scanForNewTokens/scanForTradeActivity,
 * RoundLedger.scanForNewEvents) - both the initial full-history startup
 * scan and every ordinary incremental poll go through the exact same code
 * path. This is deliberate simplicity, not an oversight: chunking an
 * already-small incremental range (new blocks since last poll) just
 * produces a single chunk, at no meaningful extra cost - there is no
 * need for a separate "small range" code path.
 *
 * Chunks are contiguous and non-overlapping by construction: chunk N+1
 * always starts at exactly (chunk N's end + 1), so every block in
 * [fromBlock, toBlock] is covered by exactly one chunk - never zero
 * (a gap) and never more than one (a duplicate).
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
