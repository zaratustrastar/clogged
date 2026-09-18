import type { PublicClient, Address } from "viem";
import { roundManagerAbi } from "./abis/roundManager.js";
import { scanBlockRangeInChunks } from "./blockRangeChunker.js";
import { withRetry } from "./retry.js";

/**
 * Tracks which rounds have unresolved randomness/relay work outstanding,
 * with NO fixed lookback horizon - a round closed 10,000 rounds ago that
 * is still awaiting randomness (RoundManager itself places no limit on
 * how long a closed round may remain unresolved - confirmed directly
 * against its source: requestRandomnessForRound/relayRandomness both
 * remain callable indefinitely, gated only by the round's own state, not
 * its age) must be found and retried/relayed just as reliably as one
 * closed a minute ago. The previous version of this design used a fixed
 * 20-round lookback window in retryRandomness.ts/relayRandomness.ts,
 * which would have silently stopped tracking any round the keeper had
 * been offline long enough to miss - exactly the failure mode this class
 * exists to close.
 *
 * RoundManager emits everything needed to reconstruct this incrementally,
 * with no state read required beyond the initial startup scan:
 *   RoundClosed(roundId, closeTime, candidateCount, drawSkipped) - a round
 *     entering "closed" state; drawSkipped is given directly, so a
 *     drawn-skipped round never enters the outstanding set at all.
 *   RandomnessRequested(roundId, requestId) - the round's real requestId,
 *     once a request has actually succeeded.
 *   RandomnessRequestFailed(roundId) - an attempt failed; the round
 *     remains outstanding for randomness (this event is purely
 *     informational for this class - the ABSENCE of a corresponding
 *     RandomnessRequested is what actually matters, and is already
 *     correctly reflected by requestedRounds never gaining an entry).
 *   RoundSettled(roundId, winnerTokenId, randomWord) - resolution; the
 *     round is removed from every outstanding set entirely.
 *
 * ARCHITECTURE:
 *   startup (once): scan all relevant event types from deploymentBlock ->
 *     latest, reconstructing the exact real current state - a bounded,
 *     one-time cost proportional to total rounds ever opened (bounded by
 *     the protocol's own round cadence, not by token/market count).
 *   runtime (every poll, cheap): one incremental scan across the same
 *     block range for every event type at once.
 *   needsRandomnessRetry() / needsRelayCheck(): small, precomputed sets -
 *     no RPC read is needed to know which rounds might be due; only to
 *     act on a specific round the caller has already decided to act on.
 *
 * A SINGLE MULTI-EVENT SCAN, NOT THREE CONCURRENT ONES: the previous
 * version ran RoundClosed/RandomnessRequested/RoundSettled as three
 * separate scanBlockRangeInChunks calls inside Promise.all - each
 * independently chunked, so together they opened three simultaneous
 * streams of many chunked RPC calls against the same public Robinhood
 * RPC. A real VPS dry-run hit this directly: RoundLedger's own startup
 * scan failed with "Too Many Requests" on an eth_getLogs chunk, even
 * though each individual chunk was already a bounded 2,000-block range -
 * the problem was concurrency (three streams at once), not chunk size.
 * Fixed by omitting getContractEvents' own `eventName` parameter
 * entirely: passing the full RoundManager ABI with no eventName makes
 * viem construct a SINGLE eth_getLogs call whose topics[0] is an array of
 * every event's own signature hash (RoundClosed, RandomnessRequested,
 * RandomnessRequestFailed, RoundSettled, RandomnessProviderUpdated all at
 * once - confirmed directly against viem's own source, not assumed: this
 * is standard eth_getLogs behavior, where topics[0] as an array means
 * "match any of these", not a viem-specific convenience that makes
 * multiple underlying requests). Every returned log carries its own
 * `.eventName` field (also confirmed directly against viem's source),
 * used to dispatch each log to the right handler below - so this ledger
 * now makes exactly ONE getContractEvents call per chunk, not three, and
 * there is only ever one sequential chunked stream in flight against the
 * RPC at any time, never several concurrent ones.
 *
 * EVERY CHUNK RETRIES TRANSIENT FAILURES IN PLACE: each chunk's own
 * getContractEvents call is wrapped in withRetry (retry.ts - the same
 * primitive every other keeper action already uses for 429/5xx/timeout/
 * reset), so a late-chunk 429 retries just that one chunk with backoff,
 * not the whole scan from deploymentBlock again. This matters
 * specifically because RoundLedger.build() runs during startup, BEFORE
 * runOnce()'s own withRetry wrapper in index.ts even exists yet - without
 * retry at this level, a single transient 429 anywhere in a long
 * historical scan is fatal to the entire startup, not a recoverable
 * hiccup.
 */
export class RoundLedger {
  /** roundId -> true if drawSkipped (per its own RoundClosed event) -
   * drawSkipped rounds are recorded so a round can never appear in the
   * outstanding sets below by omission/ambiguity, but they need no
   * randomness work at all. */
  private closedRounds = new Map<bigint, { drawSkipped: boolean }>();
  /** roundId -> its real requestId, once RandomnessRequested has fired. */
  private requestedRounds = new Map<bigint, bigint>();
  private settledRounds = new Set<bigint>();
  private lastScannedBlock: bigint;

  private constructor(
    private client: PublicClient,
    private roundManager: Address,
    startBlock: bigint,
    private chunkSizeBlocks: bigint = 2000n,
    private interChunkDelayMs: number = 0,
    private retryOptions: { maxAttempts: number; baseDelayMs: number; maxDelayMs: number } = { maxAttempts: 5, baseDelayMs: 1000, maxDelayMs: 15_000 }
  ) {
    this.lastScannedBlock = startBlock;
  }

  /** One-time reconstruction from real event history - deploymentBlock is
   * the manifest's own verified value, never genesis, never a guess. This
   * is what makes a restart safe with no fixed horizon: chain state/events
   * are the source of truth every time, not memory that could have missed
   * something while the process was down. chunkSizeBlocks bounds every
   * eth_getLogs call this instance ever makes (see blockRangeChunker.ts) -
   * what keeps the initial deploymentBlock -> latest scan safe against RPC
   * providers that cap block range/log count per call, however large that
   * range has grown by the time this runs. interChunkDelayMs (default 0,
   * i.e. no added delay) optionally paces consecutive chunk requests -
   * useful if a specific RPC provider rate-limits by request rate rather
   * than by concurrency, which per-chunk retry with backoff alone doesn't
   * address (that handles an occasional 429; a provider enforcing a hard
   * requests-per-second ceiling needs the requests themselves spaced out).
   * retryOptions (default 5 attempts, 1s base backoff, 15s cap) is
   * overridable so tests can use a near-zero backoff rather than the real
   * multi-second delays this keeper actually needs in production. */
  static async build(
    client: PublicClient,
    roundManager: Address,
    deploymentBlock: bigint,
    chunkSizeBlocks: bigint = 2000n,
    interChunkDelayMs: number = 0,
    retryOptions?: { maxAttempts: number; baseDelayMs: number; maxDelayMs: number }
  ): Promise<RoundLedger> {
    const ledger = new RoundLedger(
      client,
      roundManager,
      deploymentBlock,
      chunkSizeBlocks,
      interChunkDelayMs,
      retryOptions ?? { maxAttempts: 5, baseDelayMs: 1000, maxDelayMs: 15_000 }
    );
    await ledger.scanForNewEvents();
    return ledger;
  }

  /** Test-only: directly injects ledger state without an actual event
   * scan. Never used by the real keeper's own startup path (see
   * index.ts, which always calls `build`). */
  static withState(
    client: PublicClient,
    roundManager: Address,
    state: {
      closedRounds?: { roundId: bigint; drawSkipped: boolean }[];
      requestedRounds?: { roundId: bigint; requestId: bigint }[];
      settledRounds?: bigint[];
    },
    chunkSizeBlocks: bigint = 2000n
  ): RoundLedger {
    const ledger = new RoundLedger(client, roundManager, 0n, chunkSizeBlocks, 0);
    for (const { roundId, drawSkipped } of state.closedRounds ?? []) {
      ledger.closedRounds.set(roundId, { drawSkipped });
    }
    for (const { roundId, requestId } of state.requestedRounds ?? []) {
      ledger.requestedRounds.set(roundId, requestId);
    }
    for (const roundId of state.settledRounds ?? []) {
      ledger.settledRounds.add(roundId);
    }
    return ledger;
  }

  /** Scans the block range since the last check for EVERY RoundManager
   * event at once, in a single chunked, sequential stream (never several
   * concurrent ones - see this class's own docs above for why, and what
   * broke before this fix). Each chunk's request retries transient
   * failures (429/5xx/timeout/reset) in place via withRetry - a late
   * failure retries only that one chunk, never restarts the scan. Bounded
   * internally by blockRangeChunker.ts's shared chunking, since this same
   * method serves both the initial (potentially large) deploymentBlock ->
   * latest startup scan and every ordinary small incremental poll. */
  async scanForNewEvents(): Promise<void> {
    const latest = await withRetry(() => this.client.getBlockNumber(), {
      ...this.retryOptions,
      actionLabel: "roundLedger.getBlockNumber",
    });
    if (latest < this.lastScannedBlock) return; // defensive: a reorg-shortened chain view

    const logs = await scanBlockRangeInChunks(
      this.lastScannedBlock,
      latest,
      this.chunkSizeBlocks,
      (chunkFrom, chunkTo) =>
        withRetry(
          () =>
            this.client.getContractEvents({
              address: this.roundManager,
              abi: roundManagerAbi,
              // No eventName - a single multi-event scan (RoundClosed,
              // RandomnessRequested, RandomnessRequestFailed,
              // RoundSettled, RandomnessProviderUpdated all at once) via
              // one eth_getLogs call per chunk, not one call per event
              // type - see this class's own docs above.
              fromBlock: chunkFrom,
              toBlock: chunkTo,
            }),
          { ...this.retryOptions, actionLabel: `roundLedger.scan[${chunkFrom}-${chunkTo}]` }
        ),
      this.interChunkDelayMs
    );

    // Processed in the order received - eth_getLogs returns logs in
    // block/log-index order within a chunk, and chunks themselves are
    // scanned in ascending block order, so this preserves real
    // chronological order across the whole scan. That matters here:
    // RoundSettled's own handling below deletes from the other two maps,
    // which is only correct if any earlier RoundClosed/RandomnessRequested
    // for the same round has already been applied first.
    for (const log of logs) {
      const decoded = log as unknown as { eventName: string; args: Record<string, unknown> };
      switch (decoded.eventName) {
        case "RoundClosed": {
          const { roundId, drawSkipped } = decoded.args as { roundId?: bigint; drawSkipped?: boolean };
          if (roundId !== undefined && drawSkipped !== undefined) this.closedRounds.set(roundId, { drawSkipped });
          break;
        }
        case "RandomnessRequested": {
          const { roundId, requestId } = decoded.args as { roundId?: bigint; requestId?: bigint };
          if (roundId !== undefined && requestId !== undefined) this.requestedRounds.set(roundId, requestId);
          break;
        }
        case "RoundSettled": {
          const { roundId } = decoded.args as { roundId?: bigint };
          if (roundId !== undefined) {
            this.settledRounds.add(roundId);
            // Settled rounds need no further tracking at all - dropping
            // them from the other two maps keeps this ledger's own memory
            // footprint bounded by OUTSTANDING work, not by total rounds
            // ever opened.
            this.closedRounds.delete(roundId);
            this.requestedRounds.delete(roundId);
          }
          break;
        }
        // RandomnessRequestFailed and RandomnessProviderUpdated are
        // returned too (no eventName filter was applied), but are purely
        // informational for this class - see the class docs above for
        // RandomnessRequestFailed; RandomnessProviderUpdated affects
        // nothing this ledger tracks. Both are silently ignored here
        // rather than logged per-event, to avoid noise on a routine
        // historical scan.
        default:
          break;
      }
    }

    this.lastScannedBlock = latest + 1n;
  }

  /** Rounds that are closed, drawable (not drawSkipped), not yet
   * requested, and not settled - these need requestRandomnessForRound.
   * No fixed lookback: every closed round this ledger has ever seen and
   * not since removed as settled is a candidate, regardless of age. */
  needsRandomnessRetry(): bigint[] {
    const due: bigint[] = [];
    for (const [roundId, { drawSkipped }] of this.closedRounds) {
      if (drawSkipped) continue;
      if (this.settledRounds.has(roundId)) continue;
      if (this.requestedRounds.has(roundId)) continue;
      due.push(roundId);
    }
    return due;
  }

  /** Rounds with a real requestId that have not yet settled - these need
   * checking on Arbitrum for fulfilled-but-unrelayed status. Returns
   * (roundId, requestId) pairs since relayRandomness itself is keyed by
   * requestId, not roundId. No fixed lookback, for the same reason as
   * needsRandomnessRetry above. */
  needsRelayCheck(): { roundId: bigint; requestId: bigint }[] {
    const due: { roundId: bigint; requestId: bigint }[] = [];
    for (const [roundId, requestId] of this.requestedRounds) {
      if (this.settledRounds.has(roundId)) continue;
      due.push({ roundId, requestId });
    }
    return due;
  }

  /** Every round this ledger currently considers requested-but-unsettled -
   * used by observeSettlement for its own no-fixed-horizon reporting. */
  outstandingRequested(): bigint[] {
    return Array.from(this.requestedRounds.keys()).filter((roundId) => !this.settledRounds.has(roundId));
  }

  get outstandingCount(): number {
    return this.closedRounds.size;
  }

  /** Test-only: exposes the effective retryOptions this instance is using
   * (whatever was passed to build()/the constructor, or the conservative
   * production default if omitted) - so a test can confirm the default
   * itself is the real production value directly and cheaply, rather than
   * inferring it from real retry timing. Never read by production code. */
  get retryOptionsForTesting(): { maxAttempts: number; baseDelayMs: number; maxDelayMs: number } {
    return this.retryOptions;
  }
}
