import type { PublicClient, Address } from "viem";
import { roundManagerAbi } from "./abis/roundManager.js";
import { scanBlockRangeInChunks } from "./blockRangeChunker.js";

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
 *   runtime (every poll, cheap): one incremental scan per event type
 *     (3 total getLogs calls, but against a SINGLE fixed RoundManager
 *     address - no market-count-style scaling concern applies here at
 *     all) - updates the same maps/sets from just the new events.
 *   needsRandomnessRetry() / needsRelayCheck(): small, precomputed sets -
 *     no RPC read is needed to know which rounds might be due; only to
 *     act on a specific round the caller has already decided to act on.
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
    private chunkSizeBlocks: bigint = 2000n
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
   * range has grown by the time this runs. */
  static async build(
    client: PublicClient,
    roundManager: Address,
    deploymentBlock: bigint,
    chunkSizeBlocks: bigint = 2000n
  ): Promise<RoundLedger> {
    const ledger = new RoundLedger(client, roundManager, deploymentBlock, chunkSizeBlocks);
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
    const ledger = new RoundLedger(client, roundManager, 0n, chunkSizeBlocks);
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

  /** Scans the block range since the last check, across all relevant
   * event types, against RoundManager's single fixed address (no
   * market-count-style scaling concern here at all - this is always
   * exactly 3 getLogs-family calls per invocation, regardless of how many
   * rounds have ever existed). Bounded internally by
   * blockRangeChunker.ts's shared chunking, since this same method serves
   * both the initial (potentially large) deploymentBlock -> latest
   * startup scan and every ordinary small incremental poll. */
  async scanForNewEvents(): Promise<void> {
    const latest = await this.client.getBlockNumber();
    if (latest < this.lastScannedBlock) return; // defensive: a reorg-shortened chain view

    const [closedLogs, requestedLogs, settledLogs] = await Promise.all([
      scanBlockRangeInChunks(this.lastScannedBlock, latest, this.chunkSizeBlocks, (chunkFrom, chunkTo) =>
        this.client.getContractEvents({
          address: this.roundManager,
          abi: roundManagerAbi,
          eventName: "RoundClosed",
          fromBlock: chunkFrom,
          toBlock: chunkTo,
        })
      ),
      scanBlockRangeInChunks(this.lastScannedBlock, latest, this.chunkSizeBlocks, (chunkFrom, chunkTo) =>
        this.client.getContractEvents({
          address: this.roundManager,
          abi: roundManagerAbi,
          eventName: "RandomnessRequested",
          fromBlock: chunkFrom,
          toBlock: chunkTo,
        })
      ),
      scanBlockRangeInChunks(this.lastScannedBlock, latest, this.chunkSizeBlocks, (chunkFrom, chunkTo) =>
        this.client.getContractEvents({
          address: this.roundManager,
          abi: roundManagerAbi,
          eventName: "RoundSettled",
          fromBlock: chunkFrom,
          toBlock: chunkTo,
        })
      ),
    ]);

    for (const log of closedLogs) {
      const { roundId, drawSkipped } = (log as unknown as { args: { roundId: bigint; drawSkipped: boolean } }).args;
      if (roundId !== undefined) this.closedRounds.set(roundId, { drawSkipped });
    }
    for (const log of requestedLogs) {
      const { roundId, requestId } = (log as unknown as { args: { roundId: bigint; requestId: bigint } }).args;
      if (roundId !== undefined && requestId !== undefined) this.requestedRounds.set(roundId, requestId);
    }
    for (const log of settledLogs) {
      const { roundId } = (log as unknown as { args: { roundId: bigint } }).args;
      if (roundId !== undefined) {
        this.settledRounds.add(roundId);
        // Settled rounds need no further tracking at all - dropping them
        // from the other two maps keeps this ledger's own memory
        // footprint bounded by OUTSTANDING work, not by total rounds ever
        // opened.
        this.closedRounds.delete(roundId);
        this.requestedRounds.delete(roundId);
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
}
