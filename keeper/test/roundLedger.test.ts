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

  describe("scanForNewEvents() - incremental event-driven reconstruction", () => {
    it("a new RoundClosed event adds the round to the ledger", async () => {
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
});
