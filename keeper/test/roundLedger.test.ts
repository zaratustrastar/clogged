import { describe, it, expect } from "vitest";
import { RoundLedger } from "../src/roundLedger.js";
import { makeMockClients } from "./testHelpers.js";

const ROUND_MANAGER = "0x1000000000000000000000000000000000000d" as `0x${string}`;

describe("RoundLedger - event-driven state, no fixed lookback horizon", () => {
  describe("needsRandomnessRetry()", () => {
    it("includes a closed, drawable, unrequested round", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 5n, drawSkipped: false }],
      });
      expect(ledger.needsRandomnessRetry()).toEqual([5n]);
    });

    it("excludes a drawSkipped round entirely", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 5n, drawSkipped: true }],
      });
      expect(ledger.needsRandomnessRetry()).toEqual([]);
    });

    it("excludes a round that has already been requested", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 5n, drawSkipped: false }],
        requestedRounds: [{ roundId: 5n, requestId: 1n }],
      });
      expect(ledger.needsRandomnessRetry()).toEqual([]);
    });

    it("excludes a settled round even if it would otherwise look due", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 5n, drawSkipped: false }],
        settledRounds: [5n],
      });
      expect(ledger.needsRandomnessRetry()).toEqual([]);
    });

    it("has no fixed cap - many old outstanding rounds are all returned at once", () => {
      const { clients } = makeMockClients({});
      const closedRounds = [];
      for (let i = 1n; i <= 100n; i++) closedRounds.push({ roundId: i, drawSkipped: false });
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, { closedRounds });
      expect(ledger.needsRandomnessRetry()).toHaveLength(100);
    });
  });

  describe("needsRelayCheck()", () => {
    it("includes a requested, unsettled round with its real requestId", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        requestedRounds: [{ roundId: 5n, requestId: 99n }],
      });
      expect(ledger.needsRelayCheck()).toEqual([{ roundId: 5n, requestId: 99n }]);
    });

    it("excludes a settled round", () => {
      const { clients } = makeMockClients({});
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        requestedRounds: [{ roundId: 5n, requestId: 99n }],
        settledRounds: [5n],
      });
      expect(ledger.needsRelayCheck()).toEqual([]);
    });
  });

  describe("scanForNewEvents() - incremental event-driven reconstruction", () => {    it("a new RoundClosed event adds the round to the ledger", async () => {
      const { clients } = makeMockClients({});
      (clients.robinhoodPublic.getContractEvents as unknown as { mockImplementation: (fn: (args: { eventName: string }) => Promise<unknown[]>) => void }).mockImplementation(
        async ({ eventName }: { eventName: string }) =>
          eventName === "RoundClosed" ? [{ args: { roundId: 7n, drawSkipped: false } }] : []
      );
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {});
      await ledger.scanForNewEvents();
      expect(ledger.needsRandomnessRetry()).toEqual([7n]);
    });

    it("a new RandomnessRequested event records the round as requested", async () => {
      const { clients } = makeMockClients({});
      (clients.robinhoodPublic.getContractEvents as unknown as { mockImplementation: (fn: (args: { eventName: string }) => Promise<unknown[]>) => void }).mockImplementation(
        async ({ eventName }: { eventName: string }) =>
          eventName === "RandomnessRequested" ? [{ args: { roundId: 7n, requestId: 42n } }] : []
      );
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 7n, drawSkipped: false }],
      });
      await ledger.scanForNewEvents();
      expect(ledger.needsRandomnessRetry()).toEqual([]); // now requested, no longer needs retry
      expect(ledger.needsRelayCheck()).toEqual([{ roundId: 7n, requestId: 42n }]);
    });

    it("REQUIREMENT: a new RoundSettled event removes the round from every outstanding set (settled rounds are ignored/removed)", async () => {
      const { clients } = makeMockClients({});
      (clients.robinhoodPublic.getContractEvents as unknown as { mockImplementation: (fn: (args: { eventName: string }) => Promise<unknown[]>) => void }).mockImplementation(
        async ({ eventName }: { eventName: string }) =>
          eventName === "RoundSettled" ? [{ args: { roundId: 7n } }] : []
      );
      const ledger = RoundLedger.withState(clients.robinhoodPublic, ROUND_MANAGER, {
        closedRounds: [{ roundId: 7n, drawSkipped: false }],
        requestedRounds: [{ roundId: 7n, requestId: 42n }],
      });
      expect(ledger.outstandingCount).toBe(1);

      await ledger.scanForNewEvents();

      expect(ledger.needsRandomnessRetry()).toEqual([]);
      expect(ledger.needsRelayCheck()).toEqual([]);
      // Removed entirely, not merely excluded - memory footprint bounded
      // by outstanding work, not total rounds ever opened.
      expect(ledger.outstandingCount).toBe(0);
    });

    it("REQUIREMENT: restart reconstructs outstanding work correctly - RoundLedger.build performs one full scan from deploymentBlock", async () => {
      const { clients } = makeMockClients({});
      let capturedFromBlock: bigint | undefined;
      (clients.robinhoodPublic.getContractEvents as unknown as { mockImplementation: (fn: (args: { eventName: string; fromBlock: bigint }) => Promise<unknown[]>) => void }).mockImplementation(
        async ({ eventName, fromBlock }: { eventName: string; fromBlock: bigint }) => {
          capturedFromBlock = fromBlock;
          return eventName === "RoundClosed" ? [{ args: { roundId: 3n, drawSkipped: false } }] : [];
        }
      );

      const ledger = await RoundLedger.build(clients.robinhoodPublic, ROUND_MANAGER, 500n);

      expect(capturedFromBlock).toBe(500n); // the manifest's real verified deploymentBlock, never genesis
      expect(ledger.needsRandomnessRetry()).toEqual([3n]);
    });
  });

  describe("chunked historical reconstruction (bounded block-range chunker)", () => {
    /** A tiny fake chain: RoundClosed/RandomnessRequested/RoundSettled
     * events spread across a wide block range, keyed by which block they
     * "happened" at - used to simulate a real getContractEvents call that
     * only returns logs actually within the requested [fromBlock, toBlock]
     * window, so a chunked scan is forced to genuinely combine multiple
     * chunks to see the full picture, exactly as a real RPC provider that
     * caps block range per call would behave. */
    function makeFakeChainClient(latestBlock: bigint) {
      const events: { block: bigint; eventName: string; args: Record<string, unknown> }[] = [
        { block: 100n, eventName: "RoundClosed", args: { roundId: 1n, drawSkipped: false } },
        { block: 2_500n, eventName: "RoundClosed", args: { roundId: 2n, drawSkipped: false } },
        { block: 2_600n, eventName: "RandomnessRequested", args: { roundId: 2n, requestId: 10n } },
        { block: 5_800n, eventName: "RoundClosed", args: { roundId: 3n, drawSkipped: true } },
        { block: 9_950n, eventName: "RoundClosed", args: { roundId: 4n, drawSkipped: false } },
        { block: 9_960n, eventName: "RandomnessRequested", args: { roundId: 4n, requestId: 11n } },
        { block: 9_970n, eventName: "RoundSettled", args: { roundId: 4n } },
      ];

      return {
        getBlockNumber: async () => latestBlock,
        getContractEvents: async ({ eventName, fromBlock, toBlock }: { eventName: string; fromBlock: bigint; toBlock: bigint }) =>
          events
            .filter((e) => e.eventName === eventName && e.block >= fromBlock && e.block <= toBlock)
            .map((e) => ({ args: e.args })),
      } as unknown as Parameters<typeof RoundLedger.build>[0];
    }

    it("REQUIREMENT: historical reconstruction over multiple chunks produces the same state as one conceptual full-history scan", async () => {
      // Small chunk size (1000 blocks) against a 10,000-block history
      // forces 10 chunks per event type - the events above are
      // deliberately spread so several land in different chunks.
      const chunkedClient = makeFakeChainClient(10_000n);
      const chunkedLedger = await RoundLedger.build(chunkedClient, ROUND_MANAGER, 0n, 1000n);

      // The "one conceptual full-history scan" - a single chunk covering
      // the entire range in one call, for direct comparison.
      const fullRangeClient = makeFakeChainClient(10_000n);
      const fullRangeLedger = await RoundLedger.build(fullRangeClient, ROUND_MANAGER, 0n, 1_000_000n);

      expect(chunkedLedger.needsRandomnessRetry()).toEqual(fullRangeLedger.needsRandomnessRetry());
      expect(chunkedLedger.needsRelayCheck()).toEqual(fullRangeLedger.needsRelayCheck());
      expect(chunkedLedger.outstandingRequested()).toEqual(fullRangeLedger.outstandingRequested());
      expect(chunkedLedger.outstandingCount).toBe(fullRangeLedger.outstandingCount);

      // Concretely: round 1 (never requested) needs a retry; round 2 is
      // requested and awaiting relay; round 3 was drawSkipped, needs
      // nothing; round 4 settled, tracked nowhere at all - identical in
      // both the chunked and single-call reconstructions.
      expect(chunkedLedger.needsRandomnessRetry()).toEqual([1n]);
      expect(chunkedLedger.needsRelayCheck()).toEqual([{ roundId: 2n, requestId: 10n }]);
    });

    it("REQUIREMENT: restart reconstructs old unresolved rounds correctly even when the history requires multiple chunks", async () => {
      // Simulates a real restart against a long chain history: a fresh
      // RoundLedger.build with a small chunk size must still find round 1
      // (closed at block 100, near the very start of a 10,000-block
      // history) exactly as reliably as the most recent rounds.
      const client = makeFakeChainClient(10_000n);
      const ledger = await RoundLedger.build(client, ROUND_MANAGER, 0n, 500n); // 20 chunks

      expect(ledger.needsRandomnessRetry()).toContain(1n);
      expect(ledger.needsRandomnessRetry()).toEqual([1n]);
    });
  });
});
