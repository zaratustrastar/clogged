import type { PublicClient, Address } from "viem";
import { eligibilityRegistryAbi } from "./abis/eligibilityRegistry.js";

/**
 * Reconstructs the set of registered tokenIds from real onchain event logs
 * (TokenRegistered) at startup, and keeps it current with a cheap
 * incremental log scan thereafter - this is the whole point of this class:
 * without it, discovering which tokens exist would mean either reading
 * nextTokenId and looping 1..nextTokenId-1 on every single poll (the
 * brute-force this class exists to avoid - at the protocol's 7,777-ticker
 * cap, that is 7,777 RPC calls every 30 seconds forever), or re-scanning
 * the full log range from genesis every loop (nearly as wasteful). Instead:
 * one full scan (deploymentBlock -> latest) exactly once at construction,
 * then only ever scanning the block range since the previous check.
 *
 * "Small active watch list" (the qualifyTokens action's real per-loop
 * cost): once a token is confirmed qualified for the CURRENT round, it is
 * removed from the per-round check set entirely (markQualifiedForRound) -
 * it is only re-added to what actually needs checking once a new round
 * opens. So the set of tokens actually re-examined every poll is never
 * "every token ever registered" - it shrinks to just the tokens that have
 * not yet qualified for whichever round is currently open, which in
 * steady state is a small, bounded number regardless of how many
 * thousands of tokens have been launched historically.
 */
export class TokenWatchlist {
  private knownTokenIds = new Set<bigint>();
  private qualifiedForRound = new Map<bigint, bigint>(); // tokenId -> roundId it's already qualified for
  private lastScannedBlock: bigint;

  private constructor(
    private client: PublicClient,
    private eligibilityRegistry: Address,
    startBlock: bigint
  ) {
    this.lastScannedBlock = startBlock;
  }

  /** One-time reconstruction from real event history - deploymentBlock is
   * the manifest's own verified value (see config.ts), never genesis, and
   * never a guess. */
  static async build(client: PublicClient, eligibilityRegistry: Address, deploymentBlock: bigint): Promise<TokenWatchlist> {
    const watchlist = new TokenWatchlist(client, eligibilityRegistry, deploymentBlock);
    await watchlist.scanForNewTokens();
    return watchlist;
  }

  /** Test-only: directly injects a known set of tokenIds without an actual
   * event scan, so decision-path tests for qualifyMaturedTokens can supply
   * a fixed watchlist without mocking getBlockNumber/getContractEvents.
   * Never used by the real keeper's own startup path (see index.ts, which
   * always calls `build`). */
  static withKnownIds(client: PublicClient, eligibilityRegistry: Address, tokenIds: bigint[]): TokenWatchlist {
    const watchlist = new TokenWatchlist(client, eligibilityRegistry, 0n);
    for (const id of tokenIds) watchlist.knownTokenIds.add(id);
    return watchlist;
  }

  /** Incremental only - scans exactly the block range since the last scan,
   * never the full history again. Cheap enough to call every poll. */
  async scanForNewTokens(): Promise<number> {
    const latest = await this.client.getBlockNumber();
    if (latest < this.lastScannedBlock) return 0; // defensive: a reorg-shortened chain view - just skip this pass

    const logs = await this.client.getContractEvents({
      address: this.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      eventName: "TokenRegistered",
      fromBlock: this.lastScannedBlock,
      toBlock: latest,
    });

    let added = 0;
    for (const log of logs) {
      const tokenId = (log as unknown as { args: { tokenId: bigint } }).args.tokenId;
      if (tokenId !== undefined && !this.knownTokenIds.has(tokenId)) {
        this.knownTokenIds.add(tokenId);
        added++;
      }
    }

    this.lastScannedBlock = latest + 1n;
    return added;
  }

  /** The tokens still worth checking for maturity this round - every known
   * token EXCEPT ones already confirmed qualified for the given round. */
  tokensToCheck(currentRoundId: bigint): bigint[] {
    return Array.from(this.knownTokenIds).filter((id) => this.qualifiedForRound.get(id) !== currentRoundId);
  }

  markQualifiedForRound(tokenId: bigint, roundId: bigint): void {
    this.qualifiedForRound.set(tokenId, roundId);
  }

  get size(): number {
    return this.knownTokenIds.size;
  }
}
