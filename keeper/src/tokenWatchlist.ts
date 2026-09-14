import type { PublicClient, Address } from "viem";
import { eligibilityRegistryAbi } from "./abis/eligibilityRegistry.js";
import { bondingCurveClogAbi } from "./abis/bondingCurveClog.js";

/**
 * Maintains a genuinely SMALL active set of tokens worth checking for
 * maturity - not "every launched token minus the ones already qualified
 * this round" (which is NOT small once the protocol approaches its
 * 7,777-ticker cap - see the design note below for the earlier version of
 * this class, which had exactly that flaw despite already avoiding the
 * literal nextTokenId brute-force loop).
 *
 * EligibilityRegistry does NOT emit an event when aboveThresholdSince
 * starts or resets (confirmed directly against its source - it emits only
 * TokenRegistered, Qualified, RoundOpened, RoundManagerInitialized), so
 * there is no way to learn "this token's streak just started/reset"
 * directly from an EligibilityRegistry event. What IS observable, and
 * reliably correlates with a possible aboveThresholdSince change, is
 * trade activity on the token's own market: EligibilityRegistry.onTrade()
 * (which drives aboveThresholdSince) is called BY the market contract on
 * every buy/sell, and BondingCurveClog itself DOES emit real Bought/Sold
 * events (confirmed directly against its source) - one event stream per
 * market, but eth_getLogs accepts a MULTI-ADDRESS filter, so watching
 * "did ANY known market trade since I last checked" is a single RPC call
 * regardless of how many thousands of markets exist, not one call per
 * market.
 *
 * tokenId<->market mapping is never inferred from the Bought/Sold events
 * themselves (they carry no tokenId field at all - only buyer/seller and
 * amounts). It comes from the LOG'S OWN EMITTING CONTRACT ADDRESS
 * (log.address, which viem always includes on every decoded log,
 * regardless of the event's own args) matched against this class's own
 * market -> tokenId map, built once from TokenRegistered's own
 * (tokenId, market) pair - the only place that mapping is ever
 * established.
 *
 * ARCHITECTURE:
 *   startup (once):
 *     1. scan TokenRegistered (deploymentBlock -> latest) -> every known
 *        tokenId + its market address
 *     2. for every known token, ONE aboveThresholdSince read -> seeds the
 *        active-streak set (tokens with a live, nonzero streak right now)
 *   runtime (every poll, cheap):
 *     1. scan TokenRegistered incrementally (new blocks only) -> any newly
 *        launched token gets its own one-time aboveThresholdSince seed read
 *     2. ONE eth_getLogs call across ALL known market addresses (new
 *        blocks only) for Bought+Sold -> resolves to a small set of
 *        tokenIds that traded since last check
 *     3. re-read aboveThresholdSince ONLY for that small traded set -
 *        updates/removes them from the active-streak set based on the
 *        real, current value (0 = streak reset, removed; nonzero = active,
 *        (re)scheduled)
 *   dueForCheck(): only active-streak tokens whose scheduled maturity time
 *     (aboveThresholdSince + requiredAbsoluteSeconds) has already passed
 *     AND are not yet marked qualified for the current round - this, not
 *     the full active-streak set, is what qualifyTokens.ts actually reads
 *     isCandidate()/calls qualify() for.
 */
export class TokenWatchlist {
  private knownTokenIds = new Set<bigint>();
  private marketToTokenId = new Map<Address, bigint>();
  private tokenIdToMarket = new Map<bigint, Address>();
  /** tokenId -> its last-known aboveThresholdSince (unix seconds). Only
   * entries with a nonzero value are "active" - a zero entry (or absence)
   * means no live streak, nothing to schedule. */
  private aboveThresholdSince = new Map<bigint, bigint>();
  private qualifiedForRound = new Map<bigint, bigint>();
  private lastScannedRegistrationBlock: bigint;
  private lastScannedTradeBlock: bigint;

  private constructor(
    private client: PublicClient,
    private eligibilityRegistry: Address,
    startBlock: bigint
  ) {
    this.lastScannedRegistrationBlock = startBlock;
    this.lastScannedTradeBlock = startBlock;
  }

  /** One-time reconstruction from real event + state history -
   * deploymentBlock is the manifest's own verified value (see config.ts),
   * never genesis, and never a guess. The O(known tokens) aboveThresholdSince
   * reads here are a bounded, one-time startup cost - not a per-poll one. */
  static async build(client: PublicClient, eligibilityRegistry: Address, deploymentBlock: bigint): Promise<TokenWatchlist> {
    const watchlist = new TokenWatchlist(client, eligibilityRegistry, deploymentBlock);
    await watchlist.scanForNewTokens();
    await watchlist.seedInitialThresholdState();
    return watchlist;
  }

  /** Test-only: directly injects a known set of tokenIds (with their
   * market addresses, and optionally a starting aboveThresholdSince value
   * for a given token) without an actual event scan or trade-activity
   * discovery, so decision-path tests can set up a fixed watchlist state
   * directly. Never used by the real keeper's own startup path (see
   * index.ts, which always calls `build`). */
  static withKnownTokens(
    client: PublicClient,
    eligibilityRegistry: Address,
    tokens: { tokenId: bigint; market: Address; aboveThresholdSince?: bigint }[]
  ): TokenWatchlist {
    const watchlist = new TokenWatchlist(client, eligibilityRegistry, 0n);
    for (const { tokenId, market, aboveThresholdSince } of tokens) {
      watchlist.knownTokenIds.add(tokenId);
      watchlist.marketToTokenId.set(market.toLowerCase() as Address, tokenId);
      watchlist.tokenIdToMarket.set(tokenId, market);
      if (aboveThresholdSince !== undefined && aboveThresholdSince !== 0n) {
        watchlist.aboveThresholdSince.set(tokenId, aboveThresholdSince);
      }
    }
    return watchlist;
  }

  private async seedInitialThresholdState(): Promise<void> {
    for (const tokenId of this.knownTokenIds) {
      await this.refreshThresholdState(tokenId);
    }
  }

  private async refreshThresholdState(tokenId: bigint): Promise<void> {
    const value = (await this.client.readContract({
      address: this.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "aboveThresholdSince",
      args: [tokenId],
    })) as bigint;
    if (value === 0n) {
      this.aboveThresholdSince.delete(tokenId);
    } else {
      this.aboveThresholdSince.set(tokenId, value);
    }
  }

  /** Incremental only - scans exactly the block range since the last scan.
   * New tokens get one seed read each (unavoidable - there is no event for
   * "this token's initial aboveThresholdSince"), a bounded, small cost
   * proportional to how many NEW tokens launched since last poll, never the
   * full historical count. */
  async scanForNewTokens(): Promise<number> {
    const latest = await this.client.getBlockNumber();
    if (latest < this.lastScannedRegistrationBlock) return 0; // defensive: a reorg-shortened chain view

    const logs = await this.client.getContractEvents({
      address: this.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      eventName: "TokenRegistered",
      fromBlock: this.lastScannedRegistrationBlock,
      toBlock: latest,
    });

    let added = 0;
    for (const log of logs) {
      const { tokenId, market } = (log as unknown as { args: { tokenId: bigint; market: Address } }).args;
      if (tokenId !== undefined && !this.knownTokenIds.has(tokenId)) {
        this.knownTokenIds.add(tokenId);
        this.marketToTokenId.set(market.toLowerCase() as Address, tokenId);
        this.tokenIdToMarket.set(tokenId, market);
        await this.refreshThresholdState(tokenId); // one-time seed for this specific new token only
        added++;
      }
    }

    this.lastScannedRegistrationBlock = latest + 1n;
    return added;
  }

  /** Incremental only - ONE getLogs call per event type across every known
   * market address at once (never one call per market), scanning only the
   * block range since the last check. Returns the tokenIds whose
   * aboveThresholdSince was actually re-read (i.e. that traded), for
   * logging/visibility - the internal active-streak set is already updated
   * by the time this returns. */
  async scanForTradeActivity(): Promise<bigint[]> {
    const latest = await this.client.getBlockNumber();
    if (latest < this.lastScannedTradeBlock || this.tokenIdToMarket.size === 0) {
      this.lastScannedTradeBlock = latest + 1n;
      return [];
    }

    const marketAddresses = Array.from(this.tokenIdToMarket.values());
    const [boughtLogs, soldLogs] = await Promise.all([
      this.client.getContractEvents({
        address: marketAddresses,
        abi: bondingCurveClogAbi,
        eventName: "Bought",
        fromBlock: this.lastScannedTradeBlock,
        toBlock: latest,
      }),
      this.client.getContractEvents({
        address: marketAddresses,
        abi: bondingCurveClogAbi,
        eventName: "Sold",
        fromBlock: this.lastScannedTradeBlock,
        toBlock: latest,
      }),
    ]);

    const tradedTokenIds = new Set<bigint>();
    for (const log of [...boughtLogs, ...soldLogs]) {
      const emittingMarket = (log as unknown as { address: Address }).address.toLowerCase() as Address;
      const tokenId = this.marketToTokenId.get(emittingMarket);
      // Reliability note: tokenId is resolved from the LOG'S OWN EMITTING
      // CONTRACT ADDRESS matched against marketToTokenId (built solely
      // from TokenRegistered's own (tokenId, market) pair) - never from
      // any field within the Bought/Sold event itself, since neither event
      // carries a tokenId at all. A log from an address not in
      // marketToTokenId (which should never happen, since the filter above
      // is scoped to exactly the known market addresses) is silently
      // skipped rather than guessed at.
      if (tokenId !== undefined) tradedTokenIds.add(tokenId);
    }

    for (const tokenId of tradedTokenIds) {
      await this.refreshThresholdState(tokenId);
    }

    this.lastScannedTradeBlock = latest + 1n;
    return Array.from(tradedTokenIds);
  }

  /** The only tokens qualifyTokens.ts actually needs to read isCandidate()/
   * call qualify() for THIS poll: active-streak tokens (nonzero
   * aboveThresholdSince, kept current by scanForTradeActivity above) whose
   * scheduled maturity time has already passed, and that are not already
   * marked qualified for the given round. In steady state this is a small,
   * bounded set regardless of how many thousands of tokens have ever been
   * launched - never "every known token". */
  dueForCheck(currentRoundId: bigint, nowSec: bigint, requiredAbsoluteSeconds: bigint): bigint[] {
    const due: bigint[] = [];
    for (const [tokenId, since] of this.aboveThresholdSince) {
      if (this.qualifiedForRound.get(tokenId) === currentRoundId) continue;
      if (nowSec - since >= requiredAbsoluteSeconds) due.push(tokenId);
    }
    return due;
  }

  markQualifiedForRound(tokenId: bigint, roundId: bigint): void {
    this.qualifiedForRound.set(tokenId, roundId);
  }

  /** Called by qualifyTokens.ts after re-reading aboveThresholdSince
   * directly (to confirm no last-second reset before actually spending gas
   * on qualify()) - keeps the active-streak set in sync with that freshest
   * read rather than trusting the value scanForTradeActivity last saw. */
  recordThresholdRead(tokenId: bigint, value: bigint): void {
    if (value === 0n) this.aboveThresholdSince.delete(tokenId);
    else this.aboveThresholdSince.set(tokenId, value);
  }

  get size(): number {
    return this.knownTokenIds.size;
  }

  get activeStreakCount(): number {
    return this.aboveThresholdSince.size;
  }
}
